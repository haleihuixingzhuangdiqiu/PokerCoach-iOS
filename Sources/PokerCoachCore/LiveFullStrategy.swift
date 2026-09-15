import Foundation

/// Two distinct sources can support a complete current betting state. A recovered
/// opening is never promoted to a continuously observed hand history.
public enum FullStrategyRequest: Sendable, Equatable {
    case continuous(FullHandDecisionRequest)
    case opening(OpeningSnapshotReconstruction, [PokerAction])

    public init(opening: OpeningSnapshotReconstruction, controls: VisiblePassiveActions, observedPot: Int?) throws {
        self = .opening(opening, try FullHandDecisionRequest.observedActions(
            state: opening.state, hero: opening.hero, controls: controls, observedPot: observedPot))
    }
    public var state: TableState {
        switch self { case .continuous(let r): return r.hand.state; case .opening(let r, _): return r.state }
    }
    public var hero: Int {
        switch self { case .continuous(let r): return r.hand.hero; case .opening(let r, _): return r.hero }
    }
    public var cards: HoleCards {
        switch self { case .continuous(let r): return r.hand.cards; case .opening(let r, _): return r.cards }
    }
    public var allowedActions: [PokerAction] {
        switch self { case .continuous(let r): return r.allowedActions; case .opening(_, let a): return a }
    }
    public var sourceLabel: String {
        switch self { case .continuous: return "连续记录"; case .opening: return "单次开池重建" }
    }
    public var sourceID: String {
        switch self { case .continuous: return "continuousHand"; case .opening: return "singleOpenSnapshot" }
    }
    public func actionLabel(_ result: DecisionResult) -> String {
        FullHandDecisionRequest.actionLabel(result, state: state, hero: hero)
    }
    public func subtitle(_ result: DecisionResult) -> String {
        let text = FullHandDecisionRequest.subtitle(result, state: state, hero: hero)
        guard case .opening = self else { return text }
        let lines = text.components(separatedBy: "\n")
        return lines[0] + "\n重建 · " + lines.dropFirst().joined(separator: " ")
            .replacingOccurrences(of: " · 按模拟均值", with: "")
            .replacingOccurrences(of: " · 多人后续推演", with: "")
    }
}

/// Confirm a narrow single-open reconstruction on two separate fresh frames.
/// Any changed or unreadable state immediately withdraws the old recommendation.
public struct OpeningSnapshotGate: Sendable {
    private var candidate: OpeningSnapshotReconstruction?
    private var consecutive = 0
    private var lastInputAt = 0.0
    public private(set) var lastVerifiedAt = 0.0
    public private(set) var status = "等待开池快照"
    public let freshness: Double
    public init(freshness: Double = 0.8) {
        self.freshness = freshness.isFinite && freshness > 0 ? freshness : 0.8
    }
    public mutating func reset() {
        candidate = nil; consecutive = 0; lastInputAt = 0; lastVerifiedAt = 0
        status = "等待开池快照"
    }
    public mutating func ingest(_ snapshot: PublicTableSnapshot, timestamp: Double, now: Double) {
        guard timestamp.isFinite, now.isFinite, timestamp > lastInputAt, timestamp <= now,
              now - timestamp <= freshness else { return }
        let gap = lastInputAt > 0 && timestamp - lastInputAt > freshness
        lastInputAt = timestamp; lastVerifiedAt = 0
        do {
            let recovered = try OpeningSnapshotReconstructor.reconstruct(snapshot)
            if candidate == recovered && !gap { consecutive += 1 }
            else { candidate = recovered; consecutive = 1 }
            guard consecutive >= 2 else { status = "正在核对开池投入"; return }
            lastVerifiedAt = timestamp; status = "单次开池已核对"
        } catch {
            candidate = nil; consecutive = 0; status = String(describing: error)
        }
    }
    public mutating func ingestUnreadable(timestamp: Double, now: Double) {
        guard timestamp.isFinite, now.isFinite, timestamp > lastInputAt, timestamp <= now,
              now - timestamp <= freshness else { return }
        lastInputAt = timestamp; lastVerifiedAt = 0; candidate = nil; consecutive = 0
        status = "最新开池快照尚未读全"
    }
    public func current(now: Double) -> OpeningSnapshotReconstruction? {
        guard lastVerifiedAt > 0, now.isFinite, now >= lastVerifiedAt,
              now - lastVerifiedAt <= freshness else { return nil }
        return candidate
    }
}
