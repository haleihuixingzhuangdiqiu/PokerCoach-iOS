#if os(iOS)
import CoreGraphics
import Foundation
import ReplayKit
import SwiftUI
import Vision

/// Subclass in the Broadcast Upload Extension; reference that subclass in NSExtensionPrincipalClass.
open class PokerBroadcastSampleHandler: RPBroadcastSampleHandler {
    private let sender = FrameSender()
    open override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) { sender.setActive(true) }
    open override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if sampleBufferType == .video { sender.offer(sampleBuffer) }
    }
    open override func broadcastPaused() { sender.setActive(false) }
    open override func broadcastResumed() { sender.setActive(true) }
    open override func broadcastFinished() { sender.setActive(false) }
}

/// Callbacks execute on the receive queue. Dispatch lightweight UI changes to the main actor.
public final class ScreenFrameReceiver {
    private let receiver: FrameReceiver
    public var onFrame: ((CGImage, TimeInterval) -> Void)? { didSet { receiver.onFrame = onFrame } }
    public var onStatus: ((String) -> Void)? { didSet { receiver.onStatus = onStatus } }
    public var onHealth: ((BroadcastHealth) -> Void)? { didSet { receiver.onHealth = onHealth } }
    /// Explicit probes use a separate listener so a running ReplayKit broadcast cannot
    /// mix live-table frames into the supplied-fixture regression stream.
    public init(localProbe: Bool = false) {
        receiver = FrameReceiver(port: localProbe ? FrameReceiver.localProbePort : FrameReceiver.port)
    }
    public func start() { receiver.start() }
    public func stop() { receiver.stop() }
}

/// Explicit local transport regression: uses the production encoder, packet format and TCP sender.
/// Does not start ReplayKit or record other apps. Pair with ScreenFrameReceiver(localProbe: true).
public final class ScreenFrameTransportProbe {
    private let sender = FrameSender(port: FrameReceiver.localProbePort)
    public init() {}
    public func setActive(_ active: Bool) { sender.setActive(active) }
    public func offer(_ image: CGImage) {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: image.width, height: image.height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(pixel, []); return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.flush()
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                                   sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample { sender.offer(sample) }
    }
}

public struct ScreenBroadcastButton: UIViewRepresentable {
    public let extensionBundleIdentifier: String
    public init(extensionBundleIdentifier: String) { self.extensionBundleIdentifier = extensionBundleIdentifier }
    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = extensionBundleIdentifier; picker.showsMicrophoneButton = false
        return picker
    }
    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

public struct TextRegion {
    public let id: String
    /// Vision normalized coordinates, origin at bottom-left AFTER correcting screen orientation.
    public let rect: CGRect
    public init(id: String, rect: CGRect) { self.id = id; self.rect = rect }
}
public struct RecognizedTextField {
    public let id: String
    public let text: String
    /// Vision's candidate score is not a calibrated probability of a correctly recognized field.
    public let visionConfidence: Float
}

/// Generic OCR only. WPK regions and card/suit templates require real captured fixtures.
public final class VisionFieldReader {
    public init() {}
    public func read(_ image: CGImage, regions: [TextRegion]) throws -> [RecognizedTextField] {
        guard regions.count <= 64, regions.allSatisfy({ CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.rect) && !$0.rect.isEmpty }) else {
            throw NSError(domain: "PokerCoachCapture", code: 1)
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let requests = regions.map { region -> VNRecognizeTextRequest in
            let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate
            r.usesLanguageCorrection = false; r.recognitionLanguages = ["en-US", "zh-Hans"]; r.regionOfInterest = region.rect
            return r
        }
        try handler.perform(requests)
        return zip(regions, requests).map { region, request in
            let observations = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            return RecognizedTextField(id: region.id, text: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "),
                                       visionConfidence: observations.compactMap { $0.topCandidates(1).first?.confidence }.min() ?? 0)
        }
    }
}
#endif
