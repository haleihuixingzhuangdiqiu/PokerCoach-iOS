import Foundation

public extension PublicActionRangeModel {
    /// Conditions only the single inferred opener. This overload never creates
    /// observed history, trains a persistent player profile, or double-counts frames.
    static func analyze(opening: OpeningSnapshotReconstruction, prior: HandRange? = nil,
                        profiles: [BehaviorProfile] = [.tight, .neutral, .loose],
                        isCancelled: () -> Bool = { false }) throws -> PublicActionRangeResult {
        let began = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws { if isCancelled() { throw PokerError.cancelled } }
        try checkpoint()
        try opening.state.validate()
        try opening.stateBeforeOpening.validate()
        guard opening.state.seats.indices.contains(opening.hero),
              opening.state.seats.indices.contains(opening.openerSeat),
              opening.state.board.isEmpty, opening.stateBeforeOpening.board.isEmpty,
              !profiles.isEmpty, profiles.count <= 8,
              !opening.compatibleRules.isEmpty, opening.compatibleRules.count <= 16,
              opening.inferredActions.count <= 2 * opening.state.seats.count else {
            throw PokerError.invalid("快照范围更新需要有效的单次开池重建和行为模型")
        }
        // Validate provenance by independently reconstructing the supplied end
        // snapshot under EVERY surviving rules interpretation. Do not trust a
        // memberwise/internal construction with altered opener, before-state or events.
        for interpretation in opening.compatibleRules {
            try checkpoint()
            let optional: Bool?
            switch interpretation.rules.utgStraddle {
            case .mandatory: optional = nil
            case .disabled, .optional: optional = interpretation.usesOptionalStraddle
            }
            let snapshot = PublicTableSnapshot(seats: opening.state.seats.map {
                .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded)
            }, hero: opening.hero, cards: opening.cards, board: [], pot: opening.state.pot,
               button: opening.state.button, actor: opening.state.actor, rules: interpretation.rules,
               optionalStraddle: optional, straddleSeat: interpretation.straddleSeat)
            let replay = try OpeningSnapshotReconstructor.reconstruct(snapshot)
            guard replay.state == opening.state, replay.stateBeforeOpening == opening.stateBeforeOpening,
                  replay.openerSeat == opening.openerSeat, replay.openingRaiseTo == opening.openingRaiseTo,
                  replay.inferredActions == opening.inferredActions,
                  replay.compatibleRules.contains(interpretation) else {
                throw PokerError.invalid("快照开池者、动作或前后状态不能按规则重建")
            }
        }
        let initial = try (prior ?? uniformPrior).excluding(opening.cards.cards)
        let opponents = opening.state.live.filter { $0 != opening.hero }
        var ranges: [Int: HandRange] = [:], counts: [Int: Int] = [:]
        for seat in opponents {
            try checkpoint()
            if seat == opening.openerSeat {
                ranges[seat] = try applyingActionLikelihood(to: initial, seat: seat,
                    before: opening.stateBeforeOpening, action: .raiseTo(opening.openingRaiseTo),
                    profiles: profiles, relative: nil, isCancelled: isCancelled)
                counts[seat] = 1
            } else { ranges[seat] = initial; counts[seat] = 0 }
        }
        try checkpoint()
        var limitations = [
            "来源是单次开池快照推断，未观测到连续完整历史；只按重建的开池动作调整开池者。",
            "行为类别似然沿用未训练策略的等权混合，并加入2%类别噪声；不是校准的人类画像或GTO范围。",
            "使用重建的开池前底池和跟注成本；按加注类别更新，未拟合具体开池尺寸。",
            "其他未弃牌玩家保留排除本人底牌的先验，未将尚未行动视为跟注或弃牌；抽样时再联合排除暗牌冲突。"
        ]
        if opening.assumptions.contains(.providedRuleHypothesesAreExhaustive) {
            limitations.append("重建以调用方提供的规则候选已覆盖全部可能为条件；不是新观察到的桌规证据。")
        }
        let label = opening.openerSeat == opening.hero
            ? "单次开池快照推断：本人开池，对手保留先验"
            : "单次开池快照推断：开池者条件范围（未校准模型）"
        return .init(ranges: ranges, actionsUsedBySeat: counts, label: label, limitations: limitations,
                     elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
}
