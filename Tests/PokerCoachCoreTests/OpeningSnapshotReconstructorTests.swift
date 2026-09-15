import XCTest
@testable import PokerCoachCore

final class OpeningSnapshotReconstructorTests: XCTestCase {
    private func rules(_ policy: UTGStraddlePolicy = .disabled) throws -> PokerGameRules {
        try .init(smallBlind: 20, bigBlind: 50, utgStraddle: policy)
    }
    private func start(_ count: Int = 8, button: Int = 7,
                       policy: UTGStraddlePolicy = .optional(amount: 100), used: Bool = true) throws -> PokerHandStart {
        try rules(policy).startHand(seats: (0..<count).map { Seat(id: 100 + $0, stack: 5_000) },
            button: button, optionalStraddle: used)
    }
    private func snapshot(_ state: TableState, rules: PokerGameRules?, used: Bool?, straddler: Int?) throws -> PublicTableSnapshot {
        .init(seats: state.seats.map {
            .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded)
        }, hero: state.actor!, cards: try HoleCards("QcQh"), board: state.board, pot: state.pot,
           button: state.button, actor: state.actor, rules: rules, optionalStraddle: used, straddleSeat: straddler)
    }

    func testQueensFacing280OpenRestoresPendingPlayersWithoutFreeCalls() throws {
        let initial = try start()
        let current = try initial.state.applying(.raiseTo(280))
        let input = try snapshot(current, rules: rules(.optional(amount: 100)), used: true, straddler: 2)
        let result = try OpeningSnapshotReconstructor.reconstruct(input)
        XCTAssertEqual(result.state, current)
        XCTAssertEqual(result.stateBeforeOpening, initial.state)
        XCTAssertEqual(result.openerSeat, 3)
        XCTAssertEqual(result.hero, 4)
        XCTAssertEqual(result.state.pot, 450)
        XCTAssertEqual(result.state.seats[4].streetCommitted, 0)
        XCTAssertEqual(result.state.amountToCall(4), 280)
        XCTAssertEqual(result.state.pending, [4, 5, 6, 7, 0, 1, 2])
        XCTAssertEqual(result.state.lastFullRaise, 180)
        XCTAssertEqual(result.state.minimumRaiseTo, 460)
        XCTAssertEqual(result.state.seats.map(\.streetCommitted), [20, 50, 100, 280, 0, 0, 0, 0])
        XCTAssertEqual(result.inferredActions.map(\.action), [.raiseTo(280)])
        XCTAssertFalse(result.historyComplete)
        XCTAssertEqual(result.source, .singleOpenSnapshot)
        XCTAssertFalse(result.assumptions.contains(.providedRuleHypothesesAreExhaustive))
        // Following the hero call still leaves six actual decisions. No opponent
        // receives a free showdown while only the hero's call enters the pot.
        let called = try result.state.applying(.call)
        XCTAssertEqual(called.pot, 730)
        XCTAssertEqual(called.pending, [5, 6, 7, 0, 1, 2])
    }

    func testVisibleFoldsBeforeAndAfterOpeningAreReplayedInOrder() throws {
        let initial = try start(button: 0)
        let beforeOpening = try initial.state.applying(.fold).applying(.fold)
        let current = try beforeOpening.applying(.raiseTo(280)).applying(.fold)
        let result = try OpeningSnapshotReconstructor.reconstruct(
            snapshot(current, rules: rules(.optional(amount: 100)), used: true, straddler: 3))
        XCTAssertEqual(result.state, current)
        XCTAssertEqual(result.stateBeforeOpening, beforeOpening)
        XCTAssertEqual(result.openerSeat, 6)
        XCTAssertEqual(result.inferredActions.map(\.seatID), [104, 105, 106, 107])
        XCTAssertEqual(result.inferredActions.map(\.action), [.fold, .fold, .raiseTo(280), .fold])
    }

    func testOpeningFromBlindUsesTotalAndDoesNotPayForcedBetTwice() throws {
        let initial = try start(3, button: 0, policy: .disabled, used: false)
        let before = try initial.state.applying(.fold)
        let current = try before.applying(.raiseTo(150))
        let result = try OpeningSnapshotReconstructor.reconstruct(snapshot(current, rules: rules(), used: false, straddler: nil))
        XCTAssertEqual(result.state.pot, 200) // Original 70 plus SB's additional 130.
        XCTAssertEqual(result.state.seats[1].stack, 4_850)
        XCTAssertEqual(result.state.amountToCall(2), 100)
        XCTAssertEqual(result.state.minimumRaiseTo, 250)
        XCTAssertEqual(result.state, current)
        XCTAssertEqual(result.stateBeforeOpening, before)
    }

    func testAllClockwiseButtonsForTwoThroughNinePlayersRoundTrip() throws {
        for count in 2...9 {
            for button in 0..<count {
                for usesStraddle in [false, true] where count >= 3 || !usesStraddle {
                    let policy: UTGStraddlePolicy = usesStraddle ? .optional(amount: 100) : .disabled
                    let initial = try start(count, button: button, policy: policy, used: usesStraddle)
                    let current = try initial.state.applying(.raiseTo(3 * initial.state.minimumBet))
                    let input = try snapshot(current, rules: rules(policy), used: usesStraddle,
                                             straddler: initial.positions.straddle)
                    let result = try OpeningSnapshotReconstructor.reconstruct(input)
                    XCTAssertEqual(result.state, current)
                    XCTAssertEqual(result.stateBeforeOpening, initial.state)
                    XCTAssertFalse(result.historyComplete)
                }
            }
        }
    }

    func testUnknownActualStraddleCannotDiscardPossibleRaiseReraiseAlternative() throws {
        let current = try start().state.applying(.raiseTo(280))
        let unknown = try snapshot(current, rules: rules(.optional(amount: 100)), used: nil, straddler: nil)
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(unknown)) { error in
            XCTAssertTrue(String(describing: error).contains("多名玩家自愿投入"))
        }
        // Even specifying several possible rules cannot silently select the
        // one whose simpler explanation happens to be supported by this API.
        let noRules = try snapshot(current, rules: nil, used: nil, straddler: nil)
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(noRules,
            ruleHypotheses: [rules(), rules(.mandatory(amount: 100))]))
    }

    func testExhaustiveRuleHypothesesMayOnlyRemoveProvablyImpossibleAlternatives() throws {
        // A single UTG open to 150 with no other voluntary payments cannot arise
        // from a live 100 straddle: it would be an illegal non-all-in raise.
        let initial = try start(4, button: 0, policy: .disabled, used: false)
        let current = try initial.state.applying(.raiseTo(150))
        let unknownUse = try snapshot(current, rules: rules(.optional(amount: 100)), used: nil, straddler: nil)
        let resolvedUse = try OpeningSnapshotReconstructor.reconstruct(unknownUse)
        XCTAssertEqual(resolvedUse.state, current)
        XCTAssertEqual(resolvedUse.compatibleRules.count, 1)
        XCTAssertFalse(resolvedUse.compatibleRules[0].usesOptionalStraddle)

        let noRules = try snapshot(current, rules: nil, used: nil, straddler: nil)
        let result = try OpeningSnapshotReconstructor.reconstruct(noRules,
            ruleHypotheses: [rules(), rules(.mandatory(amount: 100))])
        XCTAssertEqual(result.state, current)
        XCTAssertTrue(result.assumptions.contains(.providedRuleHypothesesAreExhaustive))
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(noRules))
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(unknownUse, ruleHypotheses: [rules()]))
    }

    func testMultiPayerLimpReraiseAndAllInRemainOutsideNarrowRecovery() throws {
        let initial = try start()
        let opened = try initial.state.applying(.raiseTo(280))
        for state in [try opened.applying(.call), try opened.applying(.raiseTo(700)), try initial.state.applying(.call)] {
            XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(
                snapshot(state, rules: rules(.optional(amount: 100)), used: true, straddler: 2)))
        }
        let allIn = try initial.state.applying(.raiseTo(5_000))
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(
            snapshot(allIn, rules: rules(.optional(amount: 100)), used: true, straddler: 2)))
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(
            snapshot(initial.state, rules: rules(.optional(amount: 100)), used: true, straddler: 2)))
    }

    func testMissingFieldsInconsistentPotAndActorOrStraddlerAreRejected() throws {
        let current = try start().state.applying(.raiseTo(280))
        let valid = try snapshot(current, rules: rules(.optional(amount: 100)), used: true, straddler: 2)
        var missingStack = valid.seats; missingStack[0].stack = nil
        var missingWager = valid.seats; missingWager[1].streetWager = nil
        var missingFold = valid.seats; missingFold[2].folded = nil
        var negative = valid.seats; negative[3].stack = -1
        var impossibleFold = valid.seats; impossibleFold[6].folded = true
        for seats in [missingStack, missingWager, missingFold, negative, impossibleFold] {
            let invalid = PublicTableSnapshot(seats: seats, hero: valid.hero, cards: valid.cards, board: [],
                pot: valid.pot, button: valid.button, actor: valid.actor, rules: valid.rules,
                optionalStraddle: true, straddleSeat: 2)
            XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(invalid))
        }
        let invalid: [PublicTableSnapshot] = [
            .init(seats: valid.seats, hero: 4, cards: valid.cards, board: [], pot: 449, button: 7, actor: 4,
                  rules: valid.rules, optionalStraddle: true, straddleSeat: 2),
            .init(seats: valid.seats, hero: 4, cards: valid.cards, board: [], pot: 450, button: nil, actor: 4,
                  rules: valid.rules, optionalStraddle: true, straddleSeat: 2),
            .init(seats: valid.seats, hero: 4, cards: valid.cards, board: [], pot: 450, button: 7, actor: nil,
                  rules: valid.rules, optionalStraddle: true, straddleSeat: 2),
            .init(seats: valid.seats, hero: 4, cards: valid.cards, board: [], pot: 450, button: 7, actor: 5,
                  rules: valid.rules, optionalStraddle: true, straddleSeat: 2),
            .init(seats: valid.seats, hero: 4, cards: valid.cards, board: [], pot: 450, button: 7, actor: 4,
                  rules: valid.rules, optionalStraddle: true, straddleSeat: 3),
            .init(seats: valid.seats, hero: 4, cards: valid.cards, board: try Card.parse("2c7d9h"), pot: 450, button: 7, actor: 4,
                  rules: valid.rules, optionalStraddle: true, straddleSeat: 2)
        ]
        for s in invalid { XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(s)) }
    }

    func testUnseenFreeCheckBeforeOpeningIsNotInvented() throws {
        let equal = try PokerGameRules(smallBlind: 50, bigBlind: 50)
        let initial = try equal.startHand(seats: [Seat(id: 0, stack: 1_000), Seat(id: 1, stack: 1_000)], button: 0).state
        let current = try initial.applying(.check).applying(.raiseTo(150))
        XCTAssertThrowsError(try OpeningSnapshotReconstructor.reconstruct(snapshot(current, rules: equal, used: false, straddler: nil)))
    }
}
