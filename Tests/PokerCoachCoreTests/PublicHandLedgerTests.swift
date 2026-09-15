import XCTest
@testable import PokerCoachCore

final class PublicHandLedgerTests: XCTestCase {
    private let order = [0, 1, 2, 3, 7, 4, 5, 6]
    private func initial() throws -> TableState {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .optional(amount: 100))
        return try rules.startHand(seats: order.map { Seat(id: $0, stack: 5_000) }, button: 3, optionalStraddle: true).state
    }
    private func snapshot(_ state: TableState, hero: Int = 4, actor: Int? = nil,
                          cards: String = "AcJc", rules: Bool = true) throws -> PublicTableSnapshot {
        .init(seats: state.seats.map { .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded) },
              hero: hero, cards: try HoleCards(cards), board: state.board, pot: state.pot,
              button: state.button, actor: actor ?? state.actor,
              rules: rules ? try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .optional(amount: 100)) : nil,
              optionalStraddle: rules ? true : nil, straddleSeat: rules ? 6 : nil)
    }
    private func confirm(_ snapshot: PublicTableSnapshot, _ ledger: inout PublicHandLedger, at: Double) {
        ledger.ingest(snapshot, timestamp: at, now: at)
        ledger.ingest(snapshot, timestamp: at + 0.1, now: at + 0.1)
    }
    func testReal0018ClockwiseMappingAndThirdBlindOption() throws {
        var state = try initial()
        for _ in 0..<5 { state = try state.applying(.fold) }
        var ledger = PublicHandLedger()
        confirm(try snapshot(state), &ledger, at: 1)
        let hand = try XCTUnwrap(ledger.current(now: 1.1))
        XCTAssertEqual(hand.state.actor, 4)
        XCTAssertEqual(hand.state.seats[4].id, 7)
        XCTAssertEqual(hand.state.amountToCall(4), 80)
        XCTAssertEqual(hand.state.pot, 170)
        XCTAssertEqual(hand.state.bigBlind, 50)
        XCTAssertEqual(hand.state.minimumBet, 100)
        XCTAssertEqual(hand.actions.map(\.seatID), [6, 0, 1, 2, 3])
        XCTAssertNil(hand.state.seats[6].actedAtBet)
        XCTAssertEqual(hand.state.pending, [4, 5, 6])
    }
    func testMissingFieldsDoNotBecomeZeroAndCannotBootstrapLate() throws {
        var ledger = PublicHandLedger()
        let state = try initial(), s = try snapshot(state)
        var seats = s.seats; seats[0].streetWager = nil
        let missing = PublicTableSnapshot(seats: seats, hero: 4, cards: s.cards, board: [], pot: 170,
            button: 3, actor: 7, rules: s.rules, optionalStraddle: true, straddleSeat: 6)
        confirm(missing, &ledger, at: 1)
        XCTAssertNil(ledger.current(now: 1.1))
        let late = try state.applying(.raiseTo(300))
        confirm(try snapshot(late), &ledger, at: 2)
        XCTAssertNil(ledger.hand)
    }
    func testSingleFreshSnapshotAndDuplicateDoNotConfirm() throws {
        var ledger = PublicHandLedger(); let s = try snapshot(initial())
        ledger.ingest(s, timestamp: 1, now: 1)
        ledger.ingest(s, timestamp: 1, now: 1.1)
        XCTAssertNil(ledger.hand)
        ledger.ingest(s, timestamp: 1.2, now: 1.2)
        XCTAssertNotNil(ledger.current(now: 1.2))
        XCTAssertNil(ledger.current(now: 2.1))
        XCTAssertNil(ledger.current(now: .nan))
    }
    func testContinuousRaiseFoldCallAndPostflopPreserveContributions() throws {
        var ledger = PublicHandLedger(); var state = try initial()
        confirm(try snapshot(state), &ledger, at: 1)
        state = try state.applying(.raiseTo(300))
        confirm(try snapshot(state), &ledger, at: 1.2)
        XCTAssertEqual(ledger.hand?.state.lastFullRaise, 200)
        // Five intervening visible folds move the action to the big blind.
        for _ in 0..<5 { state = try state.applying(.fold) }
        confirm(try snapshot(state), &ledger, at: 1.4)
        state = try state.applying(.fold)
        confirm(try snapshot(state), &ledger, at: 1.6)
        state = try state.applying(.call)
        confirm(try snapshot(state), &ledger, at: 1.8)
        XCTAssertTrue(try XCTUnwrap(ledger.hand).state.roundComplete)
        let pot = state.pot
        state = try state.advancing(to: Card.parse("2c7d9h"))
        confirm(try snapshot(state), &ledger, at: 2)
        let hand = try XCTUnwrap(ledger.current(now: 2.1))
        XCTAssertEqual(hand.state, state)
        XCTAssertEqual(hand.state.pot, pot)
        XCTAssertEqual(hand.state.minimumBet, 50)
        XCTAssertTrue(hand.actionSequenceUnique)
    }
    func testMultipleUnseenPayersNeverInventReopeningRights() throws {
        var ledger = PublicHandLedger(); let state = try initial()
        confirm(try snapshot(state), &ledger, at: 1)
        let skipped = try state.applying(.raiseTo(300)).applying(.call)
        confirm(try snapshot(skipped), &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.3))
        XCTAssertEqual(ledger.hand?.state, state)
        XCTAssertTrue(ledger.status.contains("中间加注记录"))
    }
    func testExplicitHandBoundaryStartsNewLedgerButCardErrorCannotFakeOne() throws {
        var ledger = PublicHandLedger(); let state = try initial()
        confirm(try snapshot(state), &ledger, at: 1)
        let firstID = try XCTUnwrap(ledger.hand?.id)
        let progressed = try state.applying(.raiseTo(300))
        confirm(try snapshot(progressed, cards: "KhKd"), &ledger, at: 1.2)
        XCTAssertNil(ledger.current(now: 1.3))
        XCTAssertEqual(ledger.hand?.id, firstID)
        confirm(try snapshot(state, cards: "KhKd"), &ledger, at: 1.4)
        XCTAssertEqual(ledger.hand?.id, firstID + 1)
    }
    func testUnknownFoldPersistsOnlyWithinSameVerifiedHand() throws {
        var ledger = PublicHandLedger(); var state = try initial()
        for _ in 0..<5 { state = try state.applying(.fold) }
        confirm(try snapshot(state), &ledger, at: 1)
        let s = try snapshot(state, rules: false)
        var seats = s.seats; seats[0].folded = nil; seats[6].streetWager = nil
        let partial = PublicTableSnapshot(seats: seats, hero: 4, cards: s.cards, board: [],
            pot: s.pot, button: nil, actor: 4)
        confirm(partial, &ledger, at: 1.2)
        XCTAssertNotNil(ledger.current(now: 1.3))
        ledger.reset()
        confirm(partial, &ledger, at: 2)
        XCTAssertNil(ledger.current(now: 2.1))
    }
}
