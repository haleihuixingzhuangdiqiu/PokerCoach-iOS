import Foundation

/// Binds the complete rules state to real, enabled controls; never substitutes a
/// theoretical raise size for one the screen actually exposes.
public struct FullHandDecisionRequest: Sendable, Equatable {
    public let hand: VerifiedPublicHand
    public let allowedActions: [PokerAction]
    public init(hand: VerifiedPublicHand, controls: VisiblePassiveActions, observedPot: Int?) throws {
        guard hand.actionSequenceUnique else { throw PokerError.invalid("完整策略需要唯一行动记录") }
        self.hand = hand
        allowedActions = try Self.observedActions(state: hand.state, hero: hand.hero, controls: controls, observedPot: observedPot)
    }
    public static func observedActions(state: TableState, hero: Int, controls: VisiblePassiveActions,
                                       observedPot: Int?) throws -> [PokerAction] {
        try state.validate()
        guard state.seats.indices.contains(hero),
              controls.heroTurnConfirmed, state.actor == hero, !state.roundComplete,
              observedPot == state.pot, controls.heroStreetCommitted == state.seats[hero].streetCommitted else {
            throw PokerError.invalid("完整记录与当前操作金额尚未一致")
        }
        guard controls.visibleRaiseToAmounts.count <= 8, controls.visibleBetAmounts.count <= 8,
              (controls.visibleRaiseToAmounts + controls.visibleBetAmounts).allSatisfy({ (1...1_000_000_000).contains($0) }) else {
            throw PokerError.invalid("屏幕下注金额无效")
        }
        let cost = state.amountToCall(hero)
        guard (cost == 0 && controls.checkAvailable && controls.callAmount == nil)
            || (cost > 0 && !controls.checkAvailable && controls.callAmount == cost) else {
            throw PokerError.invalid("过牌与跟注按钮冲突或金额未一致")
        }
        var actions: [PokerAction] = []
        if cost == 0, controls.checkAvailable { actions.append(.check) }
        if cost > 0 {
            if controls.foldAvailable { actions.append(.fold) }
            if controls.callAmount == cost { actions.append(.call) }
        }
        // Incremental opening-bet controls cannot stand in for unobserved raise-to
        // controls. A blind option still has a current bet even though calling costs zero.
        guard controls.visibleBetAmounts.isEmpty || (state.currentBet == 0 && state.seats[hero].streetCommitted == 0) else {
            throw PokerError.invalid("当前已有下注，不能把下注增量当成加注到总额")
        }
        let targets = controls.visibleRaiseToAmounts + controls.visibleBetAmounts
        for target in Set(targets).sorted() {
            let action = PokerAction.raiseTo(target)
            if (try? state.applying(action)) != nil { actions.append(action) }
        }
        guard !actions.isEmpty, (cost == 0 && controls.checkAvailable) || (cost > 0 && controls.callAmount == cost) else {
            throw PokerError.invalid("跟注或过牌按钮尚未与完整记录一致")
        }
        return actions
    }
    public func actionLabel(_ result: DecisionResult) -> String {
        Self.actionLabel(result, state: hand.state, hero: hand.hero)
    }
    public static func actionLabel(_ result: DecisionResult, state: TableState, hero: Int) -> String {
        switch result.suggested {
        case .fold: return "建议：弃牌"
        case .check: return "建议：过牌"
        case .call: return "建议：跟注 " + Self.amount(state.amountToCall(hero))
        case .raiseTo(let target):
            return (state.currentBet == 0 ? "建议：下注 " : "建议：加注到 ") + Self.amount(target)
        }
    }
    public func subtitle(_ result: DecisionResult, conditionedRanges: Bool) -> String {
        Self.subtitle(result, state: hand.state, hero: hand.hero)
    }
    public static func subtitle(_ result: DecisionResult, state: TableState, hero: Int) -> String {
        let opponents = state.live.count - 1
        let win = Int((100 * result.equity.outrightWinProbability).rounded())
        let first = "摊牌独赢 \(win)% · \(opponents)对手"
        let reason: String
        switch result.suggested {
        case .fold: reason = "继续投入的模拟收益较低"
        case .check: reason = "保留筹码 · 比较后续行动"
        case .call: reason = "跟注后继续推演 · 按模拟均值"
        case .raiseTo(let total):
            let extra = total - state.seats[hero].streetCommitted
            reason = "补 " + Self.amount(extra) + " · 多人后续推演"
        }
        return first + "\n" + reason
    }
    private static func amount(_ chips: Int) -> String { String(format: "%.2f", Double(chips) / 100) }
}
