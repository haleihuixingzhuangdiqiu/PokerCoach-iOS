/// System screen capture and delivery from this App's extension are separate facts.
public enum CaptureConnectionPhase: String, Sendable {
    case stopped
    case waitingForFrames
    case receiving
    case interrupted

    public static func evaluate(isCaptured: Bool, lastFrameAt: Double?, now: Double) -> Self {
        guard isCaptured else { return .stopped }
        guard now.isFinite, now >= 0 else { return .interrupted }
        guard let lastFrameAt else { return .waitingForFrames }
        guard lastFrameAt.isFinite, lastFrameAt >= 0, lastFrameAt <= now else { return .interrupted }
        return now - lastFrameAt <= 3 ? .receiving : .interrupted
    }

    /// Three seconds governs the reconnect entry only; analysis uses its shorter freshness gate.
    public var canResumeGuidance: Bool { self == .receiving }
}

/// A first frame can precede the system's start notification. Only a previous stop
/// establishes a timestamp boundary; a start notification must not discard that first frame.
public struct CaptureSessionClock: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isCapturing = false
    public private(set) var lastStoppedAt = -Double.infinity

    public init() {}

    /// Invalidate work already queued on another executor while keeping the capture
    /// session logically alive during a bounded system-flag reconciliation.
    public mutating func invalidatePendingFrames(at now: Double) {
        guard now.isFinite, now >= 0 else { return }
        generation &+= 1; lastStoppedAt = max(lastStoppedAt, now)
    }

    @discardableResult
    public mutating func setActive(_ active: Bool, now: Double) -> Bool {
        guard active != isCapturing else { return false }
        generation &+= 1
        isCapturing = active
        if !active { lastStoppedAt = now }
        return true
    }

    /// Call again when asynchronous recognition completes, with the generation assigned on receipt.
    public func accepts(capturedAt: Double, now: Double, generation: UInt64) -> Bool {
        guard isCapturing, generation == self.generation,
              capturedAt.isFinite, now.isFinite, capturedAt >= 0, now >= capturedAt,
              capturedAt > lastStoppedAt else { return false }
        return now - capturedAt <= 0.8
    }
}
