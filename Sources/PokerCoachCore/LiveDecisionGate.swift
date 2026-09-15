import Foundation

/// Amounts and controls must be confirmed together from the same two images.
public struct LiveDecisionObservation: Sendable, Equatable {
    public let facts: PublicBettingFacts
    public let actions: VisiblePassiveActions
    public let headsUpOpponentStack: Int?
    public init(facts: PublicBettingFacts, actions: VisiblePassiveActions, headsUpOpponentStack: Int? = nil) {
        self.facts = facts; self.actions = actions; self.headsUpOpponentStack = headsUpOpponentStack
    }
}

public struct LiveDecisionGate: Sendable {
    private var candidate: LiveDecisionObservation?
    private var confirmed: LiveDecisionObservation?
    private var repeats = 0
    public private(set) var lastTimestamp = 0.0
    public private(set) var generation: UInt64 = 0
    public init() {}
    public mutating func reset() {
        candidate = nil; confirmed = nil; repeats = 0; lastTimestamp = 0; generation &+= 1
    }
    public mutating func ingest(_ observation: LiveDecisionObservation, timestamp: Double, now: Double) {
        guard now.isFinite, timestamp.isFinite, timestamp <= now, timestamp > lastTimestamp else { return }
        guard now - timestamp <= 0.8 else { _ = current(now: now); return }
        if lastTimestamp > 0, timestamp - lastTimestamp > 0.8 { reset() }
        lastTimestamp = timestamp
        if candidate == observation { repeats += 1 }
        else {
            candidate = observation; confirmed = nil; repeats = 1; generation &+= 1
        }
        if repeats >= 2 { confirmed = observation }
    }
    public mutating func current(now: Double) -> LiveDecisionObservation? {
        guard now.isFinite, now >= lastTimestamp, now - lastTimestamp <= 0.8 else {
            if candidate != nil { reset() }
            return nil
        }
        return confirmed
    }
    public mutating func accepts(_ observation: LiveDecisionObservation, generation: UInt64, now: Double) -> Bool {
        self.generation == generation && current(now: now) == observation
    }
}
