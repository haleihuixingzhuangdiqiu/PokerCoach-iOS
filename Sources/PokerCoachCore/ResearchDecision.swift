import Foundation

/// These are observed controls, not actions inferred from a missing amount or a card's strength.
/// The capture adapter must confirm the active (not preselected/disabled) controls on fresh frames.
public struct VisiblePassiveActions: Sendable, Hashable {
    public let heroTurnConfirmed: Bool
    public let foldAvailable: Bool
    public let checkAvailable: Bool
    public let callAmount: Int?
    /// Extra chips required by observed betting controls. Stored as unsupported candidates only.
    /// Do not put a "raise to" amount here unless its incremental cost was independently confirmed.
    public let visibleBetAmounts: [Int]
    /// Independently read current-street contribution and enabled menu totals.
    public let heroStreetCommitted: Int?
    public let visibleRaiseToAmounts: [Int]
    public init(heroTurnConfirmed: Bool, foldAvailable: Bool = false, checkAvailable: Bool = false,
                callAmount: Int? = nil, visibleBetAmounts: [Int] = [],
                heroStreetCommitted: Int? = nil, visibleRaiseToAmounts: [Int] = []) {
        self.heroTurnConfirmed = heroTurnConfirmed; self.foldAvailable = foldAvailable
        self.checkAvailable = checkAvailable; self.callAmount = callAmount
        self.visibleBetAmounts = visibleBetAmounts
        self.heroStreetCommitted = heroStreetCommitted; self.visibleRaiseToAmounts = visibleRaiseToAmounts
    }
}

public struct ResearchDecisionRequest: Sendable, Equatable {
    public let position: LiveCardPosition
    public let facts: PublicBettingFacts
    public let actions: VisiblePassiveActions
    /// Nil tests every possible count 1...facts.maximumOpponents. An exact count needs its own evidence.
    public let opponentCounts: ClosedRange<Int>?
    public let knownHeadsUpOpponentStack: Int?
    public init(position: LiveCardPosition, facts: PublicBettingFacts, actions: VisiblePassiveActions,
                opponentCounts: ClosedRange<Int>? = nil, knownHeadsUpOpponentStack: Int? = nil) {
        self.position = position; self.facts = facts; self.actions = actions; self.opponentCounts = opponentCounts
        self.knownHeadsUpOpponentStack = knownHeadsUpOpponentStack
    }
}

public struct ResearchDecisionBudget: Sendable {
    public var samplesPerScenario: Int
    public var milliseconds: Int
    public var seed: UInt64
    public init(samplesPerScenario: Int = 1_000, milliseconds: Int = 600, seed: UInt64 = 20260916) {
        self.samplesPerScenario = samplesPerScenario; self.milliseconds = milliseconds; self.seed = seed
    }
}

public enum ResearchRangeAssumption: String, CaseIterable, Sendable, Codable {
    case uniform, valueWeighted, polarized
    public var name: String {
        switch self {
        case .uniform: "随机全范围"
        case .valueWeighted: "牌力偏重假设"
        case .polarized: "强弱两极假设"
        }
    }
    public var explanation: String {
        switch self {
        case .uniform: "所有未被已知牌排除的底牌组合等权。"
        case .valueWeighted: "组合权重＝0.05＋0.95×牌力特征的4次方；用于测试对手范围偏强的影响。"
        case .polarized: "组合权重＝0.05＋0.95×牌力特征的5次方＋0.25×(1－牌力特征)的3次方；同时保留强牌与弱牌。"
        }
    }
}

public struct ResearchDecisionScenario: Sendable, Codable {
    public let assumption: ResearchRangeAssumption
    public let opponentCount: Int
    public let equity: EquityResult
    public let passiveAction: PokerAction
    public let additionalChips: Int
    /// Conditional incremental value, assuming full pot eligibility and no future contributions.
    public let passiveValue: Double
    public let passiveValueSamplingBounds: [Double]
    /// Fold vs call within this scenario; or the sole supported check action.
    public let preferred: PokerAction
    /// False means passiveValue/preferred are only the legacy no-future-contribution
    /// counterfactual. They MUST NOT be used as an actionable comparison for this state.
    public var actionValueApplicable: Bool = true
}

/// Incremental amounts avoid inventing this street's previous contributions or a minimum raise.
public enum ResearchAction: Hashable, Sendable, Codable {
    case fold, check, call(Int), bet(Int), raiseTo(total: Int, additional: Int)
    public var additionalChips: Int {
        switch self {
        case .fold, .check: 0
        case .call(let amount), .bet(let amount): amount
        case .raiseTo(_, let amount): amount
        }
    }
}

public enum ResearchResponseAssumption: String, CaseIterable, Sendable, Codable {
    case tight, neutral, loose
    public var name: String {
        switch self { case .tight: "偏紧响应"; case .neutral: "中性响应"; case .loose: "偏松响应" }
    }
    public var explanation: String {
        let threshold: String
        switch self {
        case .tight: threshold = "0.60＋0.45×跟注底池比"
        case .neutral: threshold = "0.44＋0.45×跟注底池比"
        case .loose: threshold = "0.28＋0.35×跟注底池比"
        }
        return "阈值＝\(threshold)；跟注倾向＝1÷(1＋exp(−9×(当前牌力特征−阈值)))，截在2%–98%；河牌绝对坚果强制继续。人工假设不是真人弃牌率预测，且不含再加注。"
    }
    func continueProbability(strength: Double, callPrice: Double, riverNuts: Bool) -> Double {
        if riverNuts { return 1 }
        let threshold: Double
        switch self {
        case .tight: threshold = 0.60 + 0.45 * callPrice
        case .neutral: threshold = 0.44 + 0.45 * callPrice
        case .loose: threshold = 0.28 + 0.35 * callPrice
        }
        return min(0.98, max(0.02, 1 / (1 + exp(-9 * (strength - threshold)))))
    }
}

public struct ResearchBetComparison: Sendable, Codable {
    public let rangeAssumption: ResearchRangeAssumption
    public let responseAssumption: ResearchResponseAssumption
    public let additionalChips: Int
    public let assumedFoldProbability: Double
    public let calledEquity: EquityResult
    public let value: Double
    public let valueSamplingBounds: [Double]
    public let checkValue: Double
}

public struct ResearchDecisionResult: Sendable {
    public let suggested: ResearchAction?
    public let additionalChips: Int
    /// Minimum/maximum scenario estimates; neither array is a calibrated confidence interval.
    public let outrightWinProbabilityRange: [Double]
    public let tieProbabilityRange: [Double]
    public let equityRange: [Double]
    public let scenarios: [ResearchDecisionScenario]
    public let betComparisons: [ResearchBetComparison]
    public let modelSensitive: Bool
    public let opponentCountUncertain: Bool
    public let samplingUncertain: Bool
    public let reason: String
    public let limitations: [String]
    public let unsupportedAggressiveAmounts: [Int]
    /// Menu totals are kept separate from incremental bet amounts.
    public var unsupportedRaiseToAmounts: [Int] = []
    public let elapsedMilliseconds: Double
    /// Probability-only output: inputs cannot support the passive action-value model.
    /// A complete-state engine may independently recover an actionable decision.
    public var withheldActionReason: String? = nil

    /// One explicit reference model, not the midpoint or minimum of sensitivity bounds.
    /// Condition on the largest still-possible opponent count, then give the three
    /// alternative range models equal prior weight. Do not invent a distribution over counts.
    public var mainScenarios: [ResearchDecisionScenario] {
        guard let count = scenarios.map(\.opponentCount).max() else { return [] }
        let selected = scenarios.filter { $0.opponentCount == count }
        guard selected.count == ResearchRangeAssumption.allCases.count,
              Set(selected.map(\.assumption)) == Set(ResearchRangeAssumption.allCases) else { return [] }
        return ResearchRangeAssumption.allCases.compactMap { assumption in
            selected.first { $0.assumption == assumption }
        }
    }
    public var mainOpponentCount: Int? { mainScenarios.first?.opponentCount }
    public var mainOutrightWinProbability: Double? { averageMain(\.outrightWinProbability) }
    public var mainTieProbability: Double? { averageMain(\.tieProbability) }
    public var mainEquity: Double? { averageMain(\.equity) }
    public var mainAssumptionLabel: String {
        guard let count = mainOpponentCount else { return "主模型待计算" }
        let people = opponentCountUncertain ? "按最多\(count)名对手估算（人数待确认）" : "按\(count)名对手估算"
        return people + "；三个范围模型等权，未校准"
    }
    private func averageMain(_ keyPath: KeyPath<EquityResult, Double>) -> Double? {
        let values = mainScenarios.map { $0.equity[keyPath: keyPath] }
        guard values.count == ResearchRangeAssumption.allCases.count,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    public var actionLabel: String {
        switch suggested {
        case .fold: "建议：弃牌"
        case .check: "建议：过牌"
        case .call: "建议：跟注\(String(format: "%.2f", Double(additionalChips) / 100))"
        case .bet: "建议：下注\(String(format: "%.2f", Double(additionalChips) / 100))"
        case .raiseTo(let total, _): "建议：加注到\(String(format: "%.2f", Double(total) / 100))"
        case nil: withheldActionReason == nil ? "等待可用动作" : "正在核对下注状态"
        }
    }
    public var winLabel: String {
        guard let win = mainOutrightWinProbability else { return "赢面待估算" }
        return String(format: "摊牌独赢%.0f%%", win * 100)
    }
}

/// A deliberately restricted research policy, separate from the complete-history DecisionEngine.
/// It ranks proven passive actions and restricted opening bets under explicit range/response assumptions.
public enum ResearchDecisionEngine {
    public static let limitations = [
        "未训练的研究策略，不是GTO，也未验证能够战胜真人。范围权重是显式假设，不是从当前下注历史推断的对手持牌。",
        "只使用已确认可用的动作；下注/加注仅限翻后、准确单挑、双方筹码已读，并从启用的屏幕金额中选择。加注还需确认本街已投入額；金额是加注到总额。",
        "假设当前动作后直接摊牌，且我方可争夺全部显示底池；下注/加注后的对手只会弃牌或跟注，不会再加注。未计抽水、边池、后续街下注和锦标赛ICM。",
        "主模型按最大仍可能在局人数、三个范围模型等权；下注响应也等权，以期望收益排序。这是未校准先验，人数不作概率平均。其余人数只做敏感性检查。区间不覆盖模型错误。",
        "多人跟注/弃牌需要完整逐人投入与待响应状态；人数上界下的免费摊牌权益只作条件概率参考，不能直接乘当前底池生成行动指令。封顶全下也需要核对实际可争夺底池。"
    ]

    public static func analyze(_ request: ResearchDecisionRequest, budget: ResearchDecisionBudget = .init(),
                               isCancelled: () -> Bool = { false }) throws -> ResearchDecisionResult {
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        guard budget.samplesPerScenario >= 500, budget.samplesPerScenario <= 100_000,
              budget.milliseconds > 0, budget.milliseconds <= 60_000 else { throw PokerError.invalid("研究决策预算无效") }
        if isCancelled() { throw PokerError.cancelled }
        let actions = request.actions
        guard actions.heroTurnConfirmed else {
            return unavailable(reason: "尚未确认轮到本人，不输出行动指令。", elapsed: elapsed())
        }
        let facts = request.facts
        guard let pot = facts.pot, pot > 0, pot <= 1_000_000_000,
              let stack = facts.heroStack, stack > 0, stack <= 1_000_000_000,
              facts.settledPot.map({ $0 >= 0 && $0 <= pot }) ?? true,
              facts.foldedSeats.isSubset(of: Set(0..<7)), (1...7).contains(facts.maximumOpponents) else {
            throw PokerError.invalid("需要确认底池、剩余筹码和仍可能在局的对手")
        }
        let counts = request.opponentCounts ?? 1...facts.maximumOpponents
        guard counts.lowerBound >= 1, counts.upperBound <= facts.maximumOpponents else {
            throw PokerError.invalid("人数假设与已确认弃牌席位冲突")
        }
        guard actions.visibleBetAmounts.count <= 8, actions.visibleRaiseToAmounts.count <= 8,
              (actions.visibleBetAmounts + actions.visibleRaiseToAmounts).allSatisfy({ $0 > 0 && $0 <= 1_000_000_000 }),
              actions.heroStreetCommitted.map({ (0...1_000_000_000).contains($0) }) ?? true else {
            throw PokerError.invalid("下注按钮金额或数量无效")
        }
        let passive: PokerAction, cost: Int
        if actions.checkAvailable {
            guard actions.callAmount == nil, facts.call == nil else { throw PokerError.invalid("过牌与正数跟注同时出现，需要重新确认按钮") }
            passive = .check; cost = 0
        } else if let amount = actions.callAmount {
            guard actions.foldAvailable, amount > 0, amount == facts.call, amount <= stack, amount <= pot else {
                throw PokerError.invalid("弃牌/跟注按钮或跟注金额未一致确认")
            }
            passive = .call; cost = amount
        } else {
            return unavailable(reason: "尚未确认过牌或跟注动作；不能把缺失金额当成可过牌。", elapsed: elapsed(),
                               aggressive: actions.visibleBetAmounts)
        }
        let confirmedHeadsUp = facts.maximumOpponents == 1 && counts == (1...1)
        let passiveComparisonSupported = confirmedHeadsUp && facts.visibleAllIn != true && cost < stack
        let withheldReason: String?
        if passive == .call && !passiveComparisonSupported {
            if facts.visibleAllIn == true || cost == stack {
                withheldReason = "全下金额与实际可争夺底池待核对，暂不判断跟弃"
            } else {
                withheldReason = "逐人投入与待行动尚未核对，暂不判断跟弃"
            }
        } else { withheldReason = nil }
        let betAdmission = admittedBets(request, counts: counts, pot: pot, stack: stack)
        let ranges = try scenarioRanges(position: request.position, isCancelled: isCancelled)
        let scenarioCount = counts.count * ResearchRangeAssumption.allCases.count
        let totalEvaluations = scenarioCount + (betAdmission.amounts.isEmpty ? 0 : ResearchRangeAssumption.allCases.count)
        var scenarios: [ResearchDecisionScenario] = []
        for count in counts {
            for assumption in ResearchRangeAssumption.allCases {
                if isCancelled() { throw PokerError.cancelled }
                let remaining = Double(budget.milliseconds) - elapsed()
                guard remaining >= 1 else { throw PokerError.budgetExceeded }
                let slotsLeft = totalEvaluations - scenarios.count
                let perScenarioTime = max(1, Int(remaining / Double(slotsLeft)))
                let equityRequest = try EquityRequest(hero: request.position.hero, board: request.position.board,
                                                      opponents: Array(repeating: ranges[assumption]!, count: count))
                let result = try EquityEngine.analyze(equityRequest,
                    budget: .init(samples: budget.samplesPerScenario, milliseconds: perScenarioTime,
                                  seed: budget.seed &+ UInt64(scenarios.count), exactOutcomeLimit: 0), isCancelled: isCancelled)
                guard result.samples >= 500 else { throw PokerError.budgetExceeded }
                func value(_ share: Double) -> Double { share * (Double(pot) + Double(cost)) - Double(cost) }
                let mean = value(result.equity)
                let preferred: PokerAction = passive == .check ? .check : (mean > 0 ? .call : .fold)
                scenarios.append(ResearchDecisionScenario(assumption: assumption, opponentCount: count, equity: result,
                    passiveAction: passive, additionalChips: cost, passiveValue: mean,
                    passiveValueSamplingBounds: result.confidence95.map(value), preferred: preferred,
                    actionValueApplicable: passiveComparisonSupported))
            }
        }
        if isCancelled() { throw PokerError.cancelled }
        if let withheldReason {
            let wins = scenarios.map { $0.equity.outrightWinProbability }
            let ties = scenarios.map { $0.equity.tieProbability }
            let shares = scenarios.map { $0.equity.equity }
            return ResearchDecisionResult(suggested: nil, additionalChips: 0,
                outrightWinProbabilityRange: [wins.min()!, wins.max()!],
                tieProbabilityRange: [ties.min()!, ties.max()!], equityRange: [shares.min()!, shares.max()!],
                scenarios: scenarios, betComparisons: [], modelSensitive: false,
                opponentCountUncertain: counts.count > 1, samplingUncertain: false,
                reason: withheldReason + "。保留的是指定人数/范围且所有人摊牌的条件概率；未跟齐玩家仍需跟注或弃牌，不能用当前底池加本人跟注额作为多人最终底池。需由完整状态推演恢复动作比较。",
                limitations: limitations, unsupportedAggressiveAmounts: Array(Set(actions.visibleBetAmounts)).sorted(),
                unsupportedRaiseToAmounts: Array(Set(actions.visibleRaiseToAmounts)).sorted(), elapsedMilliseconds: elapsed(),
                withheldActionReason: withheldReason)
        }
        if !betAdmission.amounts.isEmpty {
            return try compareOpeningBets(request, amounts: betAdmission.amounts, baseline: scenarios, ranges: ranges,
                                           pot: pot, budget: budget, started: started, isCancelled: isCancelled)
        }
        let main = scenarios.filter { $0.opponentCount == counts.upperBound }
        let expectedValue = main.reduce(0) { $0 + $1.passiveValue } / Double(main.count)
        let chosen: PokerAction = passive == .check ? .check : (expectedValue > 0 ? .call : .fold)
        let sensitive = Set(scenarios.map(\.preferred)).count > 1
        let uncertain = passive == .call && scenarios.contains { $0.passiveValueSamplingBounds[0] <= 0 && $0.passiveValueSamplingBounds[1] >= 0 }
        let winValues = scenarios.map { $0.equity.outrightWinProbability }, equityValues = scenarios.map { $0.equity.equity }
        let tieValues = scenarios.map { $0.equity.tieProbability }
        var reason: String
        if passive == .check {
            reason = "已确认可以过牌，返回支持的零投入动作；下注金额尚未比较，因此不声称过牌是全部合法动作中的最优解。"
        } else {
            reason = "按\(counts.upperBound)名对手、三个范围等权的主模型，跟注期望新增收益\(String(format: "%.2f", expectedValue / 100))，与弃牌的0新增收益比较；等权是假设，未经真人数据校准。"
            if sensitive { reason += "假设改变会改变行动首选，当前模型敏感。" }
            if uncertain { reason += "部分情景的抽样区间跨过盈亏平衡，行动排序仍有抽样不确定性。" }
        }
        if counts.count > 1 { reason += "实际人数未完全确认，逐个测试\(counts.lowerBound)–\(counts.upperBound)名对手。" }
        if passive == .check { reason += betAdmission.reason }
        let action: ResearchAction = chosen == .fold ? .fold : (chosen == .check ? .check : .call(cost))
        return ResearchDecisionResult(suggested: action, additionalChips: action.additionalChips,
            outrightWinProbabilityRange: [winValues.min()!, winValues.max()!], tieProbabilityRange: [tieValues.min()!, tieValues.max()!],
            equityRange: [equityValues.min()!, equityValues.max()!],
            scenarios: scenarios, betComparisons: [], modelSensitive: sensitive, opponentCountUncertain: counts.count > 1,
            samplingUncertain: uncertain, reason: reason, limitations: limitations,
            unsupportedAggressiveAmounts: Array(Set(actions.visibleBetAmounts)).sorted(),
            unsupportedRaiseToAmounts: Array(Set(actions.visibleRaiseToAmounts)).sorted(), elapsedMilliseconds: elapsed())
    }

    private static func unavailable(reason: String, elapsed: Double, aggressive: [Int] = []) -> ResearchDecisionResult {
        ResearchDecisionResult(suggested: nil, additionalChips: 0, outrightWinProbabilityRange: [], tieProbabilityRange: [], equityRange: [], scenarios: [], betComparisons: [],
            modelSensitive: false, opponentCountUncertain: true, samplingUncertain: true, reason: reason,
            limitations: limitations, unsupportedAggressiveAmounts: aggressive, elapsedMilliseconds: elapsed)
    }

    private static func admittedBets(_ request: ResearchDecisionRequest, counts: ClosedRange<Int>, pot: Int,
                                     stack: Int) -> (amounts: [Int], reason: String) {
        guard (3...5).contains(request.position.board.count) else { return ([], "翻前的下注/加注策略尚未接通。") }
        guard request.facts.maximumOpponents == 1, counts.lowerBound == 1, counts.upperBound == 1 else {
            return ([], "下注/加注需要准确确认只有一名在局对手。")
        }
        guard request.facts.visibleAllIn != true else { return ([], "已检测到全下，需要完整状态核对底池资格。") }
        guard let opponentStack = request.knownHeadsUpOpponentStack, opponentStack > 0, opponentStack <= 1_000_000_000 else {
            return ([], "单挑对手的剩余筹码尚未确认，开池下注暂不参与比较。")
        }
        let amounts: [Int]
        if request.actions.checkAvailable {
            guard request.facts.settledPot == pot else { return ([], "未确认本街没有未归集下注，下注暂不参与比较。") }
            amounts = Array(Set(request.actions.visibleBetAmounts.filter { $0 <= stack && $0 <= opponentStack })).sorted()
        } else {
            guard let committed = request.actions.heroStreetCommitted, let call = request.actions.callAmount else {
                return ([], "本街已投入额未确认，不能把加注到总额当成新增投入。")
            }
            amounts = Array(Set(request.actions.visibleRaiseToAmounts.compactMap { total -> Int? in
                let added = total - committed
                guard added > call, added <= stack, added - call <= opponentStack else { return nil }
                return added
            })).sorted()
        }
        guard !amounts.isEmpty else { return ([], "没有已确认且不超过双方剩余筹码的屏幕下注金额。") }
        return (amounts, "")
    }

    private struct ActionValue {
        let mean: Double
        let bounds: [Double]
    }

    /// One deal evaluates every amount/response. Integrating the response probability
    /// avoids drawing noisy synthetic fold/call actions, and never exposes the runout to the response model.
    private struct OpeningMoments {
        var normalizedValue = Moments()
        var continuation = Moments()
        var weightedShare = Moments()
        var weightedWins = 0.0
        var weightedTies = 0.0
        mutating func add(probability: Double, share: Double, pot: Double, amount: Double, call: Double) {
            // P already contains the opponent's bet. After hero adds D, the opponent
            // adds D-C, so the final called pot is P+2D-C, not P+2D.
            let finalPot = pot + 2 * amount - call
            let value = (1 - probability) * pot + probability * (share * finalPot - amount)
            normalizedValue.add((value + amount) / finalPot)
            continuation.add(probability); weightedShare.add(probability * share)
            if share == 1 { weightedWins += probability }
            else if share > 0 { weightedTies += probability }
        }
        func calledEquity(elapsed: Double, targetSamples: Int) -> EquityResult {
            let denominator = continuation.mean
            let value = min(1, max(0, weightedShare.mean / denominator))
            // Two 97.5% bounded-mean intervals yield a 95% ratio interval by a union bound.
            // This describes weighted sampling error, not model or recognition uncertainty.
            func bounds(_ m: Moments) -> [Double] {
                m.boundedConfidence(targetSamples: targetSamples, errorProbability: 0.025)
            }
            let numeratorBounds = bounds(weightedShare), denominatorBounds = bounds(continuation)
            let lower = denominatorBounds[1] > 0 ? max(0, numeratorBounds[0] / denominatorBounds[1]) : 0
            let upper = denominatorBounds[0] > 0 ? min(1, numeratorBounds[1] / denominatorBounds[0]) : 1
            return EquityResult(equity: value, outrightWinProbability: min(1, max(0, weightedWins / (denominator * Double(continuation.n)))),
                tieProbability: min(1, max(0, weightedTies / (denominator * Double(continuation.n)))),
                confidence95: [lower, upper], samples: continuation.n, exact: false, elapsedMilliseconds: elapsed,
                completedBudget: continuation.n == targetSamples)
        }
    }

    private static func compareOpeningBets(_ request: ResearchDecisionRequest, amounts: [Int],
                                           baseline: [ResearchDecisionScenario], ranges: [ResearchRangeAssumption: HandRange],
                                           pot: Int, budget: ResearchDecisionBudget, started: Double,
                                           isCancelled: () -> Bool) throws -> ResearchDecisionResult {
        let board = request.position.board
        let call = request.actions.callAmount ?? 0
        let baselineAction: ResearchAction = call == 0 ? .check : .call(call)
        func aggressiveAction(_ amount: Int) -> ResearchAction {
            if call == 0 { return .bet(amount) }
            return .raiseTo(total: request.actions.heroStreetCommitted! + amount, additional: amount)
        }
        let relative = try RelativeHandStrength(board: board)
        var strengths: [HoleCards: Double] = [:]
        for combo in ranges[.uniform]!.combos {
            if isCancelled() { throw PokerError.cancelled }
            strengths[combo.hand] = StrengthFeature.value(hand: combo.hand, board: board, relative: relative)
        }
        // This threshold uses public cards only, never the hero's hidden cards or a sampled runout.
        // It prevents an obviously tied royal-flush board from inventing opponent folds.
        var riverNutsScore: Int?
        if board.count == 5 {
            let possible = Card.deck.filter { !board.contains($0) }
            var maximum = 0
            for first in 0..<(possible.count - 1) {
                if isCancelled() { throw PokerError.cancelled }
                for second in (first + 1)..<possible.count {
                    maximum = max(maximum, HandEvaluator.value([possible[first], possible[second]] + board).score)
                }
            }
            riverNutsScore = maximum
        }
        var models: [[ResearchAction: ActionValue]] = []
        var comparisons: [ResearchBetComparison] = []
        for (rangeIndex, assumption) in ResearchRangeAssumption.allCases.enumerated() {
            let prior = ranges[assumption]!
            let remaining = Double(budget.milliseconds) - (ProcessInfo.processInfo.systemUptime - started) * 1000
            guard remaining >= 1 else { throw PokerError.budgetExceeded }
            let rangeStarted = ProcessInfo.processInfo.systemUptime
            let deadline = rangeStarted + remaining / Double(ResearchRangeAssumption.allCases.count - rangeIndex) / 1000
            let sampler = try DealSampler(EquityRequest(hero: request.position.hero, board: board, opponents: [prior]))
            var rng = SplitMix64(state: budget.seed &+ UInt64(baseline.count + rangeIndex))
            var checkShare = Moments()
            var stats = Array(repeating: Array(repeating: OpeningMoments(), count: amounts.count), count: ResearchResponseAssumption.allCases.count)
            while checkShare.n < budget.samplesPerScenario {
                if checkShare.n % 32 == 0 {
                    if isCancelled() { throw PokerError.cancelled }
                    if ProcessInfo.processInfo.systemUptime >= deadline { break }
                }
                guard let hands = sampler.holeDeal(&rng) else { continue }
                let opponent = hands[0]
                let strength = strengths[opponent]!
                let nuts = riverNutsScore.map { HandEvaluator.value(opponent.cards + board).score >= $0 } ?? false
                let runout = sampler.runout(hands, &rng)
                let heroValue = HandEvaluator.value(request.position.hero.cards + runout), otherValue = HandEvaluator.value(opponent.cards + runout)
                let share = heroValue > otherValue ? 1.0 : (heroValue == otherValue ? 0.5 : 0)
                checkShare.add(share)
                for (responseIndex, response) in ResearchResponseAssumption.allCases.enumerated() {
                    for (amountIndex, amount) in amounts.enumerated() {
                        let callPrice = Double(amount - call) / (Double(pot) + 2 * Double(amount) - Double(call))
                        let probability = response.continueProbability(strength: strength, callPrice: callPrice, riverNuts: nuts)
                        stats[responseIndex][amountIndex].add(probability: probability, share: share, pot: Double(pot), amount: Double(amount), call: Double(call))
                    }
                }
            }
            guard checkShare.n >= 500 else { throw PokerError.budgetExceeded }
            func passiveValue(_ share: Double) -> Double { share * Double(pot + call) - Double(call) }
            let check = ActionValue(mean: passiveValue(checkShare.mean),
                                    bounds: checkShare.boundedConfidence(targetSamples: budget.samplesPerScenario).map(passiveValue))
            for (responseIndex, response) in ResearchResponseAssumption.allCases.enumerated() {
                var values: [ResearchAction: ActionValue] = [baselineAction: check]
                if call > 0 { values[.fold] = ActionValue(mean: 0, bounds: [0, 0]) }
                for (amountIndex, amount) in amounts.enumerated() {
                    let moments = stats[responseIndex][amountIndex]
                    let equity = moments.calledEquity(elapsed: (ProcessInfo.processInfo.systemUptime - rangeStarted) * 1000,
                                                       targetSamples: budget.samplesPerScenario)
                    func denormalize(_ mean: Double) -> Double { mean * (Double(pot) + 2 * Double(amount) - Double(call)) - Double(amount) }
                    let result = ActionValue(mean: denormalize(moments.normalizedValue.mean),
                        bounds: moments.normalizedValue.boundedConfidence(targetSamples: budget.samplesPerScenario).map(denormalize))
                    values[aggressiveAction(amount)] = result
                    comparisons.append(ResearchBetComparison(rangeAssumption: assumption, responseAssumption: response,
                        additionalChips: amount, assumedFoldProbability: 1 - moments.continuation.mean, calledEquity: equity,
                        value: result.mean, valueSamplingBounds: result.bounds, checkValue: check.mean))
                }
                models.append(values)
            }
        }
        if isCancelled() { throw PokerError.cancelled }
        let candidates: [ResearchAction] = (call > 0 ? [.fold, baselineAction] : [baselineAction]) + amounts.map(aggressiveAction)
        func best(_ values: [ResearchAction: Double]) -> ResearchAction {
            candidates.max { left, right in
                let difference = values[left]! - values[right]!
                return abs(difference) < 1e-8 ? left.additionalChips > right.additionalChips : difference < 0
            }!
        }
        let expected = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            (candidate, models.reduce(0) { $0 + $1[candidate]!.mean } / Double(models.count))
        })
        let chosen = best(expected)
        let sensitive = Set(models.map { best($0.mapValues(\.mean)) }).count > 1
        let uncertain = models.contains { model in
            candidates.contains { $0 != chosen && model[chosen]!.bounds[0] <= model[$0]!.bounds[1] }
        }
        var reason = "已确认翻后单挑、双方筹码及\(amounts.count)个启用的屏幕金额；比较\(call == 0 ? "过牌/下注" : "弃牌/跟注/加注")，按9种范围/响应等权主模型的期望收益选择，所选动作模型净值\(String(format: "%.2f", expected[chosen]! / 100))。"
        if case .raiseTo(let total, let added) = chosen {
            reason += "加注到\(String(format: "%.2f", Double(total) / 100))，本次新增\(String(format: "%.2f", Double(added) / 100))。"
        }
        if sensitive { reason += "改变对手范围或跟弃牌假设会改变首选，当前模型敏感。" }
        if uncertain { reason += "抽样误差仍可能影响动作排序。" }
        reason += "模型只允许对手弃牌或跟注，不含再加注；显示的独赢/平局是行动前直接摊牌估计，不是这次下注的成功率。"
        let wins = baseline.map { $0.equity.outrightWinProbability }, ties = baseline.map { $0.equity.tieProbability }, shares = baseline.map { $0.equity.equity }
        return ResearchDecisionResult(suggested: chosen, additionalChips: chosen.additionalChips,
            outrightWinProbabilityRange: [wins.min()!, wins.max()!], tieProbabilityRange: [ties.min()!, ties.max()!],
            equityRange: [shares.min()!, shares.max()!], scenarios: baseline, betComparisons: comparisons,
            modelSensitive: sensitive, opponentCountUncertain: false, samplingUncertain: uncertain, reason: reason,
            limitations: limitations + ["全部下注金额共用同批底牌和公共牌样本；对手响应概率按当前牌面特征积分，跟注后权益用继续概率加权估计。"] + ResearchResponseAssumption.allCases.map { $0.name + "：" + $0.explanation },
            unsupportedAggressiveAmounts: Array(Set(request.actions.visibleBetAmounts).subtracting(amounts)).sorted(),
            unsupportedRaiseToAmounts: Array(Set(request.actions.visibleRaiseToAmounts).subtracting(
                call > 0 ? amounts.map { $0 + request.actions.heroStreetCommitted! } : [])).sorted(),
            elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    /// No sampled opponent hand, future board, or assumed betting event enters the weights.
    /// The existing feature uses current made-hand rank and draw hints; it is not showdown equity.
    static func scenarioRanges(position: LiveCardPosition, isCancelled: () -> Bool = { false }) throws -> [ResearchRangeAssumption: HandRange] {
        let blocked = (position.hero.cards + position.board).reduce(UInt64(0)) { $0 | $1.mask }
        let relative = position.board.isEmpty ? nil : try RelativeHandStrength(board: position.board)
        let available = Card.deck.filter { $0.mask & blocked == 0 }
        var weighted = Dictionary(uniqueKeysWithValues: ResearchRangeAssumption.allCases.map { ($0, [WeightedCombo]()) })
        for first in 0..<(available.count - 1) {
            if isCancelled() { throw PokerError.cancelled }
            for second in (first + 1)..<available.count {
                let hand = try HoleCards(available[first], available[second])
                let strength = StrengthFeature.value(hand: hand, board: position.board, relative: relative)
                weighted[.uniform]!.append(WeightedCombo(hand))
                weighted[.valueWeighted]!.append(WeightedCombo(hand, weight: 0.05 + 0.95 * pow(strength, 4)))
                weighted[.polarized]!.append(WeightedCombo(hand, weight: 0.05 + 0.95 * pow(strength, 5) + 0.25 * pow(1 - strength, 3)))
            }
        }
        return try weighted.mapValues { try HandRange($0) }
    }
}
