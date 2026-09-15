import Foundation

/// A transparent, untrained rollout policy. Parameters are behavioral assumptions, not GTO frequencies.
public struct BehaviorProfile: Sendable, Codable {
    public let name: String
    public let callOffset: Double
    public let aggression: Double
    public let alwaysContinue: Bool
    public init(name: String, callOffset: Double, aggression: Double, alwaysContinue: Bool = false) throws {
        guard callOffset.isFinite, (-0.5...0.5).contains(callOffset), aggression.isFinite, (0...2).contains(aggression) else {
            throw PokerError.invalid("对手模型参数无效")
        }
        self.name = name; self.callOffset = callOffset; self.aggression = aggression; self.alwaysContinue = alwaysContinue
    }
    public static let tight = try! BehaviorProfile(name: "偏紧假设", callOffset: -0.12, aggression: 0.55)
    public static let neutral = try! BehaviorProfile(name: "中性假设", callOffset: 0, aggression: 0.8)
    public static let loose = try! BehaviorProfile(name: "偏松假设", callOffset: 0.12, aggression: 1)
    public static let checkCall = try! BehaviorProfile(name: "固定过牌/跟注", callOffset: 0, aggression: 0, alwaysContinue: true)

    /// Marginal category probabilities from the same policy used by the simulator.
    /// Search-depth caps are computational limits, not evidence that real players cannot reraise.
    func categoryLikelihood(action: PokerAction, state: TableState, strength: Double) -> Double {
        let actor = state.actor!, cost = state.amountToCall(actor)
        if alwaysContinue {
            return action == (cost == 0 ? .check : .call) ? 1 : 0
        }
        let pressure = Double(cost) / Double(max(1, state.pot + cost))
        let threshold = 0.40 + 0.40 * pressure - callOffset
        let continuation = 0.03 + 0.94 / (1 + exp(-11 * (strength - threshold)))
        let fold = cost > 0 && strength < 0.99 ? 1 - continuation : 0
        let raise = state.mayRaise(actor)
            ? min(0.8, aggression * (max(0, strength - 0.65) * 1.5 + 0.025)) : 0
        switch action {
        case .fold: return fold
        case .check: return cost == 0 ? 1 - raise : 0
        case .call: return cost > 0 ? (1 - fold) * (1 - raise) : 0
        case .raiseTo: return (1 - fold) * raise
        }
    }

    /// Only this player's own cards and the current public board enter the policy.
    /// Undealt board cards and the other seats' hidden cards never enter the policy.
    func action(state: TableState, strength: Double, raiseCount: Int, maximumRaises: Int = 2, rng: inout SplitMix64) -> PokerAction {
        let i = state.actor!, cost = state.amountToCall(i)
        let passive: PokerAction = cost == 0 ? .check : .call
        if alwaysContinue { return passive }
        let pressure = Double(cost) / Double(max(1, state.pot + cost))
        let threshold = 0.40 + 0.40 * pressure - callOffset
        let continueProbability = 0.03 + 0.94 / (1 + exp(-11 * (strength - threshold)))
        if cost > 0 && strength < 0.99 && rng.unit() > continueProbability { return .fold }
        let raiseProbability = min(0.8, aggression * (max(0, strength - 0.65) * 1.5 + 0.025))
        if raiseCount < maximumRaises, state.mayRaise(i), rng.unit() < raiseProbability {
            let maximum = state.seats[i].streetCommitted + state.seats[i].stack
            let target = max(state.minimumRaiseTo, state.currentBet + Int(Double(state.pot + cost) * 0.67))
            return .raiseTo(min(maximum, target))
        }
        return passive
    }
}

/// This is a policy feature, NOT a probability of winning or a trained hand-strength model.
enum StrengthFeature {
    static func value(hand: HoleCards, board: [Card], relative: RelativeHandStrength? = nil) -> Double {
        let hi = max(hand.first.rank, hand.second.rank), lo = min(hand.first.rank, hand.second.rank)
        if board.isEmpty {
            if hi == lo { return min(0.94, 0.50 + Double(hi - 2) * 0.035) }
            return min(0.8, 0.19 + Double(hi - 2) * 0.023 + Double(lo - 2) * 0.013
                       + (hand.first.suit == hand.second.suit ? 0.05 : 0)
                       + (hi - lo == 1 ? 0.035 : 0))
        }
        let all = hand.cards + board, value = HandEvaluator.value(all)
        if board.count == 5, RiverNutsPolicyGuard.isCertainlyUnbeatable(hand: hand, board: board, value: value) {
            return 1
        }
        var feature = [0.16, 0.43, 0.64, 0.77, 0.85, 0.90, 0.96, 0.985, 0.995][value.category.rawValue]
        let boardHigh = board.map(\.rank).max()!
        if value.category == .highCard { feature += Double(hi - 2) * 0.012 }
        if value.category == .pair {
            let pairRank = (value.score >> 16) & 15
            let ownPair = hand.cards.contains { $0.rank == pairRank }
            if !ownPair { feature = 0.22 + Double(hi - 2) * 0.011 }
            else { feature += pairRank >= boardHigh ? 0.16 : Double(pairRank - 2) * 0.006 }
        }
        if board.count == 5, HandEvaluator.value(board) == value {
            // Playing the board is often weak, but folding a publicly unbeatable
            // board invents fold equity in both current and future-street rollouts.
            if SharedRiverNuts.isUnbeatable(board) { return 1 }
            feature = 0.25
        }
        if let relative { feature = (try? relative.share(for: hand)) ?? feature }
        if board.count < 5 {
            let suitCount = Dictionary(grouping: all, by: \.suit).mapValues(\.count)
            for (suit, count) in suitCount where count == 4 && hand.cards.contains(where: { $0.suit == suit }) {
                feature += 0.09
            }
            var ranks = Set(all.map(\.rank)); if ranks.contains(14) { ranks.insert(1) }
            if (1...10).contains(where: { low in (low..<(low + 5)).filter { ranks.contains($0) }.count == 4 }) { feature += 0.035 }
        }
        return min(0.999, max(0.01, feature))
    }
}

/// Sufficient river-only constraints, not a complete nuts classifier or an equity estimate.
/// Uses only this seat's cards and the public board. At most ten five-rank windows
/// are checked; no 990-combination evaluation is performed in sampled rollouts.
enum RiverNutsPolicyGuard {
    static func isCertainlyUnbeatable(hand: HoleCards, board: [Card], value: HandValue) -> Bool {
        guard board.count == 5, value.category.rawValue >= HandCategory.straight.rawValue else { return false }
        if SharedRiverNuts.isUnbeatable(board) { return true }
        let high = (value.score >> 16) & 15
        if value.category == .straightFlush { return high == 14 }
        let ranks = Dictionary(grouping: board, by: \.rank).mapValues(\.count)
        let suits = Dictionary(grouping: board, by: \.suit).mapValues(\.count)
        let maxSuitCount = suits.values.max()!
        if value.category == .straight {
            // With no public pair or three-card suit, no boat/quads/flush is
            // possible; Broadway is therefore unbeatable, though it can tie.
            return high == 14 && ranks.count == 5 && maxSuitCount <= 2
        }
        if value.category == .quads {
            // Exclude possible straight flushes and a second public pair that
            // could give an opponent different quads. A private quad card blocks
            // anyone from matching this quad; public quads require the top kicker.
            guard maxSuitCount <= 2, ranks.filter({ $0.value >= 2 }).allSatisfy({ $0.key == high }) else { return false }
            if (ranks[high] ?? 0) < 4 { return true }
            return ((value.score >> 12) & 15) == (high == 14 ? 13 : 14)
        }
        if value.category == .flush, ranks.count == 5,
           let ace = hand.cards.first(where: { $0.rank == 14 && (suits[$0.suit] ?? 0) >= 3 }) {
            // A private ace beats every other flush in this suit. An unpaired
            // board excludes boats/quads; explicitly exclude possible straight flushes.
            let publicMask = board.reduce(UInt64(0)) { $0 | $1.mask }
            for top in 5...14 {
                var needed = 0, possible = true
                for offset in 0..<5 {
                    let rawRank = top - offset, rank = rawRank == 1 ? 14 : rawRank
                    let mask = Card(unchecked: (rank - 2) * 4 + ace.suit).mask
                    if publicMask & mask == 0 {
                        if hand.mask & mask != 0 { possible = false; break }
                        needed += 1
                    }
                }
                if possible && needed <= 2 { return false }
            }
            return true
        }
        return false
    }
}

/// Exact for a five-card public board that no legal two-card holding can improve.
/// This is a policy guard, never a win-probability estimate. Constant-time rank/suit
/// conditions avoid a 1,081-combination enumeration inside every sampled river.
enum SharedRiverNuts {
    static func isUnbeatable(_ board: [Card]) -> Bool {
        guard board.count == 5 else { return false }
        let value = HandEvaluator.value(board)
        let high = (value.score >> 16) & 15
        switch value.category {
        case .straightFlush:
            return high == 14
        case .quads:
            // All four cards of this rank are public. The highest other rank is
            // A, except when aces themselves are the quads, in which case it is K.
            let kicker = (value.score >> 12) & 15
            return kicker == (high == 14 ? 13 : 14)
        case .straight:
            // Broadway cannot be outranked by another straight. Distinct ranks
            // preclude boats/quads, and at most two cards per suit preclude a flush.
            let suitCounts = Dictionary(grouping: board, by: \.suit).mapValues(\.count)
            return high == 14 && suitCounts.values.allSatisfy { $0 <= 2 }
        default:
            return false
        }
    }
}

public struct ScenarioEV: Sendable, Codable {
    public let name: String
    public let mean: Double
    public let standardError: Double
    public let samples: Int
}

public struct ActionEstimate: Sendable, Codable {
    public let action: PokerAction
    public let additionalChips: Int
    public let scenarios: [ScenarioEV]
    /// Equal-weight mean of the explicitly listed, uncalibrated behavioral hypotheses.
    public var expectedEV: Double { scenarios.isEmpty ? 0 : scenarios.reduce(0) { $0 + $1.mean } / Double(scenarios.count) }
    public var worstScenarioEV: Double { scenarios.map(\.mean).min() ?? 0 }
    public var bestScenarioEV: Double { scenarios.map(\.mean).max() ?? 0 }
}

public struct DecisionResult: Sendable, Codable {
    public let equity: EquityResult
    public let actions: [ActionEstimate]
    public let suggested: PokerAction
    public let agreementAcrossScenarios: Bool
    /// True only when the equal-weight mixture's paired interval beats every candidate alternative.
    public let statisticallySeparated: Bool
    public let minimumPairedGap95: Double
    public let completedBudget: Bool
    public let samplesPerScenario: Int
    public let minimumSamplesRequired: Int
    public let includesFutureStreets: Bool
    public let elapsedMilliseconds: Double
    public let limitations: [String]
    public let reasons: [String]
}

public enum DecisionEngine {
    /// Complete the current betting round, optionally rolling out each later street as it is revealed.
    /// Full side-pot payouts minus NEW hero commitments give incremental EV; sunk chips are not deducted twice.
    public static func analyze(state: TableState, hero: Int, cards: HoleCards,
                               ranges: [Int: HandRange], profiles: [BehaviorProfile] = [.tight, .neutral, .loose],
                               heroContinuation: BehaviorProfile = .neutral,
                               candidateActions: [PokerAction]? = nil,
                               configuration: RolloutConfiguration = .init(),
                               budget: ComputeBudget = .init(samples: 2_000, milliseconds: 2_000),
                               isCancelled: () -> Bool = { false }) throws -> DecisionResult {
        let start = ProcessInfo.processInfo.systemUptime
        var elapsed: Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        func checkpoint() throws {
            if isCancelled() { throw PokerError.cancelled }
            if elapsed >= Double(budget.milliseconds) { throw RolloutInterruption.deadline }
        }
        try state.validate(); try budget.validate(); try configuration.validate(budget: budget)
        if isCancelled() { throw PokerError.cancelled }
        guard state.actor == hero, state.seats.indices.contains(hero), !state.roundComplete,
              !profiles.isEmpty, profiles.count <= 8 else { throw PokerError.invalid("必须是我方行动且提供对手行为假设") }
        let opponents = state.live.filter { $0 != hero }
        guard Set(ranges.keys) == Set(opponents) else { throw PokerError.invalid("每名未弃牌对手需要且仅需要一个范围") }
        let candidates = candidateActions ?? state.legalActions()
        guard !candidates.isEmpty, candidates.count <= 32, Set(candidates).count == candidates.count else {
            throw PokerError.invalid("必须提供非空且不重复的实际可用动作")
        }
        // Explicit observed sizes need not match the default pot-fraction abstraction.
        for action in candidates { _ = try state.applying(action) }
        let request = try EquityRequest(hero: cards, board: state.board, opponents: opponents.map { ranges[$0]! })
        let sampler = try DealSampler(request)
        let relative = state.board.isEmpty ? nil : try RelativeHandStrength(board: state.board)
        let count = candidates.count, scenarioCount = profiles.count
        var moments = [[Moments]](repeating: [Moments](repeating: .init(), count: count), count: scenarioCount)
        var mixturePairs = [[Moments]](repeating: [Moments](repeating: .init(), count: count), count: count)
        var equityMoments = Moments(), wins = 0, ties = 0
        var rng = SplitMix64(state: budget.seed), attempts = 0, accepted = 0
        sampling: while accepted < budget.samples && attempts < max(10_000, budget.samples * 200) {
            do {
                try checkpoint()
                attempts += 1
                guard let dealt = sampler.holeDeal(&rng) else { continue }
                var hands = [hero: cards]
                for (offset, i) in opponents.enumerated() { hands[i] = dealt[offset] }
                let responseSeed = rng.next()
                var endings = [[TableState]](repeating: [], count: scenarioCount)
                for s in 0..<scenarioCount {
                    for candidate in candidates {
                        try checkpoint()
                        var policyRNG = SplitMix64(state: responseSeed)
                        let initialRaises: Int = { if case .raiseTo = candidate { return 1 }; return 0 }()
                        let end = try BettingRollout.finishStreet(state: state.applying(candidate), hands: hands, hero: hero,
                            opponentProfile: profiles[s], heroProfile: heroContinuation, raisesAlready: initialRaises,
                            configuration: configuration, relative: relative, rng: &policyRNG, checkpoint: checkpoint)
                        endings[s].append(end)
                    }
                }
                // Complete all current-street policy decisions BEFORE generating the future board.
                // Every candidate shares this deal; later policies receive only revealed prefixes.
                let board = sampler.runout(dealt, &rng), futureSeed = rng.next()
                var values = [hero: HandEvaluator.value(cards.cards + board)]
                for (offset, i) in opponents.enumerated() { values[i] = HandEvaluator.value(dealt[offset].cards + board) }
                var payoffs = [[Double]](repeating: [Double](repeating: 0, count: count), count: scenarioCount)
                for s in 0..<scenarioCount {
                    for a in 0..<count {
                        try checkpoint()
                        var futureRNG = SplitMix64(state: futureSeed)
                        let end = try BettingRollout.finishFutureStreets(state: endings[s][a], completeBoard: board,
                            hands: hands, hero: hero, opponentProfile: profiles[s], heroProfile: heroContinuation,
                            configuration: configuration, rng: &futureRNG, checkpoint: checkpoint)
                        let gross = try PotSettlement.expectedAwards(seats: end.seats, values: values)[hero]
                        payoffs[s][a] = gross - Double(end.seats[hero].committed - state.seats[hero].committed)
                    }
                }
                // Commit a sample only after ALL candidate/scenario rollouts finish. A timeout
                // midway through a large sample must not bias one candidate's sample count.
                let best = values.values.max()!, winners = values.values.filter { $0 == best }.count
                let share = values[hero]! == best ? 1 / Double(winners) : 0
                equityMoments.add(share)
                if share == 1 { wins += 1 } else if share > 0 { ties += 1 }
                for s in 0..<scenarioCount { for a in 0..<count { moments[s][a].add(payoffs[s][a]) } }
                let mixture = (0..<count).map { a in payoffs.reduce(0) { $0 + $1[a] } / Double(scenarioCount) }
                for a in 0..<count { for b in 0..<count { mixturePairs[a][b].add(mixture[a] - mixture[b]) } }
                accepted += 1
            } catch RolloutInterruption.deadline { break sampling }
        }
        guard accepted >= configuration.minimumSamples else {
            throw attempts >= max(10_000, budget.samples * 200) ? PokerError.incompatibleRanges : PokerError.budgetExceeded
        }
        let estimates = candidates.indices.map { a in
            let added: Int
            switch candidates[a] {
            case .fold, .check: added = 0
            case .call: added = state.amountToCall(hero)
            case .raiseTo(let n): added = n - state.seats[hero].streetCommitted
            }
            return ActionEstimate(action: candidates[a], additionalChips: added,
                scenarios: profiles.indices.map { s in ScenarioEV(name: profiles[s].name, mean: moments[s][a].mean,
                                                                  standardError: moments[s][a].standardError, samples: accepted) })
        }
        let choice = estimates.indices.max { a, b in
            if abs(estimates[a].expectedEV - estimates[b].expectedEV) < 1e-9 {
                return estimates[a].additionalChips > estimates[b].additionalChips
            }
            return estimates[a].expectedEV < estimates[b].expectedEV
        }!
        let agreement = profiles.indices.allSatisfy { s in candidates.indices.allSatisfy { moments[s][choice].mean >= moments[s][$0].mean - 1e-9 } }
        // Union bound over every ordered action pair and every possible returned sample count.
        // A sample is the mean over correlated policy scenarios using a shared deal; the variance
        // is measured on those means, not obtained by assuming the scenarios are independent.
        let comparisonCount = max(1, count * (count - 1))
        let allowance = SamplingConfidence.errorAllowance(sampleCount: accepted, targetSamples: budget.samples, errorProbability: 0.05)
        let l = log(2 * Double(comparisonCount) / allowance)
        let differenceRange = 2 * Double(state.pot + state.seats.reduce(0) { $0 + $1.stack })
        let gaps = candidates.indices.filter { $0 != choice }.map { a in
            let m = mixturePairs[choice][a]
            let width = sqrt(2 * max(0, m.variance) * l / Double(accepted)) + 7 * differenceRange * l / (3 * Double(accepted - 1))
            return m.mean - width
        }
        let minGap = gaps.min() ?? 0
        var limitations = ["对手行为和未来街策略为可解释启发式，尚未用真人数据校准；不是 GTO 求解器。",
                           configuration.includeFutureStreets
                             ? "逐街公开未来牌后推演；每街策略加注上限为 \(configuration.maxRaisesPerStreet)，超过后仅比较过牌/跟注/弃牌；不是无限深搜索。"
                             : "仅模拟当前下注轮；后续公共牌按所有人过牌至摊牌处理。",
                           "所列行为假设等权平均，不代表真人行为频率；仅对输入的各座位范围与完整下注状态有效。",
                           "统计区间只反映抽样误差，不覆盖范围错误、识别错误和行为模型错误。",
                           "收益单位为筹码；未计算抽水、比赛奖金结构、ICM 或特殊玩法奖励。"]
        if state.board.count < 5 && !configuration.includeFutureStreets { limitations.append("未来下注价值未模拟，行动排序只供研究比较。") }
        if !agreement { limitations.append("不同对手假设给出不同首选，当前建议对模型敏感。") }
        if accepted < budget.samples { limitations.append("本次达到时间或抽样上限，使用实际完成的样本数。") }
        let equity = EquityResult(equity: equityMoments.mean, outrightWinProbability: Double(wins) / Double(accepted),
            tieProbability: Double(ties) / Double(accepted), confidence95: equityMoments.boundedConfidence(targetSamples: budget.samples),
            samples: accepted, exact: false, elapsedMilliseconds: elapsed, completedBudget: accepted == budget.samples)
        let reasons = ["比较了 \(candidates.count) 个已验证合法动作；加注金额均为本轮累计加注到。",
                       "按所列行为假设等权平均收益选择；未使用最差情景或范围区间中点。",
                       "至少 \(configuration.minimumSamples) 个完整样本，实际完成 \(accepted) 个；各动作使用相同样本。",
                       agreement ? "所列对手假设的首选一致。" : "对手假设改变会影响动作排序。"]
        return DecisionResult(equity: equity, actions: estimates, suggested: candidates[choice], agreementAcrossScenarios: agreement,
            statisticallySeparated: count > 1 && accepted >= 500 && minGap > 0, minimumPairedGap95: minGap,
            completedBudget: accepted == budget.samples, samplesPerScenario: accepted,
            minimumSamplesRequired: configuration.minimumSamples, includesFutureStreets: configuration.includeFutureStreets,
            elapsedMilliseconds: elapsed, limitations: limitations, reasons: reasons)
    }
}
