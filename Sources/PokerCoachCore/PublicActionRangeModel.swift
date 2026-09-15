import Foundation

public struct PublicActionRangeResult: Sendable {
    /// Keys are current TableState indices; no hidden opponent cards are accepted as input.
    public let ranges: [Int: HandRange]
    public let actionsUsedBySeat: [Int: Int]
    public var observationCounts: [Int: Int] { actionsUsedBySeat }
    public let label: String
    public let limitations: [String]
    public let elapsedMilliseconds: Double
}

/// Action-conditioned ranges under an explicit, untrained generative behavior model.
/// Rebuilds from the prior and the unique complete history on every call: repeated frames
/// cannot count the same action twice. Chance conditioning removes known card collisions.
public enum PublicActionRangeModel {
    static let uniformPrior = HandRange.random

    public static func analyze(hand: VerifiedPublicHand, prior: HandRange? = nil,
                               profiles: [BehaviorProfile] = [.tight, .neutral, .loose],
                               isCancelled: () -> Bool = { false }) throws -> PublicActionRangeResult {
        let began = ProcessInfo.processInfo.systemUptime
        try hand.state.validate()
        guard hand.actionSequenceUnique, hand.state.seats.indices.contains(hand.hero),
              !profiles.isEmpty, profiles.count <= 8, hand.actions.count <= 128,
              Set(hand.cards.cards + hand.state.board).count == 2 + hand.state.board.count else {
            throw PokerError.invalid("动作范围更新需要唯一完整历史、有效本人牌及至多128个事件")
        }
        func checkpoint() throws { if isCancelled() { throw PokerError.cancelled } }
        try checkpoint()
        // Contributions have not yet been awarded during an active hand. This reconstructs
        // true pre-posting balances without inventing an observed pot, pressure or blind.
        let opening = hand.state.seats.map { Seat(id: $0.id, stack: $0.stack + $0.committed) }
        var replay = try hand.rules.startHand(seats: opening, button: hand.state.button,
                                              optionalStraddle: hand.usesOptionalStraddle).state
        var evidence: [(seat: Int, before: TableState, action: PokerAction)] = []
        var lastObservedAt = -Double.infinity
        for event in hand.actions {
            try checkpoint()
            guard event.observedAt.isFinite, event.observedAt >= 0, event.observedAt >= lastObservedAt,
                  event.board.count <= hand.state.board.count,
                  event.board == Array(hand.state.board.prefix(event.board.count)) else {
                throw PokerError.invalid("行动时间或公共牌顺序不符合已验证历史")
            }
            while replay.board.count < event.board.count {
                let count = replay.board.isEmpty ? 3 : replay.board.count + 1
                replay = try replay.advancing(to: Array(event.board.prefix(count)))
            }
            guard replay.board == event.board, let actor = replay.actor,
                  replay.seats[actor].id == event.seatID else {
                throw PokerError.invalid("动作席位或顺序不能从强制盲注重放")
            }
            let next = try replay.applying(event.action)
            evidence.append((actor, replay, event.action))
            replay = next; lastObservedAt = event.observedAt
        }
        while replay.board.count < hand.state.board.count {
            let count = replay.board.isEmpty ? 3 : replay.board.count + 1
            replay = try replay.advancing(to: Array(hand.state.board.prefix(count)))
        }
        guard replay == hand.state else { throw PokerError.invalid("动作重放末态与完整牌局不一致，不能用于范围更新") }

        let known = hand.cards.cards + hand.state.board
        let initial = try (prior ?? uniformPrior).excluding(known)
        let opponents = hand.state.live.filter { $0 != hand.hero }
        var ranges: [Int: HandRange] = [:], counts: [Int: Int] = [:]
        var relativeByBoard: [[Card]: RelativeHandStrength] = [:]
        for seat in opponents {
            try checkpoint()
            var posterior = initial
            let actions = evidence.filter { $0.seat == seat }
            for observation in actions {
                try checkpoint()
                let board = observation.before.board
                let relative: RelativeHandStrength?
                if board.isEmpty { relative = nil }
                else if let cached = relativeByBoard[board] { relative = cached }
                else {
                    let value = try RelativeHandStrength(board: board)
                    relativeByBoard[board] = value; relative = value
                }
                posterior = try applyingActionLikelihood(to: posterior, seat: seat,
                    before: observation.before, action: observation.action, profiles: profiles,
                    relative: relative, isCancelled: isCancelled)
            }
            ranges[seat] = posterior; counts[seat] = actions.count
        }
        let total = counts.values.reduce(0, +)
        let label = total > 0 ? "按\(total)次已确认对手行动更新范围（未校准模型）"
            : (prior == nil ? "尚无对手行动证据，使用随机范围先验" : "尚无对手行动证据，使用给定范围先验")
        return PublicActionRangeResult(ranges: ranges, actionsUsedBySeat: counts, label: label,
            limitations: ["只使用唯一历史中的本人可见公共行动，不知道对手真实底牌。",
                          "行为类别似然沿用未训练策略的等权混合，并加入2%类别噪声；不是校准的人类画像或GTO范围。",
                          "使用动作前真实底池和跟注成本；仅按弃牌、过牌、跟注、加注类别更新，未拟合具体下注尺寸。",
                          "各座位范围在发牌抽样时再联合排除冲突；未对已弃牌玩家建模其暗牌分布。"],
            elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
    }

    /// Shared by observed-history and explicitly reconstructed-snapshot entries.
    /// Callers validate the action/state and remove known-card collisions first.
    static func applyingActionLikelihood(to prior: HandRange, seat: Int, before: TableState,
                                        action: PokerAction, profiles: [BehaviorProfile],
                                        relative: RelativeHandStrength?,
                                        isCancelled: () -> Bool) throws -> HandRange {
        // 2% category noise preserves possible holdings under this uncalibrated
        // model. Free-check fold remains a legal, though dominated, category.
        let legalCategories = 2 + (before.mayRaise(seat) ? 1 : 0)
        var updated: [WeightedCombo] = []
        updated.reserveCapacity(prior.combos.count)
        for (index, combo) in prior.combos.enumerated() {
            if index % 64 == 0, isCancelled() { throw PokerError.cancelled }
            let strength = StrengthFeature.value(hand: combo.hand, board: before.board, relative: relative)
            let modelProbability = profiles.reduce(0) {
                $0 + $1.categoryLikelihood(action: action, state: before, strength: strength)
            } / Double(profiles.count)
            let likelihood = 0.98 * modelProbability + 0.02 / Double(legalCategories)
            updated.append(WeightedCombo(combo.hand, weight: combo.weight * likelihood))
        }
        return try HandRange(updated)
    }
}
