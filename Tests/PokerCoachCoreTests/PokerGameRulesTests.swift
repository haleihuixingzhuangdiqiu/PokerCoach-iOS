import XCTest
@testable import PokerCoachCore

final class PokerGameRulesTests: XCTestCase {
    private func players(_ count: Int, stack: Int = 5_000) -> [Seat] {
        (0..<count).map { Seat(id: 100 + $0, stack: stack) }
    }
    private func rules(_ policy: UTGStraddlePolicy = .disabled, ante: Int = 0) throws -> PokerGameRules {
        try PokerGameRules(smallBlind: 20, bigBlind: 50, ante: ante, utgStraddle: policy)
    }

    func testOrdinaryTwoThroughNinePlayerPositionsAndBlindOption() throws {
        for count in 2...9 {
            for button in 0..<count {
                let start = try rules().startHand(seats: players(count), button: button)
                let sb = count == 2 ? button : (button + 1) % count
                let bb = (sb + 1) % count
                XCTAssertEqual(start.positions.smallBlind, sb)
                XCTAssertEqual(start.positions.bigBlind, bb)
                XCTAssertEqual(start.state.actor, (bb + 1) % count)
                XCTAssertEqual(start.positions.postflopOrder.first, (button + 1) % count)
                XCTAssertNil(start.positions.straddle)
                XCTAssertEqual(start.state.pot, 70)
                var state = start.state
                for _ in 0..<(count - 1) { state = try state.applying(.call) }
                XCTAssertEqual(state.actor, bb)
                XCTAssertEqual(state.amountToCall(bb), 0)
                XCTAssertTrue(state.mayRaise(bb), "Blind posting must not consume the option")
                XCTAssertFalse(state.roundComplete)
                state = try state.applying(.check)
                XCTAssertTrue(state.roundComplete)
                try state.validate()
                XCTAssertEqual(state.pot, count * 50)
            }
        }
    }

    func testEightPlayerLiveStraddleHasDistinctPreflopAndPostflopMinimums() throws {
        let start = try rules(.mandatory(amount: 100)).startHand(seats: players(8), button: 0)
        XCTAssertEqual(start.positions.smallBlind, 1)
        XCTAssertEqual(start.positions.bigBlind, 2)
        XCTAssertEqual(start.positions.straddle, 3)
        XCTAssertEqual(start.state.pending, [4, 5, 6, 7, 0, 1, 2, 3])
        XCTAssertEqual(start.state.bigBlind, 50)
        XCTAssertEqual(start.state.minimumBet, 100)
        XCTAssertEqual(start.state.currentBet, 100)
        XCTAssertEqual(start.state.minimumRaiseTo, 200)
        XCTAssertEqual(start.state.pot, 170)
        XCTAssertEqual(start.forcedBets.map(\.paidAmount), [20, 50, 100])
        XCTAssertTrue(start.state.seats.allSatisfy { $0.actedAtBet == nil })

        var state = start.state
        for _ in 0..<7 { state = try state.applying(.call) }
        XCTAssertEqual(state.actor, 3)
        XCTAssertEqual(state.amountToCall(3), 0)
        XCTAssertTrue(state.legalActions().contains(.raiseTo(200)))
        state = try state.applying(.check)
        let flop = try state.advancing(to: Card.parse("2c3d7h"))
        XCTAssertEqual(flop.actor, 1)
        XCTAssertEqual(flop.minimumBet, 50)
        XCTAssertEqual(flop.minimumRaiseTo, 50)
        XCTAssertEqual(flop.lastFullRaise, 50)
        XCTAssertEqual(flop.bigBlind, 50)
        XCTAssertEqual(flop.pot, 800)
        XCTAssertTrue(flop.seats.allSatisfy { $0.streetCommitted == 0 && $0.actedAtBet == nil })
    }

    func testOptionalStraddleNeedsAnExplicitPerHandChoiceAndForcedDoesNot() throws {
        let optional = try rules(.optional(amount: 100))
        let declined = try optional.startHand(seats: players(8), button: 0)
        let chosen = try optional.startHand(seats: players(8), button: 0, optionalStraddle: true)
        let forced = try rules(.mandatory(amount: 100)).startHand(seats: players(8), button: 0)
        XCTAssertEqual(declined.state.currentBet, 50)
        XCTAssertNil(declined.positions.straddle)
        XCTAssertEqual(chosen.state, forced.state)
        XCTAssertThrowsError(try rules().startHand(seats: players(8), button: 0, optionalStraddle: true))
        XCTAssertThrowsError(try rules(.mandatory(amount: 100)).startHand(seats: players(2), button: 0))
        XCTAssertNoThrow(try optional.startHand(seats: players(2), button: 0))
        let three = try optional.startHand(seats: players(3), button: 0, optionalStraddle: true)
        XCTAssertEqual(three.positions.straddle, 0)
        XCTAssertEqual(three.state.pending, [1, 2, 0])
    }

    func testOriginalVideoBlindOnlyStateCanReplayFiveFoldsToHero() throws {
        // Capture-to-clockwise mapping is [top, right upper, right middle, right lower,
        // hero, left lower, left middle, left upper]. D is index 3 in frame 0018.
        var state = try rules(.optional(amount: 100)).startHand(seats: players(8), button: 3,
            optionalStraddle: true).state
        XCTAssertEqual(state.pending, [7, 0, 1, 2, 3, 4, 5, 6])
        for _ in 0..<5 { state = try state.applying(.fold) }
        XCTAssertEqual(state.actor, 4)
        XCTAssertEqual(state.seats[4].streetCommitted, 20)
        XCTAssertEqual(state.amountToCall(4), 80)
        XCTAssertEqual(state.pot, 170)
        XCTAssertEqual(state.minimumRaiseTo, 200)
        XCTAssertThrowsError(try state.applying(.raiseTo(180)))
        XCTAssertNoThrow(try state.applying(.raiseTo(230)))
    }

    func testAntesAreDeadContributionsAndDoNotChangeTheLiveCallAmount() throws {
        let start = try rules(.mandatory(amount: 100), ante: 10).startHand(seats: players(8), button: 0)
        XCTAssertEqual(start.state.pot, 250)
        XCTAssertEqual(start.state.seats.map(\.streetCommitted).reduce(0, +), 170)
        XCTAssertEqual(start.state.amountToCall(4), 100)
        XCTAssertEqual(start.forcedBets.filter { $0.kind == .ante }.map(\.paidAmount), Array(repeating: 10, count: 8))
        XCTAssertEqual(start.state.seats.map { $0.stack + $0.committed }.reduce(0, +), 40_000)
    }

    func testShortOptionalStraddleIsRejectedWhileExplicitMandatoryFloorIsPreserved() throws {
        var seats = players(8)
        seats[3].stack = 70
        XCTAssertThrowsError(try rules(.optional(amount: 100)).startHand(seats: seats, button: 0, optionalStraddle: true))
        let start = try rules(.mandatory(amount: 100)).startHand(seats: seats, button: 0)
        XCTAssertEqual(start.state.seats[3].stack, 0)
        XCTAssertEqual(start.state.seats[3].streetCommitted, 70)
        XCTAssertEqual(start.state.currentBet, 100)
        XCTAssertEqual(start.state.amountToCall(4), 100)
        XCTAssertEqual(start.state.minimumRaiseTo, 200)
        XCTAssertFalse(start.state.pending.contains(3))
        XCTAssertEqual(start.forcedBets.last?.nominalAmount, 100)
        XCTAssertEqual(start.forcedBets.last?.paidAmount, 70)
        try start.state.validate()
    }

    func testShortBigBlindKeepsNominalBringInWhenOtherPlayersCanBet() throws {
        var seats = players(3)
        seats[2].stack = 30
        var state = try rules().startHand(seats: seats, button: 0).state
        XCTAssertEqual(state.currentBet, 50)
        XCTAssertEqual(state.amountToCall(0), 50)
        XCTAssertEqual(state.minimumRaiseTo, 100)
        state = try state.applying(.call)
        state = try state.applying(.call)
        XCTAssertTrue(state.roundComplete)
        XCTAssertEqual(state.pot, 130)
        XCTAssertEqual(try PotSettlement.layers(seats: state.seats), [
            PotLayer(amount: 90, eligible: [0, 1, 2], refundTo: nil),
            PotLayer(amount: 40, eligible: [0, 1], refundTo: nil)
        ])
    }

    func testHeadsUpShortBlindCannotForceAPhantomCallOrBlindOption() throws {
        var seats = players(2)
        seats[1].stack = 10
        let alreadyCovered = try rules().startHand(seats: seats, button: 0).state
        XCTAssertTrue(alreadyCovered.roundComplete)
        XCTAssertEqual(alreadyCovered.amountToCall(0), 0)
        XCTAssertFalse(alreadyCovered.mayRaise(0))
        XCTAssertEqual(try PotSettlement.layers(seats: alreadyCovered.seats), [
            PotLayer(amount: 20, eligible: [0, 1], refundTo: nil),
            PotLayer(amount: 10, eligible: [0], refundTo: 0)
        ])
        seats[1].stack = 30
        let owesActual = try rules().startHand(seats: seats, button: 0).state
        XCTAssertEqual(owesActual.amountToCall(0), 10)
        XCTAssertEqual(owesActual.legalActions(), [.fold, .call])
        let called = try owesActual.applying(.call)
        XCTAssertEqual(called.pot, 60)
        XCTAssertTrue(called.roundComplete)
        try called.validate()
    }

    func testAnOpponentWhoCanOnlyCallShortCannotReceiveAUsefulRaise() throws {
        let state = try TableState(seats: [
            Seat(id: 0, stack: 500, committed: 100, streetCommitted: 100),
            Seat(id: 1, stack: 30, committed: 50, streetCommitted: 50)
        ], board: Card.parse("2c3d7h"), bigBlind: 50, button: 0,
            currentBet: 100, lastFullRaise: 100, pending: [1, 0])
        XCTAssertFalse(state.mayRaise(0))
        XCTAssertFalse(state.mayRaise(1))
    }

    func testShortOpeningBetRequiresFullRaiseAboveItsActualAmount() throws {
        let state = try TableState(seats: [Seat(id: 0, stack: 5), Seat(id: 1, stack: 100), Seat(id: 2, stack: 100)],
            board: Card.parse("2c3d7h"), bigBlind: 10, button: 2, currentBet: 0, lastFullRaise: 10, pending: [0, 1, 2])
        let short = try state.applying(.raiseTo(5))
        XCTAssertEqual(short.minimumRaiseTo, 15)
        XCTAssertThrowsError(try short.applying(.raiseTo(10)))
        let raised = try short.applying(.raiseTo(15))
        XCTAssertEqual(raised.lastFullRaise, 10)
        XCTAssertEqual(raised.minimumRaiseTo, 25)
    }

    func testStraddleShortAllInsReopenOnlyAfterAFullCumulativeRaise() throws {
        let seats = [Seat(id: 0, stack: 500, committed: 100, streetCommitted: 100, actedAtBet: 100),
                     Seat(id: 1, stack: 50, committed: 100, streetCommitted: 100),
                     Seat(id: 2, stack: 100, committed: 100, streetCommitted: 100),
                     Seat(id: 3, stack: 500, committed: 100, streetCommitted: 100)]
        let initial = try TableState(seats: seats, board: [], bigBlind: 50, button: 0,
            currentBet: 100, lastFullRaise: 100, pending: [1, 2, 3], preflopMinimum: 100)
        let one = try initial.applying(.raiseTo(150))
        XCTAssertFalse(one.mayRaise(0))
        XCTAssertEqual(one.minimumRaiseTo, 250)
        let two = try one.applying(.raiseTo(200))
        XCTAssertTrue(two.mayRaise(0))
        XCTAssertEqual(two.minimumRaiseTo, 300)
        XCTAssertEqual(two.lastFullRaise, 100)
    }

    func testOriginalVideoCounterfactualSidePotEligibilityAndDeadMoney() throws {
        let seats = [Seat(id: 0, stack: 0, committed: 1_122),
                     Seat(id: 1, stack: 100, committed: 2_100),
                     Seat(id: 2, stack: 100, committed: 2_100),
                     Seat(id: 3, stack: 100, committed: 280, folded: true),
                     Seat(id: 4, stack: 100, committed: 20, folded: true),
                     Seat(id: 5, stack: 100, committed: 50, folded: true)]
        XCTAssertEqual(try PotSettlement.layers(seats: seats), [
            PotLayer(amount: 3_716, eligible: [0, 1, 2], refundTo: nil),
            PotLayer(amount: 1_956, eligible: [1, 2], refundTo: nil)
        ])
        let values = [0: try HandEvaluator.evaluate(Card.parse("AsKsQsJsTs")),
                      1: try HandEvaluator.evaluate(Card.parse("AcAdAhAs2c")),
                      2: try HandEvaluator.evaluate(Card.parse("2c3d4h5s6c"))]
        XCTAssertEqual(try PotSettlement.integerAwards(seats: seats, values: values, button: 0), [3_716, 1_956, 0, 0, 0, 0])
        XCTAssertEqual(try PotSettlement.expectedAwards(seats: seats, values: values), [3_716, 1_956, 0, 0, 0, 0])
    }

    func testOriginalVideoUncalledRaiseRefundDoesNotGiveAllInOpponentFoldEquity() throws {
        let seats = [Seat(id: 0, stack: 0, committed: 1_122),
                     Seat(id: 1, stack: 100, committed: 2_100),
                     Seat(id: 2, stack: 100, committed: 280, folded: true),
                     Seat(id: 3, stack: 100, committed: 280, folded: true),
                     Seat(id: 4, stack: 100, committed: 20, folded: true),
                     Seat(id: 5, stack: 100, committed: 50, folded: true)]
        XCTAssertEqual(try PotSettlement.layers(seats: seats), [
            PotLayer(amount: 2_874, eligible: [0, 1], refundTo: nil),
            PotLayer(amount: 978, eligible: [1], refundTo: 1)
        ])
    }

    func testOldInitializerAndOldJSONKeepOrdinaryBigBlindDefaults() throws {
        let original = try TableState(seats: players(2), board: Card.parse("2c3d7h"), bigBlind: 50,
            button: 0, currentBet: 0, lastFullRaise: 50, pending: [1, 0])
        XCTAssertNil(original.preflopMinimum)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "preflopMinimum")
        let decoded = try JSONDecoder().decode(TableState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.minimumBet, 50)
        try decoded.validate()
    }

    func testRandomCompleteHandsConserveChipsAcrossStraddlesShortStacksAndAllStreets() throws {
        var random = SplitMix64(state: 20260916)
        let runout = try Card.parse("2c3d7h9sJc")
        let equalShowdownValue = try HandEvaluator.evaluate(Card.parse("AsKsQsJsTs"))
        for hand in 0..<200 {
            let count = 2 + random.index(8)
            let initial = (0..<count).map { Seat(id: $0, stack: 1 + random.index(1_000)) }
            let total = initial.map(\.stack).reduce(0, +)
            let policy: UTGStraddlePolicy = count > 2 && hand % 2 == 0 ? .mandatory(amount: 100) : .disabled
            var state = try rules(policy, ante: hand % 3 == 0 ? 10 : 0)
                .startHand(seats: initial, button: random.index(count)).state
            var decisions = 0
            while true {
                while !state.roundComplete {
                    let actions = state.legalActions()
                    XCTAssertFalse(actions.isEmpty)
                    state = try state.applying(actions[random.index(actions.count)])
                    try state.validate()
                    XCTAssertEqual(state.seats.map { $0.stack + $0.committed }.reduce(0, +), total)
                    decisions += 1
                    XCTAssertLessThan(decisions, 1_000)
                }
                if state.live.count <= 1 || state.board.count == 5 { break }
                let nextCount = state.board.isEmpty ? 3 : state.board.count + 1
                state = try state.advancing(to: Array(runout.prefix(nextCount)))
                try state.validate()
                XCTAssertEqual(state.minimumBet, 50)
                XCTAssertEqual(state.lastFullRaise, 50)
            }
            let values = Dictionary(uniqueKeysWithValues: state.live.map { ($0, equalShowdownValue) })
            let awards = try PotSettlement.integerAwards(seats: state.seats, values: values, button: state.button)
            XCTAssertEqual(awards.reduce(0, +) + state.seats.map(\.stack).reduce(0, +), total)
            let expected = try PotSettlement.expectedAwards(seats: state.seats, values: values)
            XCTAssertEqual(expected.reduce(0, +), Double(state.pot), accuracy: 1e-7)
        }
    }

    func testRejectsInvalidRulesAndAccidentallyReusedHandState() throws {
        XCTAssertThrowsError(try PokerGameRules(smallBlind: 0, bigBlind: 50))
        XCTAssertThrowsError(try PokerGameRules(smallBlind: 100, bigBlind: 50))
        XCTAssertThrowsError(try rules(.optional(amount: 75)))
        XCTAssertThrowsError(try rules(ante: -1))
        XCTAssertThrowsError(try rules().startHand(seats: players(10), button: 0))
        XCTAssertThrowsError(try rules().startHand(seats: players(2), button: 2))
        var prior = players(3); prior[0].committed = 10
        XCTAssertThrowsError(try rules().startHand(seats: prior, button: 0))
        prior = players(3); prior[1].stack = 0
        XCTAssertThrowsError(try rules().startHand(seats: prior, button: 0))
        prior = players(3); prior[0].folded = true
        XCTAssertThrowsError(try rules().startHand(seats: prior, button: 0))
    }
}
