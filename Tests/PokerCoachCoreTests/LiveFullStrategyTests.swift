import XCTest
@testable import PokerCoachCore

final class LiveFullStrategyTests: XCTestCase {
    private func opening(raiseTo: Int = 280) throws -> (PokerGameRules, TableState, PublicTableSnapshot) {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .optional(amount: 100))
        let start = try rules.startHand(seats: (0..<8).map { Seat(id: 100 + $0, stack: 5_000) },
                                       button: 7, optionalStraddle: true).state
        let raised = try start.applying(.raiseTo(raiseTo))
        return (rules, start, try snapshot(raised, rules: rules, hero: 4, straddler: 2))
    }

    private func snapshot(_ state: TableState, rules: PokerGameRules, hero: Int, straddler: Int?) throws -> PublicTableSnapshot {
        .init(seats: state.seats.map { .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded) },
              hero: hero, cards: try HoleCards("QcQh"), board: state.board, pot: state.pot,
              button: state.button, actor: state.actor, rules: rules, optionalStraddle: straddler != nil, straddleSeat: straddler)
    }

    private func changed(_ input: PublicTableSnapshot, seats: [PublicSeatSnapshot]? = nil,
                         cards: HoleCards? = nil, board: [Card]? = nil, pot: Int? = nil) -> PublicTableSnapshot {
        .init(seats: seats ?? input.seats, hero: input.hero, cards: cards ?? input.cards,
              board: board ?? input.board, pot: pot ?? input.pot, button: input.button, actor: input.actor,
              rules: input.rules, optionalStraddle: input.optionalStraddle, straddleSeat: input.straddleSeat)
    }

    private func confirm(_ input: PublicTableSnapshot, in gate: inout OpeningSnapshotGate, at timestamp: Double = 10) {
        gate.ingest(input, timestamp: timestamp, now: timestamp)
        gate.ingest(input, timestamp: timestamp + 0.1, now: timestamp + 0.1)
    }

    private func controls(call: Int = 280, committed: Int = 0, raises: [Int] = []) -> VisiblePassiveActions {
        .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: call,
              heroStreetCommitted: committed, visibleRaiseToAmounts: raises)
    }

    private func confirmedLedger() throws -> (PublicHandLedger, PublicTableSnapshot) {
        let (rules, initial, input) = try opening()
        let blinds = try snapshot(initial, rules: rules, hero: 4, straddler: 2)
        var ledger = PublicHandLedger()
        ledger.ingest(blinds, timestamp: 10, now: 10)
        ledger.ingest(blinds, timestamp: 10.1, now: 10.1)
        ledger.ingest(input, timestamp: 10.2, now: 10.2)
        ledger.ingest(input, timestamp: 10.3, now: 10.3)
        return (ledger, input)
    }

    func testTwoDistinctFreshFramesAreRequiredAndDuplicateFrameDoesNotCount() throws {
        let (_, _, input) = try opening()
        var gate = OpeningSnapshotGate()
        gate.ingest(input, timestamp: 10, now: 10)
        XCTAssertNil(gate.current(now: 10))
        XCTAssertEqual(gate.lastVerifiedAt, 0)
        gate.ingest(input, timestamp: 10, now: 10.05)
        XCTAssertNil(gate.current(now: 10.05), "A repeated callback is not a second captured frame")
        gate.ingest(input, timestamp: 10.1, now: 10.1)
        let current = try XCTUnwrap(gate.current(now: 10.1))
        XCTAssertEqual(current.state.amountToCall(current.hero), 280)
        XCTAssertEqual(current.state.pending, [4, 5, 6, 7, 0, 1, 2])
        XCTAssertFalse(current.historyComplete)
        XCTAssertEqual(gate.lastVerifiedAt, 10.1)
    }

    func testOneUnknownChangedCardBoardOrAmountWithdrawsImmediatelyAndRequiresReconfirmation() throws {
        let (_, _, input) = try opening()
        var missingStack = input.seats; missingStack[0].stack = nil
        var missingWager = input.seats; missingWager[1].streetWager = nil
        var missingFold = input.seats; missingFold[2].folded = nil
        var conflictingWager = input.seats; conflictingWager[3].streetWager = 281
        let alternatives: [(String, PublicTableSnapshot)] = [
            ("unknown stack", changed(input, seats: missingStack)),
            ("unknown wager", changed(input, seats: missingWager)),
            ("unknown fold", changed(input, seats: missingFold)),
            ("inconsistent pot", changed(input, pot: 449)),
            ("inconsistent wager", changed(input, seats: conflictingWager)),
            ("new hole cards", changed(input, cards: try HoleCards("AsKd"))),
            ("new street", changed(input, board: try Card.parse("2c7d9h"))),
            ("different valid opening amount", try opening(raiseTo: 300).2)
        ]
        for (label, replacement) in alternatives {
            var gate = OpeningSnapshotGate()
            confirm(input, in: &gate)
            XCTAssertNotNil(gate.current(now: 10.1), label)
            gate.ingest(replacement, timestamp: 10.2, now: 10.2)
            XCTAssertNil(gate.current(now: 10.2), label)
            XCTAssertEqual(gate.lastVerifiedAt, 0, label)
            gate.ingest(input, timestamp: 10.3, now: 10.3)
            XCTAssertNil(gate.current(now: 10.3), label + ": one recovered frame is insufficient")
            gate.ingest(input, timestamp: 10.4, now: 10.4)
            XCTAssertEqual(gate.current(now: 10.4)?.cards, input.cards, label)
        }
    }

    func testLateProcessingUsesCaptureTimeAndDoesNotRenewOldAdvice() throws {
        let (_, _, input) = try opening()
        var gate = OpeningSnapshotGate(freshness: 0.8)
        gate.ingest(input, timestamp: 10, now: 10.79)
        gate.ingest(input, timestamp: 10.1, now: 10.89)
        XCTAssertNotNil(gate.current(now: 10.89))
        XCTAssertEqual(gate.lastVerifiedAt, 10.1)
        XCTAssertNil(gate.current(now: 10.901), "Finishing at 10.89 cannot extend a frame captured at 10.1")
        XCTAssertNil(gate.current(now: .nan))
        XCTAssertNil(gate.current(now: .infinity))
        XCTAssertNil(gate.current(now: 10.09), "A clock before capture does not make the result fresh")
    }

    func testOutOfOrderFutureAndExpiredFramesNeverExtendValidityOrPoisonNextFreshPair() throws {
        let (_, _, input) = try opening()
        var gate = OpeningSnapshotGate()
        confirm(input, in: &gate)
        for (timestamp, now) in [(10.1, 10.5), (10.0, 10.5), (100.0, 10.5), (Double.nan, 10.5), (10.3, Double.nan)] {
            gate.ingest(input, timestamp: timestamp, now: now)
            XCTAssertEqual(gate.lastVerifiedAt, 10.1)
        }
        XCTAssertNil(gate.current(now: 10.901))
        gate.ingest(input, timestamp: 11, now: 12)
        XCTAssertEqual(gate.lastVerifiedAt, 10.1, "An expired frame must not refresh confirmation")
        gate.ingest(input, timestamp: 12.1, now: 12.1)
        XCTAssertNil(gate.current(now: 12.1), "A capture gap requires a fresh pair")
        gate.ingest(input, timestamp: 12.2, now: 12.2)
        XCTAssertNotNil(gate.current(now: 12.2), "A rejected future timestamp must not poison later valid captures")
        XCTAssertEqual(gate.lastVerifiedAt, 12.2)
    }

    func testResetDropsBothVerifiedStateAndTheFirstUnconfirmedFrame() throws {
        let (_, _, input) = try opening()
        var gate = OpeningSnapshotGate()
        confirm(input, in: &gate)
        gate.reset()
        XCTAssertNil(gate.current(now: 10.2))
        XCTAssertEqual(gate.lastVerifiedAt, 0)
        gate.ingest(input, timestamp: 11, now: 11)
        XCTAssertNil(gate.current(now: 11))
        gate.reset()
        gate.ingest(input, timestamp: 11.1, now: 11.1)
        XCTAssertNil(gate.current(now: 11.1))
        gate.ingest(input, timestamp: 11.2, now: 11.2)
        XCTAssertNotNil(gate.current(now: 11.2))
    }

    func testNewUnreadableOpeningWithdrawsAndRestartsTwoFrameConfirmation() throws {
        let (_, _, input) = try opening()
        var gate = OpeningSnapshotGate()
        confirm(input, in: &gate)
        let verified = try XCTUnwrap(gate.current(now: 10.1))

        gate.ingestUnreadable(timestamp: 10.2, now: 10.2)
        XCTAssertNil(gate.current(now: 10.2))
        XCTAssertEqual(gate.lastVerifiedAt, 0)
        gate.ingest(input, timestamp: 10.3, now: 10.3)
        XCTAssertNil(gate.current(now: 10.3), "One recovered frame cannot restore the previous advice")
        gate.ingestUnreadable(timestamp: 10.4, now: 10.4)
        gate.ingest(input, timestamp: 10.5, now: 10.5)
        gate.ingest(input, timestamp: 10.5, now: 10.55)
        XCTAssertNil(gate.current(now: 10.55), "Another unreadable frame resets confirmation; a duplicate callback does not count")
        gate.ingest(input, timestamp: 10.6, now: 10.6)
        XCTAssertEqual(gate.current(now: 10.6), verified)
        XCTAssertEqual(gate.lastVerifiedAt, 10.6)
    }

    func testNewUnreadableLedgerRetainsHistoryButRequiresTwoRecoveredFrames() throws {
        var (ledger, input) = try confirmedLedger()
        let verified = try XCTUnwrap(ledger.current(now: 10.3))
        let generation = ledger.generation
        XCTAssertEqual(verified.actions.count, 1, "This fixture includes an observed raise, not just forced bets")

        ledger.ingestUnreadable(timestamp: 10.4, now: 10.4)
        XCTAssertNil(ledger.current(now: 10.4))
        XCTAssertEqual(ledger.lastVerifiedAt, 0)
        XCTAssertEqual(ledger.hand, verified, "An unreadable image withdraws advice without deleting observed action history")
        XCTAssertEqual(ledger.generation, generation)
        ledger.ingest(input, timestamp: 10.5, now: 10.5)
        ledger.ingest(input, timestamp: 10.5, now: 10.55)
        XCTAssertNil(ledger.current(now: 10.55), "Two callbacks from one captured image are insufficient")
        XCTAssertEqual(ledger.hand, verified)
        ledger.ingest(input, timestamp: 10.6, now: 10.6)
        let recovered = try XCTUnwrap(ledger.current(now: 10.6))
        XCTAssertEqual(recovered, verified, "Reconfirmation must retain the hand ID and avoid appending the same raise again")
        XCTAssertEqual(recovered.actions, verified.actions)
        XCTAssertEqual(ledger.generation, generation)
        XCTAssertEqual(ledger.lastVerifiedAt, 10.6)
    }

    func testDuplicateLateFutureAndNonFiniteUnreadableCallbacksDoNotWithdrawNewerState() throws {
        var (ledger, input) = try confirmedLedger()
        let hand = try XCTUnwrap(ledger.current(now: 10.3))
        var gate = OpeningSnapshotGate()
        gate.ingest(input, timestamp: 10.2, now: 10.2)
        gate.ingest(input, timestamp: 10.3, now: 10.3)
        let opening = try XCTUnwrap(gate.current(now: 10.3))
        let ledgerStatus = ledger.status, openingStatus = gate.status
        let generation = ledger.generation
        let rejected: [(String, Double, Double)] = [
            ("duplicate", 10.3, 10.4), ("late", 10.2, 10.4), ("future", 20, 10.4),
            ("NaN capture", .nan, 10.4), ("infinite capture", .infinity, 10.4),
            ("NaN completion", 10.4, .nan), ("infinite completion", 10.4, .infinity)
        ]
        for (label, timestamp, now) in rejected {
            ledger.ingestUnreadable(timestamp: timestamp, now: now)
            gate.ingestUnreadable(timestamp: timestamp, now: now)
            XCTAssertEqual(ledger.current(now: 10.4), hand, label)
            XCTAssertEqual(gate.current(now: 10.4), opening, label)
            XCTAssertEqual(ledger.lastVerifiedAt, 10.3, label)
            XCTAssertEqual(gate.lastVerifiedAt, 10.3, accuracy: 0.000_001, label)
            XCTAssertEqual(ledger.status, ledgerStatus, label)
            XCTAssertEqual(gate.status, openingStatus, label)
            XCTAssertEqual(ledger.generation, generation, label)
        }
        // In particular, a rejected far-future callback must not move the input watermark.
        ledger.ingestUnreadable(timestamp: 10.5, now: 10.5)
        gate.ingestUnreadable(timestamp: 10.5, now: 10.5)
        XCTAssertNil(ledger.current(now: 10.5))
        XCTAssertNil(gate.current(now: 10.5))
        ledger.ingest(input, timestamp: 10.6, now: 10.6)
        gate.ingest(input, timestamp: 10.6, now: 10.6)
        XCTAssertNil(ledger.current(now: 10.6))
        XCTAssertNil(gate.current(now: 10.6))
        ledger.ingest(input, timestamp: 10.7, now: 10.7)
        gate.ingest(input, timestamp: 10.7, now: 10.7)
        XCTAssertEqual(ledger.current(now: 10.7), hand)
        XCTAssertEqual(gate.current(now: 10.7), opening)
    }

    func testExpiredUnreadableFrameDoesNotMutateHistoryOrWithdrawLaterFreshState() throws {
        var (ledger, input) = try confirmedLedger()
        let hand = try XCTUnwrap(ledger.current(now: 10.3))
        var gate = OpeningSnapshotGate()
        gate.ingest(input, timestamp: 10.2, now: 10.2)
        gate.ingest(input, timestamp: 10.3, now: 10.3)
        let opening = try XCTUnwrap(gate.current(now: 10.3))
        let ledgerStatus = ledger.status, openingStatus = gate.status
        let generation = ledger.generation

        // The failed capture is newer than the accepted state, but was delivered too late.
        ledger.ingestUnreadable(timestamp: 10.4, now: 11.3)
        gate.ingestUnreadable(timestamp: 10.4, now: 11.3)
        XCTAssertEqual(ledger.lastVerifiedAt, 10.3)
        XCTAssertEqual(gate.lastVerifiedAt, 10.3, accuracy: 0.000_001)
        XCTAssertEqual(ledger.hand, hand)
        XCTAssertEqual(ledger.generation, generation)
        XCTAssertEqual(ledger.status, ledgerStatus)
        XCTAssertEqual(gate.status, openingStatus)
        XCTAssertNil(ledger.current(now: 11.3), "Old advice expires naturally; rejection must not extend its lifetime")
        XCTAssertNil(gate.current(now: 11.3))

        ledger.ingest(input, timestamp: 12, now: 12)
        gate.ingest(input, timestamp: 12, now: 12)
        XCTAssertNil(ledger.current(now: 12), "A long capture gap still requires two fresh frames")
        XCTAssertNil(gate.current(now: 12))
        ledger.ingest(input, timestamp: 12.1, now: 12.1)
        gate.ingest(input, timestamp: 12.1, now: 12.1)
        ledger.ingestUnreadable(timestamp: 10.4, now: 12.2)
        gate.ingestUnreadable(timestamp: 10.4, now: 12.2)
        XCTAssertEqual(ledger.current(now: 12.2), hand)
        XCTAssertEqual(gate.current(now: 12.2), opening)
        XCTAssertEqual(ledger.lastVerifiedAt, 12.1)
        XCTAssertEqual(gate.lastVerifiedAt, 12.1)
    }

    func testOpeningRequestKeepsOnlyObservedLegalRaiseTotals() throws {
        let recovered = try OpeningSnapshotReconstructor.reconstruct(opening().2)
        let request = try FullStrategyRequest(opening: recovered,
            controls: controls(raises: [450, 460, 700, 5_000, 5_001, 280, 460]), observedPot: 450)
        XCTAssertEqual(request.allowedActions, [.fold, .call, .raiseTo(460), .raiseTo(700), .raiseTo(5_000)])
        XCTAssertEqual(request.hero, 4)
        XCTAssertEqual(request.cards, try HoleCards("QcQh"))
        XCTAssertEqual(request.state, recovered.state)
        let withoutRaises = try FullStrategyRequest(opening: recovered, controls: controls(), observedPot: 450)
        XCTAssertEqual(withoutRaises.allowedActions, [.fold, .call], "Do not generate an unobserved theoretical minimum raise")
        let noFoldButton = try FullStrategyRequest(opening: recovered,
            controls: .init(heroTurnConfirmed: true, callAmount: 280, heroStreetCommitted: 0), observedPot: 450)
        XCTAssertEqual(noFoldButton.allowedActions, [.call])
    }

    func testOpeningRequestRejectsConflictingActualControlsAndUnknownPot() throws {
        let recovered = try OpeningSnapshotReconstructor.reconstruct(opening().2)
        let invalid: [VisiblePassiveActions] = [
            .init(heroTurnConfirmed: false, foldAvailable: true, callAmount: 280, heroStreetCommitted: 0),
            controls(call: 279), controls(call: 281), controls(committed: 20),
            .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 280),
            .init(heroTurnConfirmed: true, foldAvailable: true, heroStreetCommitted: 0),
            .init(heroTurnConfirmed: true, foldAvailable: true, checkAvailable: true, callAmount: 280, heroStreetCommitted: 0),
            .init(heroTurnConfirmed: true, checkAvailable: true, heroStreetCommitted: 0),
            .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 280, visibleBetAmounts: [700], heroStreetCommitted: 0),
            controls(raises: [0]), controls(raises: [-1]), controls(raises: [Int.max])
        ]
        for control in invalid {
            XCTAssertThrowsError(try FullStrategyRequest(opening: recovered, controls: control, observedPot: 450))
        }
        XCTAssertThrowsError(try FullStrategyRequest(opening: recovered, controls: controls(), observedPot: nil))
        XCTAssertThrowsError(try FullStrategyRequest(opening: recovered, controls: controls(), observedPot: 449))
    }

    func testBlindContributionUsesRaiseToTotalAndCorrectCallIncrement() throws {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50)
        let start = try rules.startHand(seats: (0..<3).map { Seat(id: $0, stack: 5_000) }, button: 0).state
        let current = try start.applying(.fold).applying(.raiseTo(150))
        let recovered = try OpeningSnapshotReconstructor.reconstruct(snapshot(current, rules: rules, hero: 2, straddler: nil))
        XCTAssertEqual(recovered.state.seats[2].streetCommitted, 50)
        XCTAssertEqual(recovered.state.amountToCall(2), 100)
        let request = try FullStrategyRequest(opening: recovered,
            controls: controls(call: 100, committed: 50, raises: [200, 250]), observedPot: 200)
        XCTAssertEqual(request.allowedActions, [.fold, .call, .raiseTo(250)])
        XCTAssertEqual(try request.state.applying(.raiseTo(250)).seats[2].stack, 4_750)
        XCTAssertThrowsError(try FullStrategyRequest(opening: recovered,
            controls: controls(call: 150, committed: 50), observedPot: 200))
    }

    func testReconstructedAndObservedEquivalentStatesKeepDifferentProvenance() throws {
        let (rules, initial, input) = try opening()
        let recovered = try OpeningSnapshotReconstructor.reconstruct(input)
        let openingRequest = try FullStrategyRequest(opening: recovered, controls: controls(), observedPot: 450)
        var ledger = PublicHandLedger()
        let blindSnapshot = try snapshot(initial, rules: rules, hero: 4, straddler: 2)
        ledger.ingest(blindSnapshot, timestamp: 10, now: 10)
        ledger.ingest(blindSnapshot, timestamp: 10.1, now: 10.1)
        ledger.ingest(input, timestamp: 10.2, now: 10.2)
        ledger.ingest(input, timestamp: 10.3, now: 10.3)
        let observed = try XCTUnwrap(ledger.current(now: 10.3))
        let continuous = FullStrategyRequest.continuous(try FullHandDecisionRequest(hand: observed, controls: controls(), observedPot: 450))
        XCTAssertEqual(openingRequest.state, continuous.state)
        XCTAssertEqual(openingRequest.allowedActions, continuous.allowedActions)
        XCTAssertEqual(openingRequest.sourceID, "singleOpenSnapshot")
        XCTAssertEqual(openingRequest.sourceLabel, "单次开池重建")
        XCTAssertEqual(continuous.sourceID, "continuousHand")
        XCTAssertEqual(continuous.sourceLabel, "连续记录")
        XCTAssertNotEqual(openingRequest, continuous)
        guard case .opening(let sameRecovery, _) = openingRequest else { return XCTFail("A reconstructed opening must not masquerade as continuous history") }
        XCTAssertFalse(sameRecovery.historyComplete)
        XCTAssertEqual(sameRecovery.source, .singleOpenSnapshot)
    }
}
