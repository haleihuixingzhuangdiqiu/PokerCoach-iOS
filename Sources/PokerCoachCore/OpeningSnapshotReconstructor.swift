import Foundation

/// Rules evaluated for one possible interpretation of the visible opening wagers.
public struct OpeningRuleInterpretation: Sendable, Equatable {
    public let rules: PokerGameRules
    public let usesOptionalStraddle: Bool
    public let straddleSeat: Int?
}

/// A reconstructed action has no observation time: it was inferred from a snapshot.
public struct ReconstructedOpeningAction: Sendable, Equatable {
    public let seatID: Int
    public let action: PokerAction
}

public enum OpeningReconstructionSource: String, Sendable, Codable {
    case singleOpenSnapshot
}

public enum OpeningReconstructionAssumption: String, Sendable, Codable {
    /// Caller supplied the complete set of table rules still possible.
    case providedRuleHypothesesAreExhaustive
    /// All dealt seats appear clockwise, with complete live street contributions.
    case completeClockwiseDealtSeats
    /// No ante, carried-over pot, unrecorded dead money, or refund precedes this snapshot.
    case noAnteExternalPotOrRefund
}

/// Current rules state, proven only within the listed snapshot assumptions. This
/// is deliberately not VerifiedPublicHand and cannot claim observed continuous history.
public struct OpeningSnapshotReconstruction: Sendable, Equatable {
    public let state: TableState
    /// Rules state immediately before the inferred raise, for conditioning an
    /// explicit action model without labelling it observed continuous history.
    public let stateBeforeOpening: TableState
    public let hero: Int
    public let cards: HoleCards
    public let openerSeat: Int
    public let openingRaiseTo: Int
    public let inferredActions: [ReconstructedOpeningAction]
    public let compatibleRules: [OpeningRuleInterpretation]
    public let assumptions: [OpeningReconstructionAssumption]
    public let source: OpeningReconstructionSource = .singleOpenSnapshot
    public var historyComplete: Bool { false }
}

/// Narrow preflop recovery: forced bets, one full opening raise, and visible folds.
/// Missing fields, limps, multiple voluntary payers, all-ins and unresolved rule
/// alternatives fail closed. It never changes the continuous PublicHandLedger.
public enum OpeningSnapshotReconstructor {
    public static func reconstruct(_ snapshot: PublicTableSnapshot,
                                   ruleHypotheses: [PokerGameRules] = []) throws -> OpeningSnapshotReconstruction {
        try validate(snapshot)
        let rules: [PokerGameRules]
        if let observed = snapshot.rules {
            guard ruleHypotheses.isEmpty || ruleHypotheses.allSatisfy({ $0 == observed }) else {
                throw PokerError.invalid("规则候选与已识别桌规冲突")
            }
            rules = [observed]
        } else {
            guard !ruleHypotheses.isEmpty, ruleHypotheses.count <= 8 else {
                throw PokerError.invalid("快照重建需要已确认桌规或完整规则候选")
            }
            rules = ruleHypotheses.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
        for rule in rules { try rule.validate() }

        var matched: [Candidate] = []
        var unresolved: [String] = []
        for rule in rules {
            let choices: [Bool]
            switch rule.utgStraddle {
            case .disabled:
                // A positive straddler observation excludes ordinary-blind rules.
                if snapshot.optionalStraddle == true || snapshot.straddleSeat != nil { continue }
                choices = [false]
            case .mandatory:
                if snapshot.optionalStraddle == false { continue }
                choices = [false]
            case .optional:
                if let used = snapshot.optionalStraddle { choices = [used] }
                else if snapshot.straddleSeat != nil { choices = [true] }
                else { choices = [false, true] }
            }
            for choice in choices {
                switch evaluate(snapshot, rules: rule, optionalStraddle: choice) {
                case .impossible: break
                case .unresolved(let reason): unresolved.append(reason)
                case .matched(let candidate): matched.append(candidate)
                }
            }
        }
        // Unsupported alternatives are NOT evidence against those alternatives.
        // For example, 20/50/100 + 280 may be either a straddle and open, or a
        // raise to 100 followed by a re-raise to 280 when straddle use is unknown.
        guard unresolved.isEmpty else {
            throw PokerError.invalid("仍有未排除的规则或行动解释：" + unresolved[0])
        }
        guard let first = matched.first else { throw PokerError.invalid("金额或行动顺序不能证明单次开池") }
        guard matched.allSatisfy({ $0.state == first.state && $0.stateBeforeOpening == first.stateBeforeOpening
            && $0.actions == first.actions
            && $0.opener == first.opener && $0.raiseTo == first.raiseTo }) else {
            throw PokerError.invalid("不同合法解释产生不同的行动权或开池记录")
        }
        var assumptions: [OpeningReconstructionAssumption] = [.completeClockwiseDealtSeats, .noAnteExternalPotOrRefund]
        if snapshot.rules == nil { assumptions.append(.providedRuleHypothesesAreExhaustive) }
        return .init(state: first.state, stateBeforeOpening: first.stateBeforeOpening,
            hero: snapshot.hero, cards: snapshot.cards,
            openerSeat: first.opener, openingRaiseTo: first.raiseTo, inferredActions: first.actions,
            compatibleRules: matched.map(\.interpretation), assumptions: assumptions)
    }

    private struct Candidate {
        let state: TableState
        let stateBeforeOpening: TableState
        let opener: Int
        let raiseTo: Int
        let actions: [ReconstructedOpeningAction]
        let interpretation: OpeningRuleInterpretation
    }
    private enum Evaluation { case impossible, unresolved(String), matched(Candidate) }

    private static func validate(_ s: PublicTableSnapshot) throws {
        guard (2...9).contains(s.seats.count), Set(s.seats.map(\.id)).count == s.seats.count,
              s.seats.indices.contains(s.hero), s.board.isEmpty,
              let button = s.button, s.seats.indices.contains(button),
              let actor = s.actor, s.seats.indices.contains(actor),
              s.seats[s.hero].folded == false, s.seats[actor].folded == false,
              s.straddleSeat.map({ s.seats.indices.contains($0) }) ?? true,
              let pot = s.pot, (0...9_000_000_000).contains(pot),
              s.seats.allSatisfy({ seat in
                  guard let stack = seat.stack, let wager = seat.streetWager, seat.folded != nil else { return false }
                  return (1...1_000_000_000).contains(stack) && (0...1_000_000_000).contains(wager)
                      && stack + wager <= 1_000_000_000
              }), pot == s.seats.reduce(0, { $0 + $1.streetWager! }) else {
            throw PokerError.invalid("单次开池重建需要翻前完整筹码、全部投入、庄家和行动者，且无全下")
        }
    }

    private static func evaluate(_ s: PublicTableSnapshot, rules: PokerGameRules,
                                 optionalStraddle: Bool) -> Evaluation {
        // Ante accounting cannot be reconstructed as remaining stack + street wager.
        guard rules.ante == 0 else { return .unresolved("存在前注或死钱") }
        let seats = s.seats.map { Seat(id: $0.id, stack: $0.stack! + $0.streetWager!) }
        guard let start = try? rules.startHand(seats: seats, button: s.button!, optionalStraddle: optionalStraddle) else {
            return .impossible
        }
        if let observedStraddler = s.straddleSeat, observedStraddler != start.positions.straddle { return .impossible }
        if s.optionalStraddle == false, start.positions.straddle != nil { return .impossible }
        // Wagers cannot be below an already-posted forced bet. Do not reinterpret
        // the difference as a refund in this narrowly bounded recovery path.
        guard s.seats.indices.allSatisfy({ s.seats[$0].streetWager! >= start.state.seats[$0].streetCommitted }) else {
            return .impossible
        }
        let payers = s.seats.indices.filter { s.seats[$0].streetWager! > start.state.seats[$0].streetCommitted }
        guard payers.count == 1 else {
            return .unresolved(payers.isEmpty ? "尚无单次开池" : "多名玩家自愿投入，可能有跟注或再加注")
        }
        let opener = payers[0], raiseTo = s.seats[opener].streetWager!
        guard s.seats[opener].folded == false else { return .impossible }
        guard raiseTo > start.state.currentBet else {
            return raiseTo == start.state.currentBet ? .unresolved("投入也可能只是跟注") : .impossible
        }
        guard raiseTo >= start.state.minimumRaiseTo else { return .impossible }
        var state = start.state
        var actions: [ReconstructedOpeningAction] = []
        while state.actor != opener {
            guard let i = state.actor, actions.count < s.seats.count else { return .impossible }
            if state.amountToCall(i) == 0 { return .unresolved("开池前可能已有不移动筹码的让牌") }
            guard s.seats[i].folded == true, let next = try? state.applying(.fold) else { return .impossible }
            actions.append(.init(seatID: state.seats[i].id, action: .fold)); state = next
        }
        let stateBeforeOpening = state
        guard let opened = try? state.applying(.raiseTo(raiseTo)) else { return .impossible }
        actions.append(.init(seatID: state.seats[opener].id, action: .raiseTo(raiseTo)))
        state = opened
        while state.actor != s.actor {
            guard let i = state.actor, actions.count <= 2 * s.seats.count,
                  s.seats[i].folded == true, let next = try? state.applying(.fold) else { return .impossible }
            actions.append(.init(seatID: state.seats[i].id, action: .fold)); state = next
        }
        guard state.pot == s.pot, !state.roundComplete,
              state.seats.indices.allSatisfy({ i in
                  state.seats[i].stack == s.seats[i].stack
                      && state.seats[i].streetCommitted == s.seats[i].streetWager
                      && state.seats[i].folded == s.seats[i].folded
              }), (try? state.validate()) != nil else { return .impossible }
        return .matched(.init(state: state, stateBeforeOpening: stateBeforeOpening,
            opener: opener, raiseTo: raiseTo, actions: actions,
            interpretation: .init(rules: rules, usesOptionalStraddle: optionalStraddle,
                                  straddleSeat: start.positions.straddle)))
    }
}
