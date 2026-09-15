/// Reconciles a transient system capture flag with this extension's fresh frame stream.
/// During reconciliation the caller must withdraw guidance immediately, but can keep
/// the neutral PiP alive for at most 0.8 seconds. A stale/tail frame cannot restart it.
public struct CaptureActivityMonitor: Sendable {
    public enum Event: Sendable, Equatable { case none, started, suspended, resumed, stopped }
    public private(set) var isActive = false
    public private(set) var isReconciling = false
    public private(set) var usingFrameEvidence = false
    private var falseAt: Double?
    private var lastFrameAt: Double?
    private var postFlagFrames = 0
    public init() {}

    public mutating func system(_ active: Bool, now: Double) -> Event {
        guard now.isFinite, now >= 0 else { return .none }
        if active {
            let event: Event = !isActive ? .started : (isReconciling ? .resumed : .none)
            isActive = true; isReconciling = false; usingFrameEvidence = false
            falseAt = nil; postFlagFrames = 0
            return event
        }
        guard isActive, !isReconciling, !usingFrameEvidence else { return .none }
        falseAt = now; isReconciling = true; postFlagFrames = 0; lastFrameAt = nil
        return .suspended
    }

    public mutating func frame(capturedAt: Double, now: Double) -> Event {
        if tick(now: now) == .stopped { return .stopped }
        guard isActive, capturedAt.isFinite, now.isFinite,
              capturedAt <= now, now - capturedAt <= 0.8,
              capturedAt > (lastFrameAt ?? -1) else { return .none }
        if isReconciling, let falseAt {
            // A sender can have one tail frame queued; require two increasing captures
            // after the false flag, and evidence beyond the sender's 0.2-second cadence.
            guard now - falseAt < 0.8, capturedAt > falseAt else { return .none }
            lastFrameAt = capturedAt; postFlagFrames += 1
            if postFlagFrames >= 2, capturedAt - falseAt > 0.2 {
                isReconciling = false; usingFrameEvidence = true
                return .resumed
            }
        } else { lastFrameAt = capturedAt }
        return .none
    }

    public mutating func tick(now: Double) -> Event {
        guard now.isFinite, isActive else { return .none }
        let expired = isReconciling ? falseAt.map { now - $0 >= 0.8 } ?? false
            : (usingFrameEvidence ? lastFrameAt.map { now - $0 >= 0.8 } ?? true : false)
        guard expired else { return .none }
        self = Self(); return .stopped
    }
}
