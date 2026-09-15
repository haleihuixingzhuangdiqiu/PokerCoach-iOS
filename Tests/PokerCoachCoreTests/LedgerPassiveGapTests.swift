import XCTest
@testable import PokerCoachCore

final class LedgerPassiveGapTests: XCTestCase {
    private func start(stacks: [Int] = Array(repeating: 5_000, count: 8)) throws -> TableState {
        try rules.startHand(seats: stacks.enumerated().map { Seat(id: $0.offset, stack: $0.element) },
                            button: 7, optionalStraddle: true).state
    }
    private var rules: PokerGameRules {
        get throws { try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .optional(amount: 100)) }
    }
    private func snapshot(_ s: TableState, omitActor: Bool = false,
                          mutate: ((inout [PublicSeatSnapshot]) -> Void)? = nil,
                          pot: Int? = nil) throws -> PublicTableSnapshot {
        var seats = s.seats.map { PublicSeatSnapshot(id: $0.id, stack: $0.stack,
                                                    streetWager: $0.streetCommitted, folded: $0.folded) }
        mutate?(&seats)
        return .init(seats: seats, hero: 2, cards: try HoleCards("QcQs"), board: s.board,
                     pot: pot ?? s.pot, button: 7, actor: omitActor ? nil : s.actor,
                     rules: try rules, optionalStraddle: true, straddleSeat: 2)
    }
    private func confirm(_ s: PublicTableSnapshot, _ ledger: inout PublicHandLedger, at t: Double) {
        ledger.ingest(s, timestamp: t, now: t)
        ledger.ingest(s, timestamp: t + 0.05, now: t + 0.05)
    }
    private func seeded(_ state: TableState, maxStates: Int = 512, maxActions: Int = 32) throws -> PublicHandLedger {
        var ledger = PublicHandLedger(maxStates: maxStates, maxActions: maxActions)
        confirm(try snapshot(state), &ledger, at: 1)
        XCTAssertEqual(ledger.current(now: 1.05)?.state, state)
        return ledger
    }

    func testSevenUnseenLimpsPreserveUnactedStraddleOption() throws {
        let original = try start(); var ledger = try seeded(original)
        var target = original
        for _ in 0..<7 { target = try target.applying(.call) }
        confirm(try snapshot(target), &ledger, at: 1.2)
        let hand = try XCTUnwrap(ledger.current(now: 1.25))
        XCTAssertEqual(hand.state, target)
        XCTAssertEqual(hand.state.pot, 800)
        XCTAssertEqual(hand.state.pending, [2])
        XCTAssertEqual(hand.state.amountToCall(2), 0)
        XCTAssertNil(hand.state.seats[2].actedAtBet)
        XCTAssertTrue(hand.state.mayRaise(2))
        XCTAssertEqual(hand.state.minimumRaiseTo, 200)
        XCTAssertEqual(hand.actions.map(\.seatID), [3, 4, 5, 6, 7, 0, 1])
        XCTAssertEqual(hand.actions.map(\.action), Array(repeating: .call, count: 7))
        XCTAssertTrue(hand.actionSequenceUnique)
    }

    func testCallsAndFoldsAfterRecordedRaisePreserveExactContributions() throws {
        let original = try start(); var ledger = try seeded(original)
        let raised = try original.applying(.raiseTo(280))
        confirm(try snapshot(raised), &ledger, at: 1.2)
        let target = try raised.applying(.call).applying(.fold).applying(.call)
        confirm(try snapshot(target), &ledger, at: 1.4)
        let hand = try XCTUnwrap(ledger.current(now: 1.45))
        XCTAssertEqual(hand.state, target)
        XCTAssertEqual(hand.state.pot, 1_010)
        XCTAssertEqual(hand.state.currentBet, 280)
        XCTAssertEqual(hand.state.lastFullRaise, 180)
        XCTAssertEqual(hand.state.pending, [7, 0, 1, 2])
        XCTAssertEqual(hand.actions.map(\.action), [.raiseTo(280), .call, .fold, .call])
        XCTAssertFalse(hand.state.mayRaise(3), "The already-acted opener has not faced a new full raise")
    }

    func testShortCappedCallRemainsActualContributionAndDoesNotRaise() throws {
        var stacks = Array(repeating: 5_000, count: 8); stacks[4] = 150
        let original = try start(stacks: stacks); var ledger = try seeded(original)
        let raised = try original.applying(.raiseTo(300))
        confirm(try snapshot(raised), &ledger, at: 1.2)
        let target = try raised.applying(.call).applying(.call).applying(.fold)
        confirm(try snapshot(target), &ledger, at: 1.4)
        let hand = try XCTUnwrap(ledger.current(now: 1.45))
        XCTAssertEqual(hand.state, target)
        XCTAssertEqual(hand.state.seats[4].committed, 150)
        XCTAssertEqual(hand.state.seats[4].stack, 0)
        XCTAssertEqual(hand.state.seats[5].committed, 300)
        XCTAssertEqual(hand.state.pot, 920)
        XCTAssertEqual(hand.state.lastFullRaise, 200)
        XCTAssertEqual(hand.state.minimumRaiseTo, 500)
        XCTAssertFalse(hand.state.pending.contains(4))
        let pots = try PotSettlement.layers(seats: hand.state.seats)
        XCTAssertEqual(pots.reduce(0) { $0 + $1.amount }, 920)
        XCTAssertEqual(pots.filter { $0.eligible.contains(4) }.reduce(0) { $0 + $1.amount }, 620)
        XCTAssertEqual(pots.last?.amount, 300)
        XCTAssertEqual(pots.last?.eligible, [3, 5])
    }

    func testPassiveGapCannotReopenAfterAlreadyRecordedShortRaise() throws {
        var stacks = Array(repeating: 5_000, count: 8); stacks[4] = 250
        let original = try start(stacks: stacks); var ledger = try seeded(original)
        let opened = try original.applying(.raiseTo(200))
        confirm(try snapshot(opened), &ledger, at: 1.2)
        var target = try opened.applying(.raiseTo(250))
        confirm(try snapshot(target), &ledger, at: 1.4)
        for action in [PokerAction.call, .fold, .call, .fold, .fold, .fold] {
            target = try target.applying(action)
        }
        confirm(try snapshot(target), &ledger, at: 1.6)
        let hand = try XCTUnwrap(ledger.current(now: 1.66), ledger.status)
        XCTAssertEqual(hand.state, target)
        XCTAssertEqual(hand.state.actor, 3)
        XCTAssertEqual(hand.state.lastFullRaise, 100)
        XCTAssertEqual(hand.state.seats[3].actedAtBet, 200)
        XCTAssertEqual(hand.state.amountToCall(3), 50)
        XCTAssertFalse(hand.state.mayRaise(3))
        XCTAssertEqual(hand.state.legalActions(), [.fold, .call])
    }

    func testOneFreshPassiveGapFrameDoesNotPublishAndUnknownActorCannotRefresh() throws {
        let original = try start(); var ledger = try seeded(original)
        let target = try original.applying(.call).applying(.call)
        ledger.ingest(try snapshot(target), timestamp: 1.2, now: 1.2)
        XCTAssertNil(ledger.current(now: 1.2))
        XCTAssertEqual(ledger.hand?.state, original)
        confirm(try snapshot(target, omitActor: true), &ledger, at: 1.3)
        XCTAssertNil(ledger.current(now: 1.35))
        XCTAssertEqual(ledger.hand?.state, target)
        confirm(try snapshot(target), &ledger, at: 1.5)
        XCTAssertEqual(ledger.current(now: 1.55)?.state, target)
    }

    func testTwoPayersContainingAnyNewRaiseRemainRejected() throws {
        let original = try start(); var ledger = try seeded(original)
        let target = try original.applying(.raiseTo(280)).applying(.call)
        confirm(try snapshot(target), &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.25))
        XCTAssertEqual(ledger.hand?.state, original)
        XCTAssertTrue(ledger.status.contains("中间加注记录"))
    }

    func testNonconservedPotOrPerSeatWagerNeverPassPassiveException() throws {
        let original = try start()
        let target = try original.applying(.call).applying(.call)
        let invalid = [
            try snapshot(target, pot: target.pot + 1),
            try snapshot(target, mutate: { $0[3].streetWager = 99 }),
            try snapshot(target, mutate: { $0[3].stack! -= 1 }),
            try snapshot(target, mutate: { $0[3].streetWager = nil }),
            try snapshot(target, mutate: { $0[3].folded = nil })
        ]
        for observation in invalid {
            var ledger = try seeded(original)
            confirm(observation, &ledger, at: 1.2)
            XCTAssertNil(ledger.current(now: 1.25))
            XCTAssertEqual(ledger.hand?.state, original)
        }
    }

    func testPassiveChipEndpointsDoNotOverrideActionOrder() throws {
        let original = try start(); var ledger = try seeded(original)
        let target = try original.applying(.call).applying(.call)
        let wrong = try snapshot(target, mutate: { seats in
            // Same total pot, but seat 5 cannot call before untouched seat 4.
            seats[5].stack = seats[4].stack; seats[5].streetWager = seats[4].streetWager
            seats[4].stack = original.seats[4].stack; seats[4].streetWager = 0
        })
        confirm(wrong, &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.25))
        XCTAssertEqual(ledger.hand?.state, original)
    }

    func testMultiplePayersAcrossStreetRemainRejected() throws {
        let original = try start(); var ledger = try seeded(original)
        var target = original
        for _ in 0..<7 { target = try target.applying(.call) }
        target = try target.applying(.check).advancing(to: Card.parse("2c7d9h"))
        confirm(try snapshot(target), &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.25))
        XCTAssertEqual(ledger.hand?.state, original)
        XCTAssertTrue(ledger.status.contains("中间加注记录"))
    }

    func testRefundProneAllInEndpointDoesNotProveOnlyPassiveActions() throws {
        let original = try start(stacks: [100, 100, 100, 1_000, 1_000, 1_000, 1_000, 1_000])
        var ledger = try seeded(original)
        var target = try original.applying(.call)
        for _ in 0..<4 { target = try target.applying(.fold) }
        target = try target.applying(.call).applying(.call)
        XCTAssertEqual(target.pot, 400)
        XCTAssertEqual(target.live.filter { target.seats[$0].stack > 0 }, [3])
        // A raise to 200 followed by these folds/capped calls returns 100 of the
        // raiser's chips. The resulting net contributions alone do not establish
        // the passive history; retain the conservative rejection at this boundary.
        confirm(try snapshot(target), &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.25))
        XCTAssertEqual(ledger.hand?.state, original)
        XCTAssertTrue(ledger.status.contains("中间加注记录"))
    }

    func testPassiveRecoveryCannotCertifySearchBudgetTruncation() throws {
        let original = try start()
        var target = original
        for _ in 0..<7 { target = try target.applying(.call) }
        for limits in [(512, 2), (2, 32)] {
            var ledger = try seeded(original, maxStates: limits.0, maxActions: limits.1)
            confirm(try snapshot(target), &ledger, at: 1.2)
            XCTAssertNil(ledger.current(now: 1.25))
            XCTAssertEqual(ledger.hand?.state, original)
        }
    }
}
