import Foundation

/// Card-only admission is independent of the full action-history gate.
/// A new/unknown card immediately withdraws an older estimate, even before two-frame confirmation.
public struct LiveCardGate: Sendable {
    public private(set) var position: LiveCardPosition?
    public private(set) var slots: [String?]?
    public private(set) var lastTimestamp = 0.0
    public private(set) var changedAt = 0.0
    public private(set) var generation: UInt64 = 0
    /// Stable but illegal card combinations must not look like endless frame confirmation.
    public private(set) var validationIssue: String?
    private var repeats = 0
    public init() {}
    public mutating func reset() {
        position = nil; slots = nil; validationIssue = nil; lastTimestamp = 0; changedAt = 0; repeats = 0; generation &+= 1
    }
    public mutating func ingest(slots: [String?], timestamp: Double, now: Double) {
        guard now.isFinite, timestamp.isFinite, timestamp > lastTimestamp, timestamp <= now else { return }
        guard now - timestamp <= 0.8 else { expire(now: now); return }
        if lastTimestamp > 0, timestamp - lastTimestamp > 0.8 { reset() }
        lastTimestamp = timestamp
        if self.slots == slots { repeats += 1 }
        else {
            self.slots = slots; repeats = 1; position = nil; validationIssue = nil; changedAt = timestamp; generation &+= 1
        }
        if repeats >= 2 {
            do { position = try LiveCardPosition(slots: slots); validationIssue = nil }
            catch { position = nil; validationIssue = String(describing: error) }
        }
    }
    public mutating func expire(now: Double) {
        if !now.isFinite || now < lastTimestamp || now - lastTimestamp > 0.8 {
            if slots != nil { reset() }
        }
    }
    public func accepts(generation: UInt64, position: LiveCardPosition, now: Double) -> Bool {
        now.isFinite && now >= lastTimestamp && now - lastTimestamp <= 0.8 &&
        self.generation == generation && self.position == position
    }
}
