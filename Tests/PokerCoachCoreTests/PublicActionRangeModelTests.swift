import XCTest
@testable import PokerCoachCore

final class PublicActionRangeModelTests: XCTestCase {
    private func history(raise: Bool = true) throws -> VerifiedPublicHand {
        let rules = try PokerGameRules(smallBlind: 5, bigBlind: 10)
        let initial = try rules.startHand(seats: (0..<3).map { Seat(id: 100 + $0, stack: 200) }, button: 0).state
        let actions: [LedgerAction] = raise ? [.init(seatID: 100, board: [], action: .raiseTo(30), observedAt: 1)] : []
        let state = raise ? try initial.applying(.raiseTo(30)) : initial
        return VerifiedPublicHand(id: 1, state: state, hero: 1, cards: try HoleCards("QcJd"), rules: rules,
            usesOptionalStraddle: false, straddleSeat: nil, actions: actions, actionSequenceUnique: true)
    }
    func testConfirmedRaiseReweightsOnlyThatSeatAndRepeatedSnapshotIsIdempotent() throws {
        let hand = try history(), prior = try HandRange.parse("AsAd,7h2s")
        let first = try PublicActionRangeModel.analyze(hand: hand, prior: prior)
        let repeated = try PublicActionRangeModel.analyze(hand: hand, prior: prior)
        let aa = try HoleCards("AsAd")
        XCTAssertGreaterThan(try XCTUnwrap(first.ranges[0]?.combos.first { $0.hand == aa }?.weight), 0.5)
        XCTAssertEqual(first.ranges[2]?.combos.map(\.weight), [0.5, 0.5])
        XCTAssertEqual(first.actionsUsedBySeat, [0: 1, 2: 0])
        for seat in [0, 2] {
            XCTAssertEqual(first.ranges[seat]?.combos.map(\.weight), repeated.ranges[seat]?.combos.map(\.weight))
            XCTAssertEqual(first.ranges[seat]?.combos.map(\.hand), repeated.ranges[seat]?.combos.map(\.hand))
        }
        XCTAssertTrue(first.label.contains("未校准"))
    }
    func testNoActionHistoryKeepsUniformKnownCardFilteredPrior() throws {
        let hand = try history(raise: false)
        let result = try PublicActionRangeModel.analyze(hand: hand)
        XCTAssertEqual(result.ranges[0]?.combos.count, 50 * 49 / 2)
        for range in result.ranges.values {
            XCTAssertTrue(range.combos.allSatisfy { $0.hand.mask & hand.cards.mask == 0 })
            for combo in range.combos { XCTAssertEqual(combo.weight, 1 / 1225.0, accuracy: 1e-12) }
        }
        XCTAssertEqual(result.actionsUsedBySeat, [0: 0, 2: 0])
        XCTAssertTrue(result.label.contains("随机范围先验"))
    }
    func testAmbiguousDuplicateAndMismatchedHistoriesCannotTrainRange() throws {
        let hand = try history()
        func changed(state: TableState? = nil, events: [LedgerAction]? = nil, unique: Bool = true) -> VerifiedPublicHand {
            .init(id: hand.id, state: state ?? hand.state, hero: hand.hero, cards: hand.cards, rules: hand.rules,
                  usesOptionalStraddle: false, straddleSeat: nil, actions: events ?? hand.actions, actionSequenceUnique: unique)
        }
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(hand: changed(unique: false)))
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(hand: changed(events: hand.actions + hand.actions)))
        var wrong = hand.state; wrong.seats[0].stack -= 1; wrong.seats[0].committed += 1
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(hand: changed(state: wrong)))
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(hand: changed(events: [
            .init(seatID: 102, board: [], action: .raiseTo(30), observedAt: 1)
        ])))
    }
    func testReplayAllowsAllInStreetsWithoutActionsAndCurrentStreetWithoutAction() throws {
        let rules = try PokerGameRules(smallBlind: 5, bigBlind: 10)
        var state = try rules.startHand(seats: (0..<3).map { Seat(id: $0, stack: 10) }, button: 0).state
        var actions: [LedgerAction] = []
        while !state.roundComplete {
            let actor = try XCTUnwrap(state.actor)
            actions.append(.init(seatID: actor, board: [], action: .call, observedAt: 1))
            state = try state.applying(.call)
        }
        state = try state.advancing(to: Card.parse("2c3d4h"))
        state = try state.advancing(to: Card.parse("2c3d4h5s"))
        state = try state.advancing(to: Card.parse("2c3d4h5s6c"))
        let hand = VerifiedPublicHand(id: 5, state: state, hero: 2, cards: try HoleCards("QsJs"), rules: rules,
            usesOptionalStraddle: false, straddleSeat: nil, actions: actions, actionSequenceUnique: true)
        let result = try PublicActionRangeModel.analyze(hand: hand, prior: .parse("AhAd,KhKd"))
        XCTAssertEqual(Set(result.ranges.keys), [0, 1])
        XCTAssertEqual(result.actionsUsedBySeat, [0: 1, 1: 1])
    }
    func testReplaySupportsStraddleAndCurrentFlopBeforeFirstAction() throws {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .mandatory(amount: 100))
        var state = try rules.startHand(seats: (0..<4).map { Seat(id: $0, stack: 1000) }, button: 0).state
        var actions: [LedgerAction] = []
        while !state.roundComplete {
            let actor = try XCTUnwrap(state.actor)
            let action: PokerAction = state.amountToCall(actor) > 0 ? .call : .check
            actions.append(.init(seatID: actor, board: [], action: action, observedAt: 1))
            state = try state.applying(action)
        }
        state = try state.advancing(to: Card.parse("2c3d4h"))
        let hand = VerifiedPublicHand(id: 3, state: state, hero: 1, cards: try HoleCards("QsJs"), rules: rules,
            usesOptionalStraddle: false, straddleSeat: 3, actions: actions, actionSequenceUnique: true)
        let result = try PublicActionRangeModel.analyze(hand: hand, prior: .parse("AhAd,KhKd"))
        XCTAssertEqual(Set(result.ranges.keys), [0, 2, 3])
        XCTAssertEqual(state.minimumRaiseTo, 50)
    }
    func testLikelihoodMatchesSamePolicyEmpiricalActionFrequencies() throws {
        let state = try history(raise: false).state
        for profile in [BehaviorProfile.tight, .neutral, .loose, .checkCall] {
            for strength in [0.3, 0.8] {
                var rng = SplitMix64(state: 726), folded = 0, called = 0, raised = 0
                for _ in 0..<12_000 {
                    switch profile.action(state: state, strength: strength, raiseCount: 0, maximumRaises: 4, rng: &rng) {
                    case .fold: folded += 1
                    case .call: called += 1
                    case .raiseTo: raised += 1
                    case .check: XCTFail("Facing a blind cannot check")
                    }
                }
                let probabilities = [profile.categoryLikelihood(action: .fold, state: state, strength: strength),
                                     profile.categoryLikelihood(action: .call, state: state, strength: strength),
                                     profile.categoryLikelihood(action: .raiseTo(30), state: state, strength: strength)]
                XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 1e-12)
                for (count, probability) in zip([folded, called, raised], probabilities) {
                    XCTAssertEqual(Double(count) / 12_000, probability, accuracy: 0.018)
                }
            }
        }
    }
    func testCancellationDoesNotReturnPartiallyUpdatedSeatRanges() throws {
        var checkpoints = 0
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(hand: history(), isCancelled: {
            checkpoints += 1; return checkpoints > 4
        })) { error in
            guard case PokerError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
    }
}
