import Foundation

/// Amount explanations only. This type never selects a PokerAction or certifies a legal raise.
public struct BettingAmountSummary: Sendable, Equatable {
    public enum Status: String, Sendable {
        case awaitingAmounts, unconfirmedCall, callCostKnown, handEnded
    }

    public let status: Status
    public let pot: Int?
    public let call: Int?
    public let heroStack: Int?
    public let remainingStackAfterCall: Int?
    /// C / P: the additional call as a proportion of the pot currently visible.
    public let callToCurrentPotRatio: Double?
    /// C / S: the additional call as a proportion of the hero's remaining stack.
    public let callToStackRatio: Double?
    /// C / (P + C): break-even showdown share, under the assumptions in limitation.
    public let breakEvenEquity: Double?
    public let wouldUseAllKnownStack: Bool
    public let callTitle: String
    public let thresholdSubtitle: String
    public let amountDetails: String
    public let limitation: String
    /// Optional explanation for a details page, not an instruction to call or fold.
    public let conditionalShowdownValue: ConditionalCallValue?
}

/// Incremental value of paying the displayed call, assuming no further payments and
/// full eligibility for the displayed pot. Scenario spread is not a confidence interval.
public struct ConditionalCallValue: Sendable, Equatable {
    public let minimumScenarioMean: Double
    public let maximumScenarioMean: Double
    /// Envelope of each scenario's sampling interval; not a simultaneous 95% guarantee.
    public let minimumSamplingBound: Double
    public let maximumSamplingBound: Double
    public let maximumOpponents: Int
    public let explanation: String
}

public enum BettingAmountSupport {
    public static let raiseLimitation = "尚未确认盲注、本轮已投入额、上一完整加注幅度和加注权，无法确定合法加注到多少。"
    public static let showdownAssumptions = "底池比假设可争夺全部显示底池，补跟后直接摊牌；未计后续下注、抽水和边池，不是行动建议。"

    /// Pass only current facts from PublicFactsGate. If supplied, estimate must belong
    /// to the same confirmed cards; this helper can check player-count consistency only.
    public static func summarize(facts: PublicBettingFacts?, estimate: CardEquityEstimate? = nil) -> BettingAmountSummary {
        let limitation = raiseLimitation + showdownAssumptions
        guard let facts else {
            return empty(status: .awaitingAmounts, title: "金额未读清", subtitle: "仅牌面估算", limitation: limitation)
        }
        // Codable callers can provide data without going through the OCR initializer.
        guard facts.foldedSeats.isSubset(of: Set(0..<7)),
              facts.pot.map({ $0 >= 0 && $0 <= 1_000_000_000 }) ?? true,
              facts.heroStack.map({ $0 >= 0 && $0 <= 1_000_000_000 }) ?? true else {
            return empty(status: .awaitingAmounts, title: "金额未读清", subtitle: "仅牌面估算", limitation: limitation)
        }
        if facts.maximumOpponents == 0 {
            return empty(status: .handEnded, title: "等待下一手", subtitle: "可见对手均已弃牌", limitation: limitation)
        }
        guard let pot = facts.pot, pot > 0,
              let call = facts.call, call > 0, call <= pot,
              let stack = facts.heroStack, call <= stack,
              facts.settledPot.map({ $0 >= 0 && $0 <= pot }) ?? true else {
            let details = "当前底池 \(money(facts.pot))；剩余筹码 \(money(facts.heroStack))。没有确认跟注金额，不能据此认定可以过牌。"
            let hasPot = facts.pot.map { $0 > 0 } ?? false
            return BettingAmountSummary(status: .unconfirmedCall, pot: facts.pot, call: nil, heroStack: facts.heroStack,
                                        remainingStackAfterCall: nil, callToCurrentPotRatio: nil, callToStackRatio: nil,
                                        breakEvenEquity: nil, wouldUseAllKnownStack: false,
                                        callTitle: hasPot ? "底池\(money(facts.pot))" : "金额未读清",
                                        thresholdSubtitle: hasPot ? "加注未接通" : "仅牌面估算", amountDetails: details,
                                        limitation: limitation, conditionalShowdownValue: nil)
        }
        let threshold = Double(call) / (Double(pot) + Double(call))
        let potRatio = Double(call) / Double(pot), stackRatio = Double(call) / Double(stack)
        let usesAll = call == stack
        var details = "当前底池 \(money(pot))；补跟 \(money(call))（当前底池的\(percent(potRatio))，剩余筹码的\(percent(stackRatio))）；补跟后剩 \(money(stack - call))。"
        if usesAll { details += "补跟会用完全部剩余筹码；可争夺的主池、边池金额尚未核实。" }
        let conditional = estimate.flatMap { conditionalValue($0, pot: pot, call: call, maximumOpponents: facts.maximumOpponents) }
        return BettingAmountSummary(status: .callCostKnown, pot: pot, call: call, heroStack: stack,
                                    remainingStackAfterCall: stack - call, callToCurrentPotRatio: potRatio,
                                    callToStackRatio: stackRatio, breakEvenEquity: threshold, wouldUseAllKnownStack: usesAll,
                                    callTitle: "需补跟\(money(call))", thresholdSubtitle: "需权益 \(percent(threshold)) · 摊牌假设",
                                    amountDetails: details, limitation: limitation, conditionalShowdownValue: conditional)
    }

    private static func empty(status: BettingAmountSummary.Status, title: String, subtitle: String,
                              limitation: String) -> BettingAmountSummary {
        BettingAmountSummary(status: status, pot: nil, call: nil, heroStack: nil, remainingStackAfterCall: nil,
                             callToCurrentPotRatio: nil, callToStackRatio: nil, breakEvenEquity: nil,
                             wouldUseAllKnownStack: false, callTitle: title, thresholdSubtitle: subtitle,
                             amountDetails: subtitle, limitation: limitation, conditionalShowdownValue: nil)
    }

    private static func conditionalValue(_ estimate: CardEquityEstimate, pot: Int, call: Int,
                                         maximumOpponents: Int) -> ConditionalCallValue? {
        guard estimate.maximumOpponents == maximumOpponents, (1...7).contains(maximumOpponents) else { return nil }
        let scenarios = maximumOpponents == 1 ? [estimate.headsUp] : [estimate.headsUp, estimate.mostOpponents]
        guard scenarios.allSatisfy({ result in
            result.equity.isFinite && (0...1).contains(result.equity)
                && result.samples > 0 && (result.exact || result.samples >= 500)
                && result.confidence95.count == 2
                && result.confidence95.allSatisfy { $0.isFinite && (0...1).contains($0) }
                && result.confidence95[0] <= result.equity && result.equity <= result.confidence95[1]
        }) else { return nil }
        // P already includes opponents' current bets and the hero's sunk contributions.
        // Deduct only this additional call; ties are represented by equity's fractional pot share.
        func value(_ equity: Double) -> Double { equity * (Double(pot) + Double(call)) - Double(call) }
        let means = scenarios.map { value($0.equity) }
        let lower = scenarios.map { value($0.confidence95[0]) }.min()!
        let upper = scenarios.map { value($0.confidence95[1]) }.max()!
        let explanation = "假设对手随机持牌、补跟后直接摊牌且可争夺全部显示底池：本次补跟的模型净值＝权益×（当前底池＋补跟额）－补跟额。人数情景范围不是置信区间，抽样区间不覆盖对手范围、识别和边池错误；不能作为跟注或弃牌指令。"
        return ConditionalCallValue(minimumScenarioMean: means.min()!, maximumScenarioMean: means.max()!,
                                    minimumSamplingBound: lower, maximumSamplingBound: upper,
                                    maximumOpponents: maximumOpponents, explanation: explanation)
    }

    private static func money(_ chips: Int?) -> String {
        guard let chips else { return "—" }
        return String(format: "%.2f", Double(chips) / 100)
    }
    private static func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
}
