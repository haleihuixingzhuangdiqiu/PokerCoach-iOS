import ReplayKit

/// Uses the shared transport sources without linking any host-App UI into the extension.
final class SampleHandler: RPBroadcastSampleHandler {
    private let sender = FrameSender()
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) { sender.setActive(true) }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if sampleBufferType == .video { sender.offer(sampleBuffer) }
    }
    override func broadcastPaused() { sender.setActive(false) }
    override func broadcastResumed() { sender.setActive(true) }
    override func broadcastFinished() { sender.setActive(false) }
}
