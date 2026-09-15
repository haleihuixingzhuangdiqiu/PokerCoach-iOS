// Adapted from the user-owned XiangqiCoach capture pipeline; see docs/SOURCES.md.
import Foundation

/// 主应用与扩展共用带采集时间的帧头；单调时钟在同一设备的两个进程间保持一致。
struct FramePacketHeader {
    enum Kind { case frame, health }
    static let byteCount = 16
    static let maximumPayloadSize = 1_500_000
    let payloadSize: Int
    let capturedAt: TimeInterval
    let kind: Kind

    var data: Data {
        var result = Data([0x50, 0x43, kind == .frame ? 0x46 : 0x48, 0x31])
        var length = UInt32(payloadSize).bigEndian
        var timestamp = capturedAt.bitPattern.bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }
        return result
    }

    init(payloadSize: Int, capturedAt: TimeInterval, kind: Kind = .frame) {
        self.payloadSize = payloadSize
        self.capturedAt = capturedAt
        self.kind = kind
    }

    init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        switch data.prefix(4) {
        case Data([0x50, 0x43, 0x46, 0x31]): kind = .frame
        case Data([0x50, 0x43, 0x48, 0x31]): kind = .health
        default: return nil
        }
        let bytes = Array(data)
        let length = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let timestamp = Double(bitPattern: bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        guard (1...Self.maximumPayloadSize).contains(Int(length)), timestamp.isFinite, timestamp > 0 else { return nil }
        payloadSize = Int(length)
        capturedAt = timestamp
    }
}

/// One small metadata heartbeat per second, with no captured image or recognized table content.
public struct BroadcastHealth: Codable, Sendable {
    public var frameCount: Int
    public var encodedCount: Int
    public var sentCount: Int
    public var encodeMilliseconds: Double
    public var expiredCount: Int
    public var sendErrorCount: Int
    public var lastError: String
    public init(frameCount: Int = 0, encodedCount: Int = 0, sentCount: Int = 0, encodeMilliseconds: Double = 0,
                expiredCount: Int = 0, sendErrorCount: Int = 0, lastError: String = "") {
        self.frameCount = frameCount; self.encodedCount = encodedCount; self.sentCount = sentCount
        self.encodeMilliseconds = encodeMilliseconds; self.expiredCount = expiredCount
        self.sendErrorCount = sendErrorCount; self.lastError = lastError
    }
}

/// 编码/传输期间只保留一张最新截图；完成后立即消费它，不排队保留旧的 ReplayKit 缓冲。
/// 所有调用由发送方同一把锁保护。generation 使暂停前的编码完成/超时回调不能重新启动旧任务。
struct FrameAdmission<Payload> {
    static var minimumInterval: TimeInterval { 1.0 / 15.0 }
    static var maximumSendAge: TimeInterval { 0.2 }

    struct CapturedFrame {
        let payload: Payload
        let capturedAt: TimeInterval
        let generation: Int
    }

    enum Next {
        case idle
        case wait(TimeInterval)
        case frame(CapturedFrame)
    }

    private(set) var isActive = true
    private(set) var generation = 0
    private var isScheduled = false
    private var pending: CapturedFrame?
    private var lastStartedAt = -Double.infinity

    /// 返回非 nil 时才需要投递一次工作；后续输入仅替换待处理截图，不重复投递闭包。
    mutating func offer(_ payload: Payload, capturedAt: TimeInterval) -> Int? {
        guard isActive, capturedAt.isFinite, capturedAt > 0 else { return nil }
        guard pending == nil || capturedAt > pending!.capturedAt else { return nil }
        pending = CapturedFrame(payload: payload, capturedAt: capturedAt, generation: generation)
        guard !isScheduled else { return nil }
        isScheduled = true
        return generation
    }

    mutating func next(generation expectedGeneration: Int, at now: TimeInterval) -> Next {
        guard expectedGeneration == generation, isActive, isScheduled else { return .idle }
        guard let pending else {
            isScheduled = false
            return .idle
        }
        let age = now - pending.capturedAt
        guard age >= 0, age < Self.maximumSendAge else {
            self.pending = nil
            isScheduled = false
            return .idle
        }
        let delay = lastStartedAt + Self.minimumInterval - now
        guard delay <= 0 else { return .wait(delay) }
        self.pending = nil
        lastStartedAt = now
        return .frame(pending)
    }

    mutating func setActive(_ active: Bool) {
        generation += 1
        isActive = active
        isScheduled = false
        pending = nil
        lastStartedAt = -Double.infinity
    }
}

/// 跨连接乱序或积压的旧画面不得让局面倒退；迟到超过一秒时等待下一张新画面。
struct FrameFreshnessGate {
    private var latestTimestamp = -Double.infinity

    /// 先检查帧头即可拒绝过时数据，不必继续接收大段 JPEG 或浪费解码时间。
    func isAcceptable(capturedAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - capturedAt
        return age >= 0 && age <= 1 && capturedAt > latestTimestamp
    }

    mutating func accept(capturedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard isAcceptable(capturedAt: capturedAt, now: now) else { return false }
        latestTimestamp = capturedAt
        return true
    }
}
