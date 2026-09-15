import XCTest
@testable import PokerCoachCore

final class LedgerAuditTests: XCTestCase {
    private func initial() throws -> TableState {
        try PokerGameRules(smallBlind: 20, bigBlind: 50)
            .startHand(seats: (0..<4).map { Seat(id: 100 + $0, stack: 1_000) }, button: 0).state
    }

    private func snapshot(_ state: TableState, hero: Int = 1, omitActor: Bool = false,
                          omitWagerAt: Int? = nil, omitFoldAt: Int? = nil,
                          rules: PokerGameRules? = nil, straddleSeat: Int? = nil) throws -> PublicTableSnapshot {
        let seats = state.seats.enumerated().map { index, seat in
            PublicSeatSnapshot(id: seat.id, stack: seat.stack,
                streetWager: omitWagerAt == index ? nil : seat.streetCommitted,
                folded: omitFoldAt == index ? nil : seat.folded)
        }
        return .init(seats: seats, hero: hero, cards: try HoleCards("AcJc"), board: state.board,
            pot: state.pot, button: state.button, actor: omitActor ? nil : state.actor,
            rules: try rules ?? PokerGameRules(smallBlind: 20, bigBlind: 50), straddleSeat: straddleSeat)
    }

    private func confirm(_ snapshot: PublicTableSnapshot, in ledger: inout PublicHandLedger, at time: Double) {
        ledger.ingest(snapshot, timestamp: time, now: time)
        ledger.ingest(snapshot, timestamp: time + 0.05, now: time + 0.05)
    }

    private func flopReady(maxActions: Int = 32) throws -> (PublicHandLedger, TableState) {
        var ledger = PublicHandLedger(maxActions: maxActions)
        var state = try initial()
        confirm(try snapshot(state), in: &ledger, at: 1)
        for step in 0..<4 {
            state = try state.applying(state.amountToCall(state.actor!) > 0 ? .call : .check)
            confirm(try snapshot(state), in: &ledger, at: 1.2 + Double(step) * 0.2)
        }
        state = try state.advancing(to: Card.parse("2c7d9h"))
        confirm(try snapshot(state), in: &ledger, at: 2)
        XCTAssertNotNil(ledger.current(now: 2.05))
        return (ledger, state)
    }

    /// Seat 3 can have folded on either the flop or turn. Both legal histories
    /// converge to exactly the same river state, including lastFullRaise/pending.
    private func riverWithAmbiguousFoldTime(_ flop: TableState) throws -> TableState {
        var state = try flop.applying(.check).applying(.check).applying(.fold).applying(.check)
        state = try state.advancing(to: Card.parse("2c7d9hTs"))
        state = try state.applying(.check).applying(.check).applying(.check)
        return try state.advancing(to: Card.parse("2c7d9hTs3s"))
    }

    func testUnknownActorCannotRefreshOldActionableTurn() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial, hero: 3), in: &ledger, at: 1)
        XCTAssertNotNil(ledger.current(now: 1.05))
        confirm(try snapshot(initial, hero: 3, omitActor: true), in: &ledger, at: 1.2)
        XCTAssertNotNil(ledger.hand, "Keep reconciled history for later observations")
        XCTAssertNil(ledger.current(now: 1.25), "An old actor is not a freshly observed actor")
        confirm(try snapshot(initial, hero: 3), in: &ledger, at: 1.4)
        XCTAssertNotNil(ledger.current(now: 1.45))
    }

    func testFastSingleFrameTransitionsPreserveHistoryButNeverPublishEarly() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial), in: &ledger, at: 1)
        let raised = try initial.applying(.raiseTo(150))
        ledger.ingest(try snapshot(raised), timestamp: 1.2, now: 1.2)
        XCTAssertNil(ledger.current(now: 1.2))
        XCTAssertEqual(ledger.hand?.state, initial, "One frame only updates the private working state")
        let called = try raised.applying(.call)
        ledger.ingest(try snapshot(called), timestamp: 1.3, now: 1.3)
        XCTAssertNil(ledger.current(now: 1.3))
        ledger.ingest(try snapshot(called), timestamp: 1.4, now: 1.4)
        let hand = try XCTUnwrap(ledger.current(now: 1.4))
        XCTAssertEqual(hand.state, called)
        XCTAssertEqual(hand.actions.map(\.action), [.raiseTo(150), .call])
        XCTAssertEqual(hand.actions.map(\.seatID), [103, 100])
        XCTAssertEqual(hand.state.lastFullRaise, 100)
        XCTAssertTrue(hand.actionSequenceUnique)
    }

    func testFastBootstrapStillRequiresTwoIdenticalFrames() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        ledger.ingest(try snapshot(initial), timestamp: 1, now: 1)
        let raised = try initial.applying(.raiseTo(150))
        confirm(try snapshot(raised), in: &ledger, at: 1.2)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 1.25))
    }

    func testSkippingTwoPayersStillDoesNotInventIntermediateRaiseHistory() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial), in: &ledger, at: 1)
        let skipped = try initial.applying(.raiseTo(150)).applying(.call)
        confirm(try snapshot(skipped), in: &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.25))
        XCTAssertEqual(ledger.hand?.state, initial)
        XCTAssertTrue(ledger.status.contains("中间加注记录"))
    }

    func testMissingWagerCannotHideAPlayerWhoPaidNewChips() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial), in: &ledger, at: 1)
        let raised = try initial.applying(.raiseTo(150))
        confirm(try snapshot(raised, omitWagerAt: 3), in: &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.25))
        XCTAssertEqual(ledger.hand?.state, initial)
        confirm(try snapshot(initial, omitFoldAt: 0), in: &ledger, at: 1.4)
        XCTAssertNil(ledger.current(now: 1.45), "Unknown live/folded state cannot be filled as not-folded")
    }

    func testEquivalentRiverStateDoesNotProveTheMissingActionSequence() throws {
        for omitActor in [false, true] {
            var (ledger, flop) = try flopReady()
            let river = try riverWithAmbiguousFoldTime(flop)
            confirm(try snapshot(river, omitActor: omitActor), in: &ledger, at: 2.2)
            XCTAssertNil(ledger.current(now: 2.25))
            if omitActor {
                // Unknown actor allows multiple final pending states, so this may
                // reject the transition entirely. A later actor still cannot prove
                // which street contained the fold.
                confirm(try snapshot(river), in: &ledger, at: 2.4)
                XCTAssertNil(ledger.current(now: 2.45))
            }
            let hand = try XCTUnwrap(ledger.hand)
            XCTAssertEqual(hand.state, river)
            XCTAssertFalse(hand.actionSequenceUnique)
            XCTAssertThrowsError(try FullHandDecisionRequest(hand: hand,
                controls: .init(heroTurnConfirmed: true, checkAvailable: true,
                    visibleBetAmounts: [50], heroStreetCommitted: 0), observedPot: river.pot))
        }
    }

    func testSearchDepthLimitCannotTurnAnUnseenAlternativeIntoUniqueHistory() throws {
        var (ledger, flop) = try flopReady(maxActions: 9)
        let river = try riverWithAmbiguousFoldTime(flop)
        // Folding on the flop takes 9 transitions; folding on the turn takes 10.
        // A 9-step search must not certify the first path just because it cut off the second.
        confirm(try snapshot(river), in: &ledger, at: 2.2)
        XCTAssertNil(ledger.current(now: 2.25))
        XCTAssertEqual(ledger.hand?.state, flop)
        XCTAssertTrue(ledger.status.contains("上限"))
    }

    func testConflictingControlsAndIncrementalAmountsCannotBeUsedAsRaises() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial, hero: 3), in: &ledger, at: 1)
        let hand = try XCTUnwrap(ledger.current(now: 1.05))
        let valid = try FullHandDecisionRequest(hand: hand,
            controls: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 50,
                heroStreetCommitted: 0, visibleRaiseToAmounts: [100]), observedPot: 70)
        XCTAssertEqual(valid.allowedActions, [.fold, .call, .raiseTo(100)])
        let invalid: [VisiblePassiveActions] = [
            .init(heroTurnConfirmed: true, foldAvailable: true, checkAvailable: true,
                  callAmount: 50, heroStreetCommitted: 0),
            .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 50,
                  visibleBetAmounts: [100], heroStreetCommitted: 0),
            .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 50,
                  heroStreetCommitted: 0, visibleRaiseToAmounts: [Int.max]),
            .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 50,
                  heroStreetCommitted: 0, visibleRaiseToAmounts: Array(repeating: 100, count: 9))
        ]
        for controls in invalid {
            XCTAssertThrowsError(try FullHandDecisionRequest(hand: hand, controls: controls, observedPot: 70))
        }
    }

    func testBigBlindOptionNeedsRaiseToEvenThoughCallingCostsZero() throws {
        var ledger = PublicHandLedger()
        var state = try initial()
        confirm(try snapshot(state, hero: 2), in: &ledger, at: 1)
        for index in 0..<3 {
            state = try state.applying(.call)
            confirm(try snapshot(state, hero: 2), in: &ledger, at: 1.2 + Double(index) * 0.2)
        }
        let hand = try XCTUnwrap(ledger.current(now: 1.66))
        XCTAssertEqual(state.actor, 2)
        XCTAssertEqual(state.amountToCall(2), 0)
        XCTAssertThrowsError(try FullHandDecisionRequest(hand: hand,
            controls: .init(heroTurnConfirmed: true, checkAvailable: true,
                           visibleBetAmounts: [50], heroStreetCommitted: 50), observedPot: 200))
        let valid = try FullHandDecisionRequest(hand: hand,
            controls: .init(heroTurnConfirmed: true, checkAvailable: true,
                           heroStreetCommitted: 50, visibleRaiseToAmounts: [100]), observedPot: 200)
        XCTAssertEqual(valid.allowedActions, [.check, .raiseTo(100)])
    }

    func testResetDiscardsUnconfirmedWorkingTransitions() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial), in: &ledger, at: 1)
        let raised = try initial.applying(.raiseTo(150))
        ledger.ingest(try snapshot(raised), timestamp: 1.2, now: 1.2)
        ledger.reset()
        confirm(try snapshot(raised), in: &ledger, at: 2)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 2.05))
    }

    func testUnknownActorBlindSnapshotStartsOnlyPrivateHistory() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        let hiddenActor = try snapshot(initial, hero: 0, omitActor: true)
        ledger.ingest(hiddenActor, timestamp: 1, now: 1)
        XCTAssertNil(ledger.hand)
        confirm(hiddenActor, in: &ledger, at: 1.1)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 1.16))
        let raised = try initial.applying(.raiseTo(150))
        ledger.ingest(try snapshot(raised, hero: 0), timestamp: 1.3, now: 1.3)
        XCTAssertNil(ledger.current(now: 1.3))
        ledger.ingest(try snapshot(raised, hero: 0), timestamp: 1.4, now: 1.4)
        let hand = try XCTUnwrap(ledger.current(now: 1.4))
        XCTAssertEqual(hand.state, raised)
        XCTAssertEqual(hand.actions.map(\.action), [.raiseTo(150)])
        let request = try FullHandDecisionRequest(hand: hand,
            controls: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 150,
                           heroStreetCommitted: 0), observedPot: 220)
        XCTAssertEqual(request.allowedActions, [.fold, .call])
    }

    func testUnknownActorThirdBlindSnapshotCanReplayOnlyVisibleFoldPrefix() throws {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .mandatory(amount: 100))
        var state = try rules.startHand(seats: (0..<8).map { Seat(id: $0, stack: 1_000) }, button: 3).state
        for _ in 0..<5 { state = try state.applying(.fold) }
        XCTAssertEqual(state.actor, 4)
        var ledger = PublicHandLedger()
        confirm(try snapshot(state, hero: 4, omitActor: true, rules: rules, straddleSeat: 6), in: &ledger, at: 1)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 1.05))
        confirm(try snapshot(state, hero: 4, rules: rules, straddleSeat: 6), in: &ledger, at: 1.2)
        let hand = try XCTUnwrap(ledger.current(now: 1.25))
        XCTAssertEqual(hand.state, state)
        XCTAssertEqual(hand.actions.map(\.seatID), [7, 0, 1, 2, 3])
        XCTAssertEqual(hand.actions.map(\.action), Array(repeating: .fold, count: 5))
        XCTAssertEqual(hand.state.amountToCall(4), 80)
    }

    func testUnknownActorCannotBootstrapAFreeBlindOptionOrNonprefixFolds() throws {
        let equalBlinds = try PokerGameRules(smallBlind: 50, bigBlind: 50)
        let freeOption = try equalBlinds.startHand(seats: [Seat(id: 0, stack: 1_000), Seat(id: 1, stack: 1_000)], button: 0).state
        XCTAssertEqual(freeOption.amountToCall(0), 0)
        var ledger = PublicHandLedger()
        confirm(try snapshot(freeOption, hero: 0, omitActor: true, rules: equalBlinds), in: &ledger, at: 1)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 1.05))
        XCTAssertTrue(ledger.status.contains("不能排除已让牌"))

        let original = try snapshot(initial(), omitActor: true)
        var seats = original.seats
        seats[0].folded = true // Seat 3 has not acted; seat 0 cannot yet have folded.
        let invalid = PublicTableSnapshot(seats: seats, hero: original.hero, cards: original.cards,
            board: [], pot: original.pot, button: original.button, actor: nil, rules: original.rules)
        confirm(invalid, in: &ledger, at: 2)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 2.05))
    }

    func testInheritedStaticFieldsDoNotResetStableConfirmationButMissingMoneyDoes() throws {
        var ledger = PublicHandLedger()
        let initial = try initial()
        confirm(try snapshot(initial), in: &ledger, at: 1)
        let original = try snapshot(initial)
        let staticLabelsMissing = PublicTableSnapshot(seats: original.seats, hero: original.hero,
            cards: original.cards, board: [], pot: original.pot, button: nil, actor: original.actor)
        ledger.ingest(staticLabelsMissing, timestamp: 1.2, now: 1.2)
        XCTAssertNotNil(ledger.current(now: 1.2), "Known hand rules and button do not require fresh OCR every frame")
        var seats = original.seats
        seats[3].stack = nil
        let moneyMissing = PublicTableSnapshot(seats: seats, hero: original.hero,
            cards: original.cards, board: [], pot: original.pot, button: nil, actor: original.actor)
        ledger.ingest(moneyMissing, timestamp: 1.3, now: 1.3)
        XCTAssertNil(ledger.current(now: 1.3))
        XCTAssertEqual(ledger.hand?.state, initial)
    }

    /// Reproduces 0024→0025: KhQs, dealer at core 5, straddler at core 0,
    /// 20/50/100 forced wagers and pot 170; the purple label disappears before
    /// the second observation. Balances are controlled test values.
    private func shortOpeningLabelFixture() throws -> (TableState, PublicTableSnapshot) {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .optional(amount: 100))
        let state = try rules.startHand(seats: (0..<8).map { Seat(id: $0, stack: 2_000) },
            button: 5, optionalStraddle: true).state
        let visible = PublicTableSnapshot(seats: state.seats.map {
            .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded)
        }, hero: 4, cards: try HoleCards("KhQs"), board: [], pot: 170, button: 5, actor: nil,
           rules: rules, optionalStraddle: true, straddleSeat: 0)
        return (state, visible)
    }

    private func withoutOpeningLabels(_ s: PublicTableSnapshot, keepRules: Bool = true) -> PublicTableSnapshot {
        .init(seats: s.seats, hero: s.hero, cards: s.cards, board: s.board, pot: s.pot,
              button: s.button, actor: s.actor, rules: keepRules ? s.rules : nil)
    }

    func testOpeningStraddleLabelSurvivesNextIdenticalForcedFrame() throws {
        for keepRules in [true, false] {
            var (state, visible) = try shortOpeningLabelFixture()
            var ledger = PublicHandLedger()
            ledger.ingest(visible, timestamp: 1, now: 1)
            let hidden = withoutOpeningLabels(visible, keepRules: keepRules)
            ledger.ingest(hidden, timestamp: 1.1, now: 1.1)
            XCTAssertNil(ledger.hand)
            XCTAssertNil(ledger.current(now: 1.1))
            XCTAssertEqual(ledger.status, "开局已记录，等待当前行动位置")
            for _ in 0..<3 { state = try state.applying(.fold) }
            let heroTurn = PublicTableSnapshot(seats: state.seats.map {
                .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded)
            }, hero: 4, cards: visible.cards, board: [], pot: 170, button: 5, actor: 4)
            confirm(heroTurn, in: &ledger, at: 1.3)
            let hand = try XCTUnwrap(ledger.current(now: 1.36))
            XCTAssertEqual(hand.state, state)
            XCTAssertTrue(hand.usesOptionalStraddle)
            XCTAssertEqual(hand.straddleSeat, 0)
            XCTAssertEqual(hand.actions.map(\.seatID), [1, 2, 3])
            XCTAssertEqual(hand.state.minimumRaiseTo, 200)
        }
    }

    func testOpeningLabelEvidenceIsDiscardedOnConflictingIdentityOrMoney() throws {
        let (_, visible) = try shortOpeningLabelFixture()
        let hidden = withoutOpeningLabels(visible)
        var changedMoney = hidden.seats; changedMoney[0].streetWager = 99
        var changedStack = hidden.seats; changedStack[1].stack = 1_999
        var missingMoney = hidden.seats; missingMoney[6].streetWager = nil
        var changedFold = hidden.seats; changedFold[1].folded = true
        let invalid: [PublicTableSnapshot] = [
            .init(seats: hidden.seats, hero: 4, cards: try HoleCards("AhKs"), board: [], pot: 170, button: 5, actor: nil),
            .init(seats: hidden.seats, hero: 3, cards: hidden.cards, board: [], pot: 170, button: 5, actor: nil),
            .init(seats: hidden.seats, hero: 4, cards: hidden.cards, board: [], pot: 170, button: 6, actor: nil),
            .init(seats: hidden.seats, hero: 4, cards: hidden.cards, board: [], pot: 170, button: nil, actor: nil),
            .init(seats: hidden.seats, hero: 4, cards: hidden.cards, board: try Card.parse("2c7d9h"), pot: 170, button: 5, actor: nil),
            .init(seats: changedMoney, hero: 4, cards: hidden.cards, board: [], pot: 169, button: 5, actor: nil),
            .init(seats: changedStack, hero: 4, cards: hidden.cards, board: [], pot: 170, button: 5, actor: nil),
            .init(seats: missingMoney, hero: 4, cards: hidden.cards, board: [], pot: 170, button: 5, actor: nil),
            .init(seats: changedFold, hero: 4, cards: hidden.cards, board: [], pot: 170, button: 5, actor: nil),
            .init(seats: hidden.seats, hero: 4, cards: hidden.cards, board: [], pot: 170, button: 5, actor: nil,
                  rules: visible.rules, optionalStraddle: false),
            .init(seats: hidden.seats, hero: 4, cards: hidden.cards, board: [], pot: 170, button: 5, actor: nil,
                  rules: visible.rules, optionalStraddle: true, straddleSeat: 1)
        ]
        for conflicting in invalid {
            var ledger = PublicHandLedger()
            ledger.ingest(visible, timestamp: 1, now: 1)
            ledger.ingest(conflicting, timestamp: 1.1, now: 1.1)
            confirm(hidden, in: &ledger, at: 1.2)
            XCTAssertNil(ledger.hand)
            XCTAssertNil(ledger.current(now: 1.25))
            XCTAssertNotEqual(ledger.status, "开局已记录，等待当前行动位置")
        }
    }

    func testOpeningLabelEvidenceExpiresAndResetClearsIt() throws {
        let (_, visible) = try shortOpeningLabelFixture()
        let hidden = withoutOpeningLabels(visible)
        var ledger = PublicHandLedger()
        ledger.ingest(visible, timestamp: 1, now: 1)
        confirm(hidden, in: &ledger, at: 1.81)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 1.87))
        XCTAssertNotEqual(ledger.status, "开局已记录，等待当前行动位置")
        ledger.ingest(visible, timestamp: 2, now: 2)
        ledger.reset()
        confirm(hidden, in: &ledger, at: 2.1)
        XCTAssertNil(ledger.hand)
        XCTAssertNotEqual(ledger.status, "开局已记录，等待当前行动位置")
    }

    func testThreeBlindNumbersAloneCannotEstablishActualStraddle() throws {
        let (_, visible) = try shortOpeningLabelFixture()
        var ledger = PublicHandLedger()
        confirm(withoutOpeningLabels(visible), in: &ledger, at: 1)
        XCTAssertNil(ledger.hand)
        XCTAssertNil(ledger.current(now: 1.05))
        XCTAssertTrue(ledger.status.contains("尚未确认本手是否实际投入第三盲"))
    }
}
