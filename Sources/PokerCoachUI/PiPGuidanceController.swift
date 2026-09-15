#if os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import CoreImage
import SwiftUI
import UIKit
import PokerCoachCore

/// System PiP lifecycle and tiny two-line guidance surface. iOS controls its position and size.
@MainActor
public final class PiPGuidanceController: NSObject, ObservableObject {
    @Published public private(set) var active = false
    @Published public private(set) var possible = false
    @Published public private(set) var error: String?
    private var controller: AVPictureInPictureController?
    private weak var view: GuidanceVideoView?
    private var timer: Timer?
    private var status = GuidanceStatus.waiting
    private var action: String?
    private var readout: (title: String, subtitle: String)?
    private var validThrough = 0.0
    private var updatedAt = Date()
    private var cachedKey = ""
    private var cachedBuffer: CVPixelBuffer?
    private var generatedImage: UIImage?
    private var lastDisplayFailure: String?
    private var readinessObservation: NSKeyValueObservation?
    private var startDeadline: Double?
    private var startIssued = false
    private var lifecycle: [String] = []
    private var showsIdleScreen = true
    private var renderedTitle = ""
    private var renderedSubtitle = ""
    private var renderSchedule = GuidanceRenderSchedule()
    private var enqueuedFrames = 0
    private var backpressureSkips = 0
    private var failureFlushes = 0
    private let diagnosticSessionID = UUID().uuidString
    private var lastEnqueuedAt: Double?
    private var pendingStopReason: String?
    private var lastStopRequestReason: String?
    private var lastStopRequestAt: Double?
    private var lastStopAt: Double?
    private var lastStopClassification = "none"
    /// Main-actor callback for the host to persist critical lifecycle events immediately.
    /// Reading debugSnapshot here is side-effect free; it never renders or restarts PiP.
    public var onDiagnosticEvent: ((String) -> Void)?

    /// JSON-compatible normal-operation evidence, without capturing the screen or needing a probe.
    /// The host owns persistence, including retaining this snapshot across process restarts.
    public var debugSnapshot: [String: Any] {
        let now = ProcessInfo.processInfo.systemUptime
        let renderer = view?.display.sampleBufferRenderer
        return [
            "sessionID": diagnosticSessionID, "uptime": now,
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
            "active": active, "possible": possible, "controllerAttached": controller != nil,
            "controllerActive": controller?.isPictureInPictureActive == true,
            "controllerPossible": controller?.isPictureInPicturePossible == true,
            "controllerSuspended": controller?.isPictureInPictureSuspended == true,
            "automaticStartEnabled": controller?.canStartPictureInPictureAutomaticallyFromInline == true,
            "startIssued": startIssued, "startPending": startDeadline != nil,
            "startDeadlineRemaining": startDeadline.map { $0 - now } ?? -1,
            "pendingStopReason": pendingStopReason ?? "",
            "lastStopRequestReason": lastStopRequestReason ?? "",
            "lastStopRequestAge": lastStopRequestAt.map { now - $0 } ?? -1,
            "lastStopAge": lastStopAt.map { now - $0 } ?? -1,
            "lastStopClassification": lastStopClassification,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "viewAttached": view != nil, "viewInWindow": view?.window != nil,
            "displayStatus": renderer?.status.rawValue ?? -1,
            "displayError": renderer?.error.map(String.init(describing:)) ?? "",
            "requiresFlush": renderer?.requiresFlushToResumeDecoding == true,
            "readyForMoreMediaData": renderer?.isReadyForMoreMediaData == true,
            "lastDisplayFailure": lastDisplayFailure ?? "", "controllerError": error ?? "",
            "enqueuedFrames": enqueuedFrames, "backpressureSkips": backpressureSkips,
            "failureFlushes": failureFlushes, "lastEnqueuedAge": lastEnqueuedAt.map { now - $0 } ?? -1,
            "idleScreen": showsIdleScreen, "readoutValid": validThrough >= now,
            "renderedTitle": renderedTitle, "renderedSubtitle": renderedSubtitle,
            "lifecycle": lifecycle
        ]
    }

    public override init() { super.init(); configureAudioSession() }
    private func trace(_ event: String) {
        lifecycle.append(String(format: "%.3f %@ %@", ProcessInfo.processInfo.systemUptime,
                                ISO8601DateFormatter().string(from: Date()), event))
        if lifecycle.count > 64 { lifecycle.removeFirst(lifecycle.count - 64) }
        onDiagnosticEvent?(event)
    }
    private func recordStopRequest(_ reason: String) {
        pendingStopReason = reason; lastStopRequestReason = reason
        lastStopRequestAt = ProcessInfo.processInfo.systemUptime
        trace("stop requested: " + reason)
    }
    private func configureAudioSession() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try audio.setActive(true)
        } catch { self.error = error.localizedDescription; trace("audio session failed: " + error.localizedDescription) }
    }
    public func update(status: GuidanceStatus, action: String?, validThrough: Double) {
        readout = nil
        self.status = status; self.action = action; self.validThrough = validThrough; updatedAt = Date()
        render()
    }
    /// Descriptive card analysis does not mark the action ledger complete or authorize a bet.
    public func updateReadout(title: String, subtitle: String, validThrough: Double) {
        status = .waiting; action = nil; readout = (title, subtitle); self.validThrough = validThrough
        render()
    }
    public func setIdleScreen(_ idle: Bool) {
        guard showsIdleScreen != idle else { return }
        showsIdleScreen = idle; cachedBuffer = nil; render()
    }
    func attach(_ view: GuidanceVideoView) {
        guard self.view !== view || controller == nil else { return }
        readinessObservation?.invalidate()
        if controller != nil { recordStopRequest("view-reattached") }
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        pendingStopReason = nil
        startIssued = false
        self.view = view
        renderSchedule.reset()
        trace("attach")
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.display, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self; controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            self.controller = controller
            readinessObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] source, _ in
                let identity = ObjectIdentifier(source)
                Task { @MainActor in
                    guard let self, let current = self.controller, ObjectIdentifier(current) == identity else { return }
                    self.possible = current.isPictureInPicturePossible
                    self.active = current.isPictureInPictureActive
                    self.trace("possible=\(self.possible) active=\(self.active)")
                    self.attemptStart()
                }
            }
        }
        // Immediate state frames use the renderer's own timebase. Do not replace
        // the playback timebase after constructing the system PiP content source.
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render(); self?.attemptStart() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        render()
    }
    public func start() {
        guard !active, startDeadline == nil else { trace("start ignored: active or already pending"); return }
        guard controller != nil else { error = "当前设备的画中画不可用"; trace("start unavailable: missing controller"); return }
        error = nil
        configureAudioSession()
        guard error == nil else { return }
        pendingStopReason = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        startDeadline = ProcessInfo.processInfo.systemUptime + 10
        startIssued = false
        trace("start requested possible=\(controller?.isPictureInPicturePossible == true)")
        render(); attemptStart()
    }
    private func attemptStart() {
        guard let deadline = startDeadline, !active else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        if ProcessInfo.processInfo.systemUptime > deadline {
            trace("timeout issued=\(startIssued) possible=\(controller?.isPictureInPicturePossible == true)")
            startDeadline = nil; startIssued = false; recordStopRequest("start-timeout")
            controller?.stopPictureInPicture()
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            error = "悬浮画面暂未就绪，请保持 App 在前台后重试"; return
        }
        guard !startIssued, UIApplication.shared.applicationState == .active,
              let controller, controller.isPictureInPicturePossible else { return }
        startIssued = true; trace("start issued"); controller.startPictureInPicture()
    }
    public func stop(reason: String = "app-stop") {
        startDeadline = nil; startIssued = false; recordStopRequest(reason)
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
    }
    /// Withdraw an unfulfilled automatic start when the capture connection disappears.
    /// An already active window and a user's explicit close choice remain separate.
    @discardableResult
    public func cancelPendingStart() -> Bool {
        guard !active, startDeadline != nil else { return false }
        startDeadline = nil; startIssued = false
        recordStopRequest("pending-start-lost-capture")
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
        return true
    }
    public func tearDown() {
        stop(reason: "teardown"); timer?.invalidate(); timer = nil; readinessObservation?.invalidate()
        readinessObservation = nil; controller?.delegate = nil; controller = nil; cachedBuffer = nil
        renderSchedule.reset()
        trace("torn down")
    }

    private func render() {
        guard let view else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = now <= validThrough
        let ready = (status == .ready || readout != nil) && fresh
        let title = fresh && readout != nil ? readout!.title : (ready ? (action ?? "分析中…") : (fresh ? status.rawValue : (validThrough == 0 ? "等待牌桌" : "等待新画面")))
        let timestamp = updatedAt.formatted(.dateTime.hour().minute().second())
        let subtitle = fresh && readout != nil ? readout!.subtitle : (ready ? "\(timestamp) · 研究估计" : (validThrough == 0 ? "请先开始录屏" : "确认牌面后更新"))
        // Include all visible properties, but never validity timestamps: a fresh observation
        // with the same text only extends its lifetime. The timer still notices expiry.
        let key = showsIdleScreen ? "idle-white" : "\(ready)|\(title)\u{0}\(subtitle)"
        let renderer = view.display.sampleBufferRenderer
        if renderer.status == .failed {
            let failure = renderer.error.map(String.init(describing:)) ?? "renderer failed without NSError"
            let changed = failure != lastDisplayFailure
            lastDisplayFailure = failure
            renderer.flush(); failureFlushes += 1; renderSchedule.reset()
            if changed || failureFlushes == 1 { trace("renderer failed and flushed: " + failure) }
        }
        guard renderSchedule.shouldSubmit(key: key, now: now) else { return }
        // Ordinary backpressure is not a decoder failure. Keep the current displayed image
        // and the latest readout; the next timer tick retries without flushing the queue.
        guard renderer.isReadyForMoreMediaData else { backpressureSkips += 1; return }
        if cachedKey != key || cachedBuffer == nil {
            cachedBuffer = makePixels(title: title, subtitle: subtitle, ready: ready); cachedKey = key
        }
        guard let pixels = cachedBuffer else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        // These are irregular live UI updates. Display the newest state immediately;
        // attaching this flag to the sample (not the whole buffer) is required by CoreMedia.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        renderSchedule.didSubmit(key: key, at: now); enqueuedFrames += 1
        lastEnqueuedAt = now
        renderedTitle = title; renderedSubtitle = subtitle
    }

    /// Explicit local regression only; saves this App's generated video, never the captured phone screen.
    public func exportRenderProbe(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let view else { throw NSError(domain: "PokerCoachPiP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display view is missing"]) }
        let layer = view.display
        var report: [String: Any] = [
            "viewInWindow": view.window != nil, "viewWidth": view.bounds.width, "viewHeight": view.bounds.height,
            "pipPossible": controller?.isPictureInPicturePossible == true, "pipActive": active,
            "displayStatus": layer.sampleBufferRenderer.status.rawValue, "displayError": layer.sampleBufferRenderer.error.map(String.init(describing:)) ?? "",
            "lastDisplayFailure": lastDisplayFailure ?? "", "controllerError": error ?? "",
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "startIssued": startIssued,
            "startPending": startDeadline != nil,
            "controllerActive": controller?.isPictureInPictureActive == true,
            "enqueuedFrames": enqueuedFrames, "backpressureSkips": backpressureSkips,
            "failureFlushes": failureFlushes,
            "lifecycle": lifecycle,
            "debugSnapshot": debugSnapshot,
            "inputHasIOSurface": cachedBuffer.flatMap { CVPixelBufferGetIOSurface($0) } != nil,
            "generatedFrame": cachedBuffer != nil
        ]
        report["readoutTitle"] = readout?.title ?? ""
        report["readoutSubtitle"] = readout?.subtitle ?? ""
        report["renderedTitle"] = renderedTitle
        report["renderedSubtitle"] = renderedSubtitle
        func save(_ buffer: CVPixelBuffer, name: String) throws {
            let input = CIImage(cvPixelBuffer: buffer)
            guard let cg = CIContext().createCGImage(input, from: input.extent), let data = UIImage(cgImage: cg).pngData() else { return }
            try data.write(to: directory.appendingPathComponent(name))
        }
        if let buffer = cachedBuffer { try save(buffer, name: "generated.png") }
        if let data = generatedImage?.pngData() { try data.write(to: directory.appendingPathComponent("uikit-source.png")) }
        if #available(iOS 17.4, *) {
            report["readyForDisplay"] = layer.isReadyForDisplay
            let timebase = layer.sampleBufferRenderer.timebase
            let oldRate = CMTimebaseGetRate(timebase)
            CMTimebaseSetRate(timebase, rate: 0)
            try? await Task.sleep(for: .milliseconds(120))
            let displayed = layer.sampleBufferRenderer.displayedPixelBuffer()
            CMTimebaseSetRate(timebase, rate: oldRate)
            report["copiedDisplayedFrame"] = displayed != nil
            if let displayed { try save(displayed, name: "displayed.png") }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("render.json"))
    }
    private func makePixels(title: String, subtitle: String, ready: Bool) -> CVPixelBuffer? {
        let size = CGSize(width: 360, height: 104)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { c in
            if showsIdleScreen {
                UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size)); return
            }
            UIColor(red: 0.04, green: 0.09, blue: 0.10, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
            let titleColor = ready ? UIColor(red: 0.59, green: 0.96, blue: 0.77, alpha: 1) : UIColor.white
            func line(_ text: String, rect: CGRect, size: CGFloat, minimum: CGFloat, weight: UIFont.Weight, color: UIColor) {
                var fontSize = size
                while fontSize > minimum && (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: weight)]).width > rect.width { fontSize -= 1 }
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (text as NSString).draw(in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
            }
            line(title, rect: CGRect(x: 18, y: 10, width: 324, height: 36), size: 29, minimum: 21, weight: .bold, color: titleColor)
            let details = subtitle.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if details.count == 2 {
                line(String(details[0]), rect: CGRect(x: 19, y: 52, width: 322, height: 20), size: 15, minimum: 12, weight: .regular, color: .lightGray)
                line(String(details[1]), rect: CGRect(x: 19, y: 76, width: 322, height: 18), size: 13, minimum: 11, weight: .regular, color: .lightGray)
            } else {
                line(subtitle, rect: CGRect(x: 19, y: 64, width: 322, height: 24), size: 15, minimum: 12, weight: .regular, color: .lightGray)
            }
        }
        generatedImage = image
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer, let cgImage = image.cgImage else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        c.draw(cgImage, in: CGRect(origin: .zero, size: size))
        // Complete CPU writes before unlocking the IOSurface for the display renderer.
        c.flush()
        return buffer
    }
}

extension PiPGuidanceController: @preconcurrency AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }; trace("will start")
    }
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        guard startDeadline != nil else {
            recordStopRequest("late-start-after-cancel")
            pictureInPictureController.stopPictureInPicture(); return
        }
        active = true; startDeadline = nil; startIssued = false; error = nil
        trace("did start")
    }
    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        trace("will stop: " + (pendingStopReason.map { "app-requested: " + $0 } ?? "external-or-system-unknown"))
    }
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
        active = false
        lastStopAt = ProcessInfo.processInfo.systemUptime
        lastStopClassification = pendingStopReason.map { "app-requested: " + $0 } ?? "external-or-system-unknown"
        pendingStopReason = nil
        trace("did stop: " + lastStopClassification)
        render()
    }
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
        active = false; startDeadline = nil; startIssued = false; self.error = error.localizedDescription
        trace("failed to start: \(error.localizedDescription)")
    }
}
extension PiPGuidanceController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}

final class GuidanceVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
public struct GuidancePreview: UIViewRepresentable {
    private let controller: PiPGuidanceController
    public init(controller: PiPGuidanceController) { self.controller = controller }
    public func makeUIView(context: Context) -> UIView {
        let view = GuidanceVideoView(); view.backgroundColor = .white
        view.display.videoGravity = .resizeAspect; controller.attach(view); return view
    }
    public func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
