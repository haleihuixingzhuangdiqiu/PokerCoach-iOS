import Foundation

/// Limits an explicitly untrained continuation policy; these are not equilibrium settings.
public struct RolloutConfiguration: Sendable, Codable, Equatable {
    public var includeFutureStreets: Bool
    public var minimumSamples: Int
    public var maxRaisesPerStreet: Int
    public init(includeFutureStreets: Bool = false, minimumSamples: Int = 2, maxRaisesPerStreet: Int = 2) {
        self.includeFutureStreets = includeFutureStreets
        self.minimumSamples = minimumSamples
        self.maxRaisesPerStreet = maxRaisesPerStreet
    }
    public static let fullHand = RolloutConfiguration(includeFutureStreets: true, minimumSamples: 64)
    func validate(budget: ComputeBudget) throws {
        guard (2...budget.samples).contains(minimumSamples), (0...4).contains(maxRaisesPerStreet) else {
            throw PokerError.invalid("完整牌局推演的最少样本数或每街加注上限无效")
        }
    }
}

/// Requires a complete, audited betting state and the real currently enabled actions.
/// Estimates incremental chip EV under equal-weight behavior hypotheses, never GTO.
public enum FullHandDecisionEngine {
    public static func analyze(state: TableState, hero: Int, cards: HoleCards,
                               ranges: [Int: HandRange], allowedActions: [PokerAction],
                               profiles: [BehaviorProfile] = [.tight, .neutral, .loose],
                               heroContinuation: BehaviorProfile = .neutral,
                               configuration: RolloutConfiguration = .fullHand,
                               budget: ComputeBudget = .init(samples: 256, milliseconds: 600),
                               isCancelled: () -> Bool = { false }) throws -> DecisionResult {
        try DecisionEngine.analyze(state: state, hero: hero, cards: cards, ranges: ranges,
                                   profiles: profiles, heroContinuation: heroContinuation,
                                   candidateActions: allowedActions, configuration: configuration,
                                   budget: budget, isCancelled: isCancelled)
    }
}

enum RolloutInterruption: Error { case deadline }

/// Deliberately contains no opponent hole cards and no undealt board suffix.
struct RolloutPolicyInformation: Equatable {
    let actor: Int
    let ownCards: HoleCards
    let publicBoard: [Card]
}

enum BettingRollout {
    /// At a policy boundary, only own cards/current public board create the strength feature.
    /// The observer is internal and used by information-boundary tests, never by action selection.
    static func finishStreet(state: TableState, hands: [Int: HoleCards], hero: Int,
                             opponentProfile: BehaviorProfile, heroProfile: BehaviorProfile,
                             raisesAlready: Int, configuration: RolloutConfiguration,
                             relative: RelativeHandStrength? = nil, rng: inout SplitMix64,
                             checkpoint: () throws -> Void,
                             observe: ((RolloutPolicyInformation) -> Void)? = nil) throws -> TableState {
        var table = state, raises = raisesAlready, steps = 0
        var strengths: [Int: Double] = [:]
        while !table.roundComplete {
            try checkpoint()
            steps += 1
            guard steps <= 128, let actor = table.actor, let own = hands[actor] else {
                throw PokerError.invalid("下注推演缺少本人底牌或超过动作上限")
            }
            observe?(.init(actor: actor, ownCards: own, publicBoard: table.board))
            let strength: Double
            if let cached = strengths[actor] { strength = cached }
            else {
                strength = StrengthFeature.value(hand: own, board: table.board, relative: relative)
                strengths[actor] = strength
            }
            let profile = actor == hero ? heroProfile : opponentProfile
            let action = profile.action(state: table, strength: strength, raiseCount: raises,
                                        maximumRaises: configuration.maxRaisesPerStreet, rng: &rng)
            if case .raiseTo = action { raises += 1 }
            table = try table.applying(action)
        }
        return table
    }

    static func finishFutureStreets(state: TableState, completeBoard: [Card], hands: [Int: HoleCards],
                                   hero: Int, opponentProfile: BehaviorProfile, heroProfile: BehaviorProfile,
                                   configuration: RolloutConfiguration, rng: inout SplitMix64,
                                   checkpoint: () throws -> Void,
                                   observe: ((RolloutPolicyInformation) -> Void)? = nil) throws -> TableState {
        guard configuration.includeFutureStreets else { return state }
        guard completeBoard.count == 5, Array(completeBoard.prefix(state.board.count)) == state.board else {
            throw PokerError.invalid("未来公共牌与已公开牌面不一致")
        }
        var table = state
        while table.live.count > 1 && table.board.count < 5 {
            try checkpoint()
            let count = table.board.isEmpty ? 3 : table.board.count + 1
            // Only this newly public prefix is available to the betting policy.
            table = try table.advancing(to: Array(completeBoard.prefix(count)))
            table = try finishStreet(state: table, hands: hands, hero: hero,
                                     opponentProfile: opponentProfile, heroProfile: heroProfile,
                                     raisesAlready: 0, configuration: configuration, rng: &rng,
                                     checkpoint: checkpoint, observe: observe)
        }
        return table
    }
}
