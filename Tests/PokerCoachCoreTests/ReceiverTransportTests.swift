#if canImport(Network) && canImport(ImageIO)
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import XCTest
@testable import PokerCoachCapture

final class ReceiverTransportTests: XCTestCase {
    func testFixedPortFragmentedFirstJPEGReachesReceiver() throws {
        // A real nonzero local port exercises the same binding path as the iOS App.
        let receiver = FrameReceiver(port: 43_992)
        defer { receiver.stop() }
        let port = try start(receiver)
        XCTAssertEqual(port, NWEndpoint.Port(rawValue: 43_992))
        let jpeg = try makeJPEG()
        let timestamp = ProcessInfo.processInfo.systemUptime
        let header = FramePacketHeader(payloadSize: jpeg.count, capturedAt: timestamp).data
        try assertReceives(receiver, port: port, timestamp: timestamp,
                           fragments: [Data(header.prefix(3)), Data(header.dropFirst(3)),
                                       Data(jpeg.prefix(13)), Data(jpeg.dropFirst(13))])
    }

    func testStopThenStartReceivesNewFrame() throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        var port = try start(receiver)
        try assertReceivesJPEG(receiver, port: port)
        receiver.stop()
        XCTAssertNil(receiver.listeningPort)
        port = try start(receiver)
        try assertReceivesJPEG(receiver, port: port)
    }

    func testOccupiedPortAutomaticallyRecoversWithoutStartAgain() throws {
        let blocker = try makeBlockingListener()
        defer { blocker.cancel() }
        let port = try XCTUnwrap(blocker.port)
        let receiver = FrameReceiver(port: port)
        defer { receiver.stop() }
        let failed = expectation(description: "Real occupied port reports failure")
        let recovered = expectation(description: "Released port recovers without another start")
        receiver.onStatus = { status in
            if status.contains("失败") || status.contains("无法启动") {
                failed.fulfill()
                blocker.cancel()
            }
            if status == "录屏接收器已就绪" { recovered.fulfill() }
        }
        receiver.start()
        wait(for: [failed, recovered], timeout: 3, enforceOrder: true)
        XCTAssertEqual(receiver.listeningPort, port)
        guard receiver.listeningPort != nil else { return }
        try assertReceivesJPEG(receiver, port: port)
    }

    func testConstructorFailureRetriesAndReceivesRealJPEG() throws {
        let probe = ReceiverListenerProbe()
        let receiver = FrameReceiver(port: .any, makeListener: { parameters in
            if probe.recordAttempt() == 1 { throw NWError.posix(.EMFILE) }
            return try NWListener(using: parameters)
        })
        defer { receiver.stop() }
        let failed = expectation(description: "Constructor error reported")
        let ready = expectation(description: "Constructor error recovered automatically")
        receiver.onStatus = { status in
            if status.contains("无法启动") { failed.fulfill() }
            if status == "录屏接收器已就绪" { ready.fulfill() }
        }
        receiver.start()
        wait(for: [failed, ready], timeout: 2, enforceOrder: true)
        XCTAssertEqual(probe.attemptCount, 2)
        try assertReceivesJPEG(receiver, port: XCTUnwrap(receiver.listeningPort))
    }

    func testStopCancelsConstructorRetryAndExplicitRestartWorks() throws {
        let probe = ReceiverListenerProbe()
        let receiver = FrameReceiver(port: .any, makeListener: { parameters in
            if probe.recordAttempt() == 1 { throw NWError.posix(.EADDRINUSE) }
            return try NWListener(using: parameters)
        })
        defer { receiver.stop() }
        let failed = expectation(description: "Constructor failed")
        let unwantedReady = expectation(description: "Stopped generation cannot restart")
        unwantedReady.isInverted = true
        receiver.onStatus = { [weak receiver] status in
            if status.contains("无法启动") { receiver?.stop(); failed.fulfill() }
            if status == "录屏接收器已就绪" { unwantedReady.fulfill() }
        }
        receiver.start()
        wait(for: [failed], timeout: 1)
        wait(for: [unwantedReady], timeout: 0.6)
        XCTAssertEqual(probe.attemptCount, 1)
        XCTAssertNil(receiver.listeningPort)
        let port = try start(receiver)
        XCTAssertEqual(probe.attemptCount, 2)
        try assertReceivesJPEG(receiver, port: port)
    }

    func testLateOldListenerCallbackCannotRetireReplacement() throws {
        let probe = ReceiverListenerProbe()
        let receiver = FrameReceiver(port: .any, makeListener: { parameters in
            let listener = try NWListener(using: parameters)
            probe.append(listener)
            return listener
        })
        defer { receiver.stop() }
        _ = try start(receiver)
        let previous = try XCTUnwrap(probe.listeners.first)
        let delayedState = try XCTUnwrap(previous.stateUpdateHandler)
        receiver.stop()
        let replacementReady = expectation(description: "Replacement survives queued old state events")
        receiver.onStatus = { [weak receiver] status in
            guard status == "录屏接收器已就绪", let receiver else { return }
            let replacementPort = receiver.listeningPort
            // Reproduce an already-queued old callback on the actual listener queue.
            delayedState(.failed(.posix(.ECANCELED)))
            delayedState(.cancelled)
            XCTAssertEqual(receiver.listeningPort, replacementPort)
            XCTAssertNotNil(receiver.listeningPort)
            receiver.start()
            XCTAssertEqual(probe.listeners.count, 2)
            replacementReady.fulfill()
        }
        receiver.start()
        wait(for: [replacementReady], timeout: 2)
        try assertReceivesJPEG(receiver, port: XCTUnwrap(receiver.listeningPort))
    }

    func testHealthArrivingFirstDoesNotRejectAnOlderFreshImage() throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        let port = try start(receiver)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let health = BroadcastHealth(frameCount: 15, encodedCount: 2, sentCount: 1, encodeMilliseconds: 32,
                                     expiredCount: 1, sendErrorCount: 0, lastError: "")
        let data = try JSONEncoder().encode(health)
        let delivered = expectation(description: "Health metadata decoded on independent timeline")
        receiver.onHealth = { decoded in
            XCTAssertEqual(decoded.frameCount, 15)
            XCTAssertEqual(decoded.sentCount, 1)
            XCTAssertEqual(decoded.encodeMilliseconds, 32)
            delivered.fulfill()
        }
        try transmit([FramePacketHeader(payloadSize: data.count, capturedAt: timestamp, kind: .health).data, data], to: port)
        wait(for: [delivered], timeout: 1)
        let jpeg = try makeJPEG()
        let imageTimestamp = timestamp - 0.01
        try assertReceives(receiver, port: port, timestamp: imageTimestamp,
                           fragments: [FramePacketHeader(payloadSize: jpeg.count, capturedAt: imageTimestamp).data, jpeg])
    }

    func testInvalidHealthDoesNotAdvanceHealthTimelineOrReachImageCallback() throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        let port = try start(receiver)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let bad = Data("not-json".utf8)
        receiver.onFrame = { _, _ in XCTFail("Health data must never enter the card image callback") }
        receiver.onStatus = { _ in } // This test deliberately supplies malformed metadata.
        try transmit([FramePacketHeader(payloadSize: bad.count, capturedAt: timestamp, kind: .health).data, bad], to: port)
        let good = try JSONEncoder().encode(BroadcastHealth(frameCount: 2))
        let delivered = expectation(description: "Valid health after failed decode at identical timestamp")
        receiver.onHealth = { health in XCTAssertEqual(health.frameCount, 2); delivered.fulfill() }
        try transmit([FramePacketHeader(payloadSize: good.count, capturedAt: timestamp, kind: .health).data, good], to: port)
        wait(for: [delivered], timeout: 1)
    }

    func testStaleHeaderClosesBeforeWaitingForBody() throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        let port = try start(receiver)
        receiver.onFrame = { _, _ in XCTFail("Expired frame must not be delivered") }
        receiver.onStatus = { _ in }
        let timestamp = ProcessInfo.processInfo.systemUptime - 2
        let header = FramePacketHeader(payloadSize: 1_000_000, capturedAt: timestamp).data
        let transmission = ReceiverLoopbackTransmission(port: port, fragments: [header])
        let closed = expectation(description: "Invalid header closes before the one-second watchdog")
        transmission.start { error in if let error { XCTFail(error.localizedDescription) }; closed.fulfill() }
        wait(for: [closed], timeout: 0.75)
    }

    private func start(_ receiver: FrameReceiver) throws -> NWEndpoint.Port {
        let ready = expectation(description: "Real loopback listener ready")
        receiver.onStatus = { status in
            if status == "录屏接收器已就绪" { ready.fulfill() }
            if status.contains("失败") || status.contains("无法启动") { XCTFail(status) }
        }
        receiver.start()
        wait(for: [ready], timeout: 2)
        return try XCTUnwrap(receiver.listeningPort)
    }

    private func makeBlockingListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Real blocking listener ready")
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
            if case let .failed(error) = state { XCTFail(error.localizedDescription) }
        }
        listener.start(queue: DispatchQueue(label: "poker.receiver-tests.blocker"))
        wait(for: [ready], timeout: 2)
        return listener
    }

    private func assertReceivesJPEG(_ receiver: FrameReceiver, port: NWEndpoint.Port) throws {
        let jpeg = try makeJPEG()
        let timestamp = ProcessInfo.processInfo.systemUptime
        try assertReceives(receiver, port: port, timestamp: timestamp,
                           fragments: [FramePacketHeader(payloadSize: jpeg.count, capturedAt: timestamp).data, jpeg])
    }

    private func assertReceives(_ receiver: FrameReceiver, port: NWEndpoint.Port, timestamp: TimeInterval,
                                fragments: [Data]) throws {
        let delivered = expectation(description: "Actual TCP JPEG decoded")
        let received = ReceivedFrameEvidence()
        receiver.onFrame = { image, capturedAt in
            received.append(width: image.width, height: image.height, timestamp: capturedAt)
            delivered.fulfill()
        }
        let transmission = ReceiverLoopbackTransmission(port: port, fragments: fragments)
        let closed = expectation(description: "Server closed the consumed connection")
        transmission.start { error in
            if let error { XCTFail(error.localizedDescription) }
            closed.fulfill()
        }
        wait(for: [delivered, closed], timeout: 3)
        let frames = received.snapshot
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.width, 18)
        XCTAssertEqual(frames.first?.height, 12)
        XCTAssertEqual(frames.first?.timestamp, timestamp)
    }

    private func transmit(_ fragments: [Data], to port: NWEndpoint.Port) throws {
        let transmission = ReceiverLoopbackTransmission(port: port, fragments: fragments)
        let closed = expectation(description: "Actual server closed the test TCP connection")
        transmission.start { error in if let error { XCTFail(error.localizedDescription) }; closed.fulfill() }
        wait(for: [closed], timeout: 3)
    }

    private func makeJPEG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 18, height: 12, bitsPerComponent: 8,
                                              bytesPerRow: 18 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 18, height: 12))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class ReceivedFrameEvidence: @unchecked Sendable {
    struct Frame { let width: Int; let height: Int; let timestamp: TimeInterval }
    private let lock = NSLock()
    private var frames: [Frame] = []
    func append(width: Int, height: Int, timestamp: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        frames.append(Frame(width: width, height: height, timestamp: timestamp))
    }
    var snapshot: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
}

private final class ReceiverListenerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NWListener] = []
    private var attempts = 0
    func append(_ listener: NWListener) { lock.lock(); defer { lock.unlock() }; storage.append(listener) }
    func recordAttempt() -> Int { lock.lock(); defer { lock.unlock() }; attempts += 1; return attempts }
    var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var listeners: [NWListener] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// The server's EOF/RST is the completion barrier; no direct callback or mocked transport.
private final class ReceiverLoopbackTransmission: @unchecked Sendable {
    private let connection: NWConnection
    private let fragments: [Data]
    private let queue = DispatchQueue(label: "poker.receiver-tests.client")
    private var connected = false
    private var completion: (@Sendable (Error?) -> Void)?
    init(port: NWEndpoint.Port, fragments: [Data]) {
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.fragments = fragments
    }
    func start(completion: @escaping @Sendable (Error?) -> Void) {
        self.completion = completion
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connected = true; self.receiveClose(); self.sendFragment(0)
            case let .failed(error): self.finish(self.connected ? nil : error)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finish(NSError(domain: "ReceiverTransportTests", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Server did not close the TCP connection"]))
        }
    }
    private func sendFragment(_ index: Int) {
        guard completion != nil, fragments.indices.contains(index) else { return }
        connection.send(content: fragments[index], isComplete: index == fragments.count - 1,
                        completion: .contentProcessed { error in
            if error == nil { self.sendFragment(index + 1) }
        })
    }
    private func receiveClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            if complete || error != nil { self.finish(nil) } else { self.receiveClose() }
        }
    }
    private func finish(_ error: Error?) {
        guard let completion else { return }
        self.completion = nil; connection.stateUpdateHandler = nil; connection.cancel(); completion(error)
    }
}
#endif
