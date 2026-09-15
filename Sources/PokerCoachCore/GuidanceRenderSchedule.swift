import Foundation

/// Submits changed visual content immediately and unchanged live video only as a heartbeat.
/// Merely asking to submit does not consume the slot: renderer backpressure leaves the latest
/// state pending until a later call can actually enqueue it.
public struct GuidanceRenderSchedule: Sendable {
    private var lastKey: String?
    private var lastSubmittedAt: Double?
    public init() {}
    public mutating func reset() { lastKey = nil; lastSubmittedAt = nil }
    public func shouldSubmit(key: String, now: Double) -> Bool {
        guard now.isFinite else { return false }
        guard let lastSubmittedAt else { return true }
        return key != lastKey || now < lastSubmittedAt || now - lastSubmittedAt >= 0.5
    }
    public mutating func didSubmit(key: String, at timestamp: Double) {
        guard timestamp.isFinite else { return }
        lastKey = key; lastSubmittedAt = timestamp
    }
}
