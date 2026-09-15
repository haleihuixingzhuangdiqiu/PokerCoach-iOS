#if canImport(ReplayKit) && canImport(CoreImage) && canImport(Network)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network
import ReplayKit
import XCTest
@testable import PokerCoachCapture

final class SenderTransportTests: XCTestCase {
    func testExplicitProbeAndDefaultProductionStreamsStayOnSeparateTCPPorts() throws {
        let production = FrameReceiver()
        let probe = FrameReceiver(port: FrameReceiver.localProbePort)
        let productionFeeder = ProductionSenderFeeder()
        let probeFeeder = ProductionSenderFeeder(port: FrameReceiver.localProbePort)
        defer { productionFeeder.stop(); probeFeeder.stop(); production.stop(); probe.stop() }
        try start(production)
        try start(probe, expectedPort: 43_983)
        XCTAssertNotEqual(production.listeningPort, probe.listeningPort)
        let productionEvidence = SenderStreamEvidence(), probeEvidence = SenderStreamEvidence()
        let productionFrames = expectation(description: "Default production stream remains on 43982")
        let probeFrames = expectation(description: "Explicit fixture stream arrives separately on 43983")
        production.onFrame = { image, timestamp in
            XCTAssertEqual(image.height, 1440, "The small probe image must never reach the production listener")
            if productionEvidence.append(image: image, timestamp: timestamp) == 3 { productionFrames.fulfill() }
        }
        probe.onFrame = { image, timestamp in
            XCTAssertEqual(image.height, 780, "The production screenshot must never reach the probe listener")
            if probeEvidence.append(image: image, timestamp: timestamp) == 3 { probeFrames.fulfill() }
        }
        productionFeeder.stream(try makeBGRASample(width: 720, height: 1564), count: 12, framesPerSecond: 15)
        probeFeeder.stream(try makeBGRASample(width: 360, height: 780), count: 12, framesPerSecond: 15)
        wait(for: [productionFrames, probeFrames], timeout: 3)
        XCTAssertGreaterThanOrEqual(productionEvidence.snapshot.frames.count, 3)
        XCTAssertGreaterThanOrEqual(probeEvidence.snapshot.frames.count, 3)
    }

    func testProductionSenderStreamsPhoneSizeFramesAndHealthOverRealTCP() throws {
        let receiver = FrameReceiver() // Production 43982, not a test-only injected port.
        let feeder = ProductionSenderFeeder()
        defer { feeder.stop(); receiver.stop() }
        try start(receiver)
        let evidence = SenderStreamEvidence()
        let frames = expectation(description: "Twelve real encoded phone-size images decoded")
        let health = expectation(description: "Production heartbeat reports offered, encoded and sent frames")
        let image = try makeBGRASample(width: 1320, height: 2868)
        receiver.onFrame = { image, timestamp in
            let count = evidence.append(image: image, timestamp: timestamp)
            if count == 12 { frames.fulfill() }
        }
        receiver.onHealth = { snapshot in
            if evidence.record(snapshot), snapshot.frameCount >= 50, snapshot.sentCount >= 12 { health.fulfill() }
        }
        feeder.stream(image, count: 60, framesPerSecond: 30)
        wait(for: [frames, health], timeout: 5)
        feeder.stop()
        let snapshot = evidence.snapshot
        XCTAssertGreaterThanOrEqual(snapshot.frames.count, 12)
        XCTAssertGreaterThan((snapshot.frames.last?.timestamp ?? 0) - (snapshot.frames.first?.timestamp ?? 0), 0.6)
        XCTAssertTrue(zip(snapshot.frames, snapshot.frames.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        XCTAssertTrue(snapshot.frames.allSatisfy { $0.height == 1440 && (662...664).contains($0.width) })
        XCTAssertTrue(snapshot.frames.allSatisfy { $0.averageChannel > 0.1 && $0.colorSpread > 0.15 }, "Decoded image must retain nonblack, varied color content")
        let metadata = try XCTUnwrap(snapshot.health.last)
        XCTAssertGreaterThanOrEqual(metadata.frameCount, 50)
        XCTAssertGreaterThanOrEqual(metadata.encodedCount, metadata.sentCount)
        XCTAssertGreaterThanOrEqual(metadata.sentCount, 12)
        XCTAssertEqual(metadata.sendErrorCount, 0)
        XCTAssertTrue(metadata.lastError.isEmpty)
        print("Sender stream: offered=\(metadata.frameCount), encoded=\(metadata.encodedCount), sent=\(metadata.sentCount), received=\(snapshot.frames.count), expired=\(metadata.expiredCount), sendErrors=\(metadata.sendErrorCount), lastEncodeMs=\(metadata.encodeMilliseconds)")
    }

    func testProductionSenderEncodesBiPlanarVideoAndAppliesReplayKitOrientation() throws {
        let receiver = FrameReceiver()
        let feeder = ProductionSenderFeeder()
        defer { feeder.stop(); receiver.stop() }
        try start(receiver)
        let evidence = SenderStreamEvidence()
        let frames = expectation(description: "Actual NV12 JPEG honors ReplayKit rotation")
        let sample = try makeBiPlanarSample(width: 1564, height: 720)
        CMSetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                        value: NSNumber(value: CGImagePropertyOrientation.right.rawValue), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        receiver.onFrame = { image, timestamp in
            if evidence.append(image: image, timestamp: timestamp) == 3 { frames.fulfill() }
        }
        feeder.stream(sample, count: 12, framesPerSecond: 15)
        wait(for: [frames], timeout: 3)
        feeder.stop()
        let images = evidence.snapshot.frames
        XCTAssertGreaterThanOrEqual(images.count, 3)
        XCTAssertTrue(images.allSatisfy { $0.height == 1440 && (662...664).contains($0.width) })
        XCTAssertTrue(images.allSatisfy { $0.averageChannel > 0.1 && $0.colorSpread > 0.15 })
    }

    private func start(_ receiver: FrameReceiver, expectedPort: NWEndpoint.Port = 43_982) throws {
        let ready = expectation(description: "Receiver bound 127.0.0.1:\(expectedPort)")
        receiver.onStatus = { status in
            if status == "录屏接收器已就绪" { ready.fulfill() }
            if status.contains("失败") || status.contains("无法启动") { XCTFail(status) }
        }
        receiver.start()
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(try XCTUnwrap(receiver.listeningPort), expectedPort)
    }

    private func makeBGRASample(width: Int, height: Int) throws -> CMSampleBuffer {
        let pixel = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        let side = 96
        for y in stride(from: 0, to: height, by: side) {
            for x in stride(from: 0, to: width, by: side) {
                let index = (x / side + y / side) % 3
                let colors: [CGColor] = [CGColor(red: 0.95, green: 0.1, blue: 0.2, alpha: 1),
                                         CGColor(red: 0.1, green: 0.85, blue: 0.3, alpha: 1),
                                         CGColor(red: 0.2, green: 0.3, blue: 0.95, alpha: 1)]
                context.setFillColor(colors[index])
                context.fill(CGRect(x: x, y: y, width: side, height: side))
            }
        }
        context.flush()
        return try sampleBuffer(pixel)
    }

    private func makeBiPlanarSample(width: Int, height: Int) throws -> CMSampleBuffer {
        let pixel = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 1)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = luma.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0))
            for x in 0..<width { row[x] = x < width / 2 ? 180 : 70 }
        }
        for y in 0..<height / 2 {
            let row = chroma.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1))
            for x in stride(from: 0, to: width, by: 2) { row[x] = 90; row[x + 1] = 190 }
        }
        return try sampleBuffer(pixel)
    }

    private func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &result), kCVReturnSuccess)
        return try XCTUnwrap(result)
    }

    private func sampleBuffer(_ pixel: CVPixelBuffer) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                                   formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let format = try XCTUnwrap(description)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                               formatDescription: format, sampleTiming: &timing,
                                                               sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }
}

/// A test producer drives the public production sender methods, without replacing JPEG or sockets.
private final class ProductionSenderFeeder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "poker.sender-tests.producer")
    private let sender: FrameSender
    private var timer: DispatchSourceTimer?
    init() { sender = FrameSender() }
    init(port: NWEndpoint.Port) { sender = FrameSender(port: port) }
    func stream(_ sample: CMSampleBuffer, count: Int, framesPerSecond: Int) {
        queue.sync {
            sender.setActive(true)
            var remaining = count
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1 / Double(framesPerSecond))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.sender.offer(sample)
                remaining -= 1
                if remaining == 0 { self.timer?.cancel(); self.timer = nil }
            }
            timer = source
            source.resume()
        }
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil; sender.setActive(false) } }
}

private final class SenderStreamEvidence: @unchecked Sendable {
    struct Frame {
        let width: Int; let height: Int; let timestamp: TimeInterval
        let averageChannel: Double; let colorSpread: Double
    }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var health: [BroadcastHealth] = []
    private var fulfilledHealth = false
    func append(image: CGImage, timestamp: TimeInterval) -> Int {
        var average = 0.0, spread = 0.0
        if let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8 * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
                var low = UInt8.max, high = UInt8.min, sum = 0
                for pixel in 0..<64 { for channel in 0..<3 {
                    let value = pixels[pixel * 4 + channel]
                    low = min(low, value); high = max(high, value); sum += Int(value)
                } }
                average = Double(sum) / (64 * 3 * 255)
                spread = Double(high - low) / 255
            }
        }
        lock.lock(); defer { lock.unlock() }
        frames.append(Frame(width: image.width, height: image.height, timestamp: timestamp,
                            averageChannel: average, colorSpread: spread))
        return frames.count
    }
    func record(_ snapshot: BroadcastHealth) -> Bool {
        lock.lock(); defer { lock.unlock() }
        health.append(snapshot)
        guard !fulfilledHealth, snapshot.frameCount >= 50, snapshot.sentCount >= 12 else { return false }
        fulfilledHealth = true
        return true
    }
    var snapshot: (frames: [Frame], health: [BroadcastHealth]) {
        lock.lock(); defer { lock.unlock() }; return (frames, health)
    }
}
#endif
