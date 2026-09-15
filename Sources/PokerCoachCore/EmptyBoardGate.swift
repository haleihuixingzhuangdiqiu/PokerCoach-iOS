import Foundation

/// A missing OCR result is not proof of a preflop board. Require explicit whole-area
/// empty-table evidence on two fresh frames, and withdraw on the first contrary frame.
public struct EmptyBoardGate: Sendable {
    private var lastTimestamp = 0.0
    private var repeats = 0
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func ingest(verifiedEmpty: Bool, timestamp: Double, now: Double) {
        guard timestamp.isFinite, now.isFinite, timestamp > lastTimestamp, timestamp <= now else { return }
        guard now - timestamp <= 0.8 else { reset(); return }
        if lastTimestamp > 0, timestamp - lastTimestamp > 0.8 { repeats = 0 }
        lastTimestamp = timestamp
        repeats = verifiedEmpty ? repeats + 1 : 0
    }
    public func confirmed(now: Double) -> Bool {
        now.isFinite && now >= lastTimestamp && now - lastTimestamp <= 0.8 && repeats >= 2
    }
}
