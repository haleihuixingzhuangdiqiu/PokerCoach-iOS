import Foundation

public struct RecognizedTable: Sendable, Equatable {
    public let tableID: String
    public let handID: String
    public let state: TableState
    public let hero: Int
    public let holeCards: HoleCards
    /// True only when the adapter has reconstructed the current betting round from confirmed events.
    public let historyComplete: Bool
    public init(tableID: String, handID: String, state: TableState, hero: Int, holeCards: HoleCards, historyComplete: Bool) {
        self.tableID = tableID; self.handID = handID; self.state = state; self.hero = hero
        self.holeCards = holeCards; self.historyComplete = historyComplete
    }
}

public struct FrameObservation: Sendable {
    public let sequence: UInt64
    /// Monotonic time shared with the receiver, never a camera frame's unrelated timestamp origin.
    public let capturedAt: Double
    public let table: RecognizedTable?
    /// Minimum of calibrated confidence values for ALL critical fields, not their average.
    public let criticalConfidence: Double
    public init(sequence: UInt64, capturedAt: Double, table: RecognizedTable?, criticalConfidence: Double) {
        self.sequence = sequence; self.capturedAt = capturedAt; self.table = table; self.criticalConfidence = criticalConfidence
    }
}

public struct AnalysisTicket: Sendable, Equatable {
    public let generation: UInt64
    public let table: RecognizedTable
}

public enum GuidanceStatus: String, Sendable {
    case waiting = "等待牌桌"
    case unstable = "正在确认牌面"
    case incompleteHistory = "下注记录不完整"
    case waitingForTurn = "等待我方行动"
    case ready = "可以分析"
    case stale = "画面已过期"
    case invalid = "牌面或金额冲突"
}

/// A single-owner value type: use from the UI's @MainActor or one dedicated actor.
public struct ObservationGate: Sendable {
    public private(set) var status: GuidanceStatus = .waiting
    public private(set) var ticket: AnalysisTicket?
    public private(set) var generation: UInt64 = 0
    private var sequence: UInt64?
    private var candidate: RecognizedTable?
    private var repeats = 0
    private var lastCapture: Double?
    public let maxAge: Double
    public let requiredFrames: Int
    public let minimumConfidence: Double
    public init(maxAge: Double = 0.8, requiredFrames: Int = 2, minimumConfidence: Double = 0.98) {
        self.maxAge = max(0.05, maxAge); self.requiredFrames = max(2, requiredFrames)
        self.minimumConfidence = min(1, max(0, minimumConfidence))
    }
    public mutating func reset() {
        sequence = nil; candidate = nil; repeats = 0; lastCapture = nil
        invalidate(.waiting)
    }
    private mutating func invalidate(_ newStatus: GuidanceStatus) {
        if ticket != nil || status != newStatus { generation &+= 1 }
        ticket = nil; status = newStatus
    }
    public mutating func ingest(_ observation: FrameObservation, now: Double) {
        guard now.isFinite else { return }
        if let sequence, observation.sequence <= sequence { expire(now: now); return }
        sequence = observation.sequence
        guard observation.capturedAt.isFinite, observation.capturedAt <= now,
              now - observation.capturedAt <= maxAge else {
            candidate = nil; repeats = 0; invalidate(.stale); return
        }
        if let lastCapture, observation.capturedAt <= lastCapture { expire(now: now); return }
        lastCapture = observation.capturedAt
        guard observation.criticalConfidence.isFinite, observation.criticalConfidence >= minimumConfidence,
              observation.criticalConfidence <= 1, let table = observation.table else {
            candidate = nil; repeats = 0; invalidate(.unstable); return
        }
        let all = table.holeCards.cards + table.state.board
        guard !table.tableID.isEmpty, !table.handID.isEmpty, table.state.seats.indices.contains(table.hero),
              Set(all).count == all.count, (try? table.state.validate()) != nil else {
            candidate = nil; repeats = 0; invalidate(.invalid); return
        }
        if candidate != table { candidate = table; repeats = 1; invalidate(.unstable) }
        else { repeats += 1 }
        guard repeats >= requiredFrames else { return }
        guard table.historyComplete else { invalidate(.incompleteHistory); return }
        guard table.state.actor == table.hero, !table.state.roundComplete else { invalidate(.waitingForTurn); return }
        status = .ready
        if ticket == nil { generation &+= 1; ticket = AnalysisTicket(generation: generation, table: table) }
    }
    public mutating func expire(now: Double) {
        guard let lastCapture, now.isFinite, now >= lastCapture, now - lastCapture <= maxAge else {
            candidate = nil; repeats = 0; invalidate(.stale); return
        }
    }
    public mutating func accepts(_ completed: AnalysisTicket, now: Double) -> Bool {
        expire(now: now)
        return status == .ready && ticket == completed
    }
}

/// Single-slot inbox for expensive recognition. The adapter must separately flag missing action history.
public actor LatestFrameMailbox<Frame: Sendable> {
    private var newest: Frame?
    public init() {}
    public func offer(_ frame: Frame) { newest = frame }
    public func take() -> Frame? { defer { newest = nil }; return newest }
    public func clear() { newest = nil }
}
