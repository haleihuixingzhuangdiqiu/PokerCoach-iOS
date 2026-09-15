// Adapted from the user-owned XiangqiCoach capture pipeline; see docs/SOURCES.md.
#if canImport(Network) && canImport(ImageIO)
import Foundation
import ImageIO
import Network

final class FrameReceiver: @unchecked Sendable {
    static let port: NWEndpoint.Port = 43_982
    /// Host-only fixture probes never share the live ReplayKit listener.
    static let localProbePort: NWEndpoint.Port = 43_983

    var onFrame: ((CGImage, TimeInterval) -> Void)? {
        get { withQueue { frameHandler } }
        set { withQueue { frameHandler = newValue } }
    }
    var onStatus: ((String) -> Void)? {
        get { withQueue { statusHandler } }
        set { withQueue { statusHandler = newValue } }
    }

    var onHealth: ((BroadcastHealth) -> Void)? {
        get { withQueue { healthHandler } }
        set { withQueue { healthHandler = newValue } }
    }

    private let queue = DispatchQueue(label: "com.lgj.pokercoach.frame-receiver", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let requestedPort: NWEndpoint.Port
    private let makeListener: (NWParameters) throws -> NWListener
    private var listener: NWListener?
    private var frameHandler: ((CGImage, TimeInterval) -> Void)?
    private var statusHandler: ((String) -> Void)?
    private var healthHandler: ((BroadcastHealth) -> Void)?
    private var freshness = FrameFreshnessGate()
    private var healthFreshness = FrameFreshnessGate()
    private var diagnosticTimes: [String: TimeInterval] = [:]
    private var isRunning = false
    private var generation: UInt64 = 0
    private var retryAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var connections: [UUID: NWConnection] = [:]

    var listeningPort: NWEndpoint.Port? { withQueue { listener?.port } }

    // 默认工厂仍创建真实本机监听器；注入点只用于验证延迟回调与构造失败的恢复。
    init(port: NWEndpoint.Port = FrameReceiver.port,
         makeListener: @escaping (NWParameters) throws -> NWListener = { try NWListener(using: $0) }) {
        requestedPort = port
        self.makeListener = makeListener
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        retryWork?.cancel()
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    /// 生命周期与 Network 回调在同一队列串行执行，stop 返回后旧连接不能再交付帧。
    func start() {
        withQueue {
            guard listener == nil else { return }
            if !isRunning {
                isRunning = true
                generation &+= 1
                retryAttempt = 0
                diagnosticTimes.removeAll()
            }
            retryWork?.cancel()
            retryWork = nil
            startListener(generation: generation)
        }
    }

    func stop() {
        withQueue {
            isRunning = false
            generation &+= 1
            retryWork?.cancel()
            retryWork = nil
            let previous = listener
            listener = nil
            previous?.stateUpdateHandler = nil
            previous?.newConnectionHandler = nil
            previous?.cancel()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func startListener(generation expectedGeneration: UInt64) {
        guard isRunning, generation == expectedGeneration, listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
            // 地址和端口已由本地端点指定；再次传 on: 固定端口会让 Network.framework 抛 EINVAL。
            let current = try makeListener(parameters)
            current.newConnectionHandler = { [weak self, weak current] connection in
                guard let self, let current, self.owns(current, generation: expectedGeneration) else {
                    connection.cancel()
                    return
                }
                self.receiveFrame(from: connection, generation: expectedGeneration)
            }
            current.stateUpdateHandler = { [weak self, weak current] state in
                guard let self, let current, self.owns(current, generation: expectedGeneration) else { return }
                switch state {
                case .ready:
                    self.retryAttempt = 0
                    self.statusHandler?("录屏接收器已就绪")
                case let .failed(error):
                    self.retire(current, generation: expectedGeneration)
                    self.statusHandler?("录屏接收器失败，正在重试：\(error.localizedDescription)")
                case .cancelled:
                    self.retire(current, generation: expectedGeneration)
                default:
                    break
                }
            }
            listener = current
            current.start(queue: queue)
        } catch {
            scheduleRetry(generation: expectedGeneration)
            statusHandler?("无法启动本机画面接收器，正在重试：\(error.localizedDescription)")
        }
    }

    private func owns(_ current: NWListener, generation expectedGeneration: UInt64) -> Bool {
        isRunning && generation == expectedGeneration && listener === current
    }

    private func retire(_ current: NWListener, generation expectedGeneration: UInt64) {
        listener = nil
        current.stateUpdateHandler = nil
        current.newConnectionHandler = nil
        current.cancel()
        scheduleRetry(generation: expectedGeneration)
    }

    /// 临时端口/网络失败可自行恢复；退避最高 2 秒，显式 stop 会取消本代所有重试。
    private func scheduleRetry(generation expectedGeneration: UInt64) {
        guard isRunning, generation == expectedGeneration, retryWork == nil else { return }
        let delay = min(0.25 * pow(2, Double(retryAttempt)), 2)
        retryAttempt = min(retryAttempt + 1, 3)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.generation == expectedGeneration else { return }
            self.retryWork = nil
            self.startListener(generation: expectedGeneration)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receiveFrame(from connection: NWConnection, generation expectedGeneration: UInt64) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        diagnostic("connection", "已连接录屏扩展", interval: 5)
        guard ownsConnection(id, generation: expectedGeneration) else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finishConnection(id) }
        connection.receive(minimumIncompleteLength: FramePacketHeader.byteCount, maximumLength: FramePacketHeader.byteCount) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard self.ownsConnection(id, generation: expectedGeneration) else { self.finishConnection(id); return }
            guard
                error == nil,
                let data,
                let header = FramePacketHeader(data: data),
                self.isAcceptable(header)
            else {
                self.diagnostic("header", "录屏帧头已拒绝：无效、过期或接收失败")
                self.finishConnection(id)
                return
            }
            self.receiveBody(from: connection, id: id, generation: expectedGeneration,
                             remaining: header.payloadSize, collected: Data(), header: header)
        }
    }

    private func receiveBody(from connection: NWConnection, id: UUID, generation expectedGeneration: UInt64,
                             remaining: Int, collected: Data, header: FramePacketHeader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard self.ownsConnection(id, generation: expectedGeneration) else { self.finishConnection(id); return }
            guard error == nil else {
                self.diagnostic("body", "录屏数据接收失败：\(error!.localizedDescription)")
                self.finishConnection(id)
                return
            }
            var next = collected
            if let data { next.append(data) }
            let bytesLeft = remaining - (data?.count ?? 0)
            if bytesLeft > 0, !isComplete {
                self.receiveBody(from: connection, id: id, generation: expectedGeneration,
                                 remaining: bytesLeft, collected: next, header: header)
                return
            }
            self.finishConnection(id)
            guard bytesLeft == 0, self.isAcceptable(header) else {
                self.diagnostic("body", "录屏数据已丢弃：接收不完整或画面过期")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            switch header.kind {
            case .health:
                guard let health = try? JSONDecoder().decode(BroadcastHealth.self, from: next),
                      self.healthFreshness.accept(capturedAt: header.capturedAt, now: now) else {
                    self.diagnostic("health", "录屏扩展状态解码失败")
                    return
                }
                self.healthHandler?(health)
            case .frame:
                guard let source = CGImageSourceCreateWithData(next as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      self.freshness.accept(capturedAt: header.capturedAt, now: ProcessInfo.processInfo.systemUptime) else {
                    self.diagnostic("decode", "录屏画面解码失败或画面已过期")
                    return
                }
                self.frameHandler?(image, header.capturedAt)
                if self.isRunning, self.generation == expectedGeneration {
                    self.diagnostic("frame", "已收到录屏画面 \(image.width)×\(image.height)", interval: 5)
                }
            }
        }
    }

    private func isAcceptable(_ header: FramePacketHeader) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        switch header.kind {
        case .frame: return freshness.isAcceptable(capturedAt: header.capturedAt, now: now)
        case .health: return healthFreshness.isAcceptable(capturedAt: header.capturedAt, now: now)
        }
    }

    /// Diagnostics contain metadata only. Rate-limit each fixed category so 15 Hz input cannot flood UI or disk.
    private func diagnostic(_ key: String, _ message: String, interval: TimeInterval = 1) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (diagnosticTimes[key] ?? -Double.infinity) >= interval else { return }
        diagnosticTimes[key] = now
        statusHandler?(message)
    }

    private func ownsConnection(_ id: UUID, generation expectedGeneration: UInt64) -> Bool {
        isRunning && generation == expectedGeneration && connections[id] != nil
    }

    private func finishConnection(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func withQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return operation() }
        return queue.sync(execute: operation)
    }
}

#endif
