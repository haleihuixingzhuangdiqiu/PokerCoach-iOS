import XCTest
@testable import PokerCoachCore

final class FullHandDecisionTests: XCTestCase {
    private let ample = ComputeBudget(samples: 128, milliseconds: 20_000, seed: 781)
    private func sidePotState(board: String = "QsJsTs2d3h") throws -> TableState {
        try TableState(seats: [Seat(id: 10, stack: 900, committed: 100),
                               Seat(id: 11, stack: 100, committed: 200, streetCommitted: 100, actedAtBet: 100),
                               Seat(id: 12, stack: 50, committed: 150, streetCommitted: 50, actedAtBet: 50)],
                       board: Card.parse(board), bigBlind: 10, button: 2,
                       currentBet: 100, lastFullRaise: 100, pending: [0, 2])
    }
    func testThreeWayShortAllInsCreateCorrectSidePotsAndRefund() throws {
        let result = try FullHandDecisionEngine.analyze(state: sidePotState(), hero: 0, cards: HoleCards("AsKs"),
            ranges: [1: .parse("AhAd"), 2: .parse("4c5c")], allowedActions: [.fold, .call, .raiseTo(300)],
            profiles: [.checkCall], budget: ample)
        // Raise: commitments 400/300/200, main 600 + side 200 + refund 100.
        // Gross 900 minus NEW hero chips 300 = 600; sunk 100 must not be deducted again.
        XCTAssertEqual(result.actions.first { $0.action == .raiseTo(300) }?.expectedEV, 600)
        XCTAssertEqual(result.actions.first { $0.action == .call }?.expectedEV, 500)
        XCTAssertEqual(result.actions.first { $0.action == .fold }?.expectedEV, 0)
        XCTAssertEqual(result.suggested, .raiseTo(300))
        XCTAssertEqual(result.equity.outrightWinProbability, 1)
        XCTAssertEqual(result.minimumSamplesRequired, 64)
        XCTAssertTrue(result.includesFutureStreets)
    }
    func testRoyalBoardMultiwayTieUsesSidePotShareNotHalfAndNoFalseWin() throws {
        let result = try FullHandDecisionEngine.analyze(state: sidePotState(board: "AsKsQsJsTs"), hero: 0,
            cards: HoleCards("2c3c"), ranges: [1: .parse("4c5c"), 2: .parse("6c7c")],
            allowedActions: [.fold, .call, .raiseTo(300)], profiles: [.checkCall], budget: ample)
        XCTAssertEqual(result.equity.outrightWinProbability, 0)
        XCTAssertEqual(result.equity.tieProbability, 1)
        XCTAssertEqual(result.equity.equity, 1.0 / 3, accuracy: 1e-12)
        // 200 main share + 100 side share + 100 unmatched refund - 300 new chips.
        XCTAssertEqual(result.actions.first { $0.action == .raiseTo(300) }?.expectedEV, 100)
        XCTAssertEqual(result.actions.first { $0.action == .call }?.expectedEV, 100)
        XCTAssertEqual(result.suggested, .call)
    }
    func testRealActionWhitelistAllowsNonDefaultSizeAndRejectsInvalidActions() throws {
        let state = try sidePotState(), own = try HoleCards("AsKs")
        let ranges = try [1: HandRange.parse("AhAd"), 2: .parse("4c5c")]
        let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: [.raiseTo(237)], profiles: [.checkCall], budget: ample)
        XCTAssertEqual(result.actions.map(\.action), [.raiseTo(237)])
        XCTAssertEqual(result.actions[0].additionalChips, 237)
        for invalid: [PokerAction] in [[], [.call, .call], [.check], [.raiseTo(150)], [.raiseTo(901)]] {
            XCTAssertThrowsError(try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own,
                ranges: ranges, allowedActions: invalid, budget: ample))
        }
    }
    func testShortAllInDoesNotReopenHeroRaiseRight() throws {
        let state = try TableState(seats: [Seat(id: 0, stack: 850, committed: 150, streetCommitted: 100, actedAtBet: 100),
                                          Seat(id: 1, stack: 0, committed: 200, streetCommitted: 150, actedAtBet: 150),
                                          Seat(id: 2, stack: 850, committed: 150, streetCommitted: 100, actedAtBet: 100)],
            board: Card.parse("QsJsTs2d3h"), bigBlind: 10, button: 2, currentBet: 150, lastFullRaise: 100, pending: [0, 2])
        XCTAssertFalse(state.mayRaise(0))
        XCTAssertThrowsError(try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: HoleCards("AsKs"),
            ranges: [1: .parse("AhAd"), 2: .parse("4c5c")], allowedActions: [.raiseTo(250)], budget: ample))
        let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: HoleCards("AsKs"),
            ranges: [1: .parse("AhAd"), 2: .parse("4c5c")], allowedActions: [.fold, .call], profiles: [.checkCall], budget: ample)
        XCTAssertEqual(result.suggested, .call)
        XCTAssertEqual(result.actions.first { $0.action == .call }?.additionalChips, 50)
    }
    func testReRaiseRolloutReturnsToHeroRatherThanAssumingOneOpponentResponse() throws {
        let initial = try TableState(seats: (0..<3).map { Seat(id: $0, stack: 500, committed: 10) },
            board: Card.parse("2c3c4c"), bigBlind: 10, button: 0, currentBet: 0, lastFullRaise: 10, pending: [0, 1, 2])
        let hands = try [0: HoleCards("AcKc"), 1: HoleCards("5c6c"), 2: HoleCards("7c8c")]
        let aggressive = try BehaviorProfile(name: "测试强进攻假设", callOffset: 0.5, aggression: 2)
        var witnessed = false
        for seed: UInt64 in 0..<64 {
            var rng = SplitMix64(state: seed), actors: [Int] = []
            let final = try BettingRollout.finishStreet(state: initial.applying(.raiseTo(100)), hands: hands,
                hero: 0, opponentProfile: aggressive, heroProfile: .checkCall, raisesAlready: 1,
                configuration: .fullHand, rng: &rng, checkpoint: {}, observe: { actors.append($0.actor) })
            try final.validate()
            if actors.contains(0) {
                XCTAssertGreaterThan(final.seats[0].streetCommitted, 100)
                XCTAssertTrue(final.roundComplete)
                witnessed = true; break
            }
        }
        XCTAssertTrue(witnessed, "At least one deterministic seed must exercise a hero decision after a reraise")
    }
    func testFutureRiverBettingChangesEVWithNutsAndKnownCallers() throws {
        let state = try TableState(seats: (0..<3).map { Seat(id: $0, stack: 500, committed: 100) },
            board: Card.parse("QsJsTs2d"), bigBlind: 10, button: 0, currentBet: 0, lastFullRaise: 10, pending: [0, 1, 2])
        let own = try HoleCards("AsKs"), ranges = try [1: HandRange.parse("AhAd"), 2: .parse("9c9d")]
        let aggressive = try BehaviorProfile(name: "测试本人未来强进攻", callOffset: 0.5, aggression: 2)
        let checkdown = try DecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            profiles: [.checkCall], heroContinuation: aggressive, candidateActions: [.check], budget: ample)
        let future = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: [.check], profiles: [.checkCall], heroContinuation: aggressive, budget: ample)
        XCTAssertEqual(checkdown.actions[0].expectedEV, 300)
        XCTAssertGreaterThan(future.actions[0].expectedEV, 300)
        XCTAssertEqual(future.equity.outrightWinProbability, 1)
        XCTAssertEqual(future.equity.samples, ample.samples)
    }
    func testFuturePoliciesReceiveOnlyOwnCardsAndRevealedBoardPrefix() throws {
        let state = try TableState(seats: (0..<3).map { Seat(id: $0, stack: 500, committed: 10) },
            board: [], bigBlind: 10, button: 0, currentBet: 0, lastFullRaise: 10, pending: [])
        let hands = try [0: HoleCards("AsAd"), 1: HoleCards("KhKd"), 2: HoleCards("QhQd")]
        var traces: [[RolloutPolicyInformation]] = []
        for runout in ["2c3d4h5s6c", "2c3d4h9sTc"] {
            let board = try Card.parse(runout)
            var rng = SplitMix64(state: 5), seen: [RolloutPolicyInformation] = []
            _ = try BettingRollout.finishFutureStreets(state: state, completeBoard: board, hands: hands, hero: 0,
                opponentProfile: .checkCall, heroProfile: .checkCall, configuration: .fullHand,
                rng: &rng, checkpoint: {}, observe: { seen.append($0) })
            XCTAssertEqual(seen.map { $0.publicBoard.count }, [3, 3, 3, 4, 4, 4, 5, 5, 5])
            for observation in seen {
                XCTAssertEqual(observation.ownCards, hands[observation.actor])
                XCTAssertEqual(observation.publicBoard, Array(board.prefix(observation.publicBoard.count)))
            }
            traces.append(seen)
        }
        XCTAssertEqual(Array(traces[0].prefix(3)), Array(traces[1].prefix(3)), "Changing undealt turn/river cannot change flop policy information")
    }
    func testSeedAndCandidateOrderReproduceCompletedSampleEstimates() throws {
        let state = try sidePotState(), own = try HoleCards("AsKs")
        let ranges = try [1: HandRange.parse("AhAd,4c5c"), 2: .parse("6c7c,8c9c")]
        let candidates: [PokerAction] = [.fold, .call, .raiseTo(300)]
        let a = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: candidates, budget: ample)
        let b = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: candidates.reversed(), budget: ample)
        XCTAssertTrue(a.completedBudget && b.completedBudget)
        XCTAssertEqual(a.equity.outrightWinProbability, b.equity.outrightWinProbability)
        for estimate in a.actions {
            let other = try XCTUnwrap(b.actions.first { $0.action == estimate.action })
            XCTAssertEqual(estimate.scenarios.map(\.mean), other.scenarios.map(\.mean))
            XCTAssertEqual(estimate.scenarios.map(\.standardError), other.scenarios.map(\.standardError))
        }
        XCTAssertEqual(a.suggested, b.suggested)
    }
    func testMixtureEVSelectionCanDifferFromWorstScenarioSelection() throws {
        let state = try TableState(seats: [Seat(id: 0, stack: 100, committed: 500),
                                          Seat(id: 1, stack: 90, committed: 510, streetCommitted: 10, actedAtBet: 10)],
            board: Card.parse("2c2d7h9sJc"), bigBlind: 10, button: 0, currentBet: 10, lastFullRaise: 10, pending: [0])
        let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: HoleCards("KhQh"),
            ranges: [1: .parse("Ah4h")], allowedActions: [.fold, .call, .raiseTo(100)],
            profiles: [.tight, .neutral, .checkCall], budget: .init(samples: 512, milliseconds: 20_000, seed: 55))
        let raise = try XCTUnwrap(result.actions.first { $0.action == .raiseTo(100) })
        XCTAssertGreaterThan(raise.expectedEV, 0)
        XCTAssertEqual(raise.worstScenarioEV, -100)
        XCTAssertEqual(result.suggested, .raiseTo(100))
        XCTAssertFalse(result.agreementAcrossScenarios)
    }
    func testMinimumSamplesAndCancellationNeverReturnAnIncompleteCandidateBatch() throws {
        let state = try sidePotState(), own = try HoleCards("AsKs")
        let ranges = try [1: HandRange.parse("AhAd"), 2: .parse("4c5c")]
        XCTAssertThrowsError(try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: [.call], budget: .init(samples: 63, milliseconds: 20_000)))
        var checkpoints = 0
        XCTAssertThrowsError(try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: [.fold, .call, .raiseTo(300)], budget: ample, isCancelled: {
                checkpoints += 1; return checkpoints > 30
            })) { error in
                guard case PokerError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
            }
        XCTAssertThrowsError(try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: own, ranges: ranges,
            allowedActions: [.call], budget: .init(samples: 64, milliseconds: 1), isCancelled: {
                Thread.sleep(forTimeInterval: 0.002); return false
            })) { error in
                guard case PokerError.budgetExceeded = error else { return XCTFail("Expected insufficient sample budget, got \(error)") }
            }
    }
    func testNineHandedThirdBlindFullRolloutBudgetSample() throws {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .mandatory(amount: 100))
        let initial = try rules.startHand(seats: (0..<9).map { Seat(id: $0, stack: 5_000) }, button: 0)
        let hero = try XCTUnwrap(initial.state.actor)
        XCTAssertEqual(hero, 4)
        XCTAssertEqual(initial.state.minimumRaiseTo, 200)
        let ranges = Dictionary(uniqueKeysWithValues: try initial.state.live.filter { $0 != hero }.map { ($0, try HandRange.parse("random")) })
        let actions = initial.state.legalActions()
        let result = try FullHandDecisionEngine.analyze(state: initial.state, hero: hero, cards: HoleCards("AsKs"),
            ranges: ranges, allowedActions: actions, budget: .init(samples: 256, milliseconds: 20_000, seed: 312))
        XCTAssertEqual(result.samplesPerScenario, 256)
        XCTAssertTrue(result.completedBudget)
        XCTAssertTrue(actions.contains(result.suggested))
        XCTAssertEqual(result.actions.flatMap(\.scenarios).map(\.samples), Array(repeating: 256, count: actions.count * 3))
        for estimate in result.actions {
            XCTAssertTrue(estimate.expectedEV.isFinite)
            XCTAssertGreaterThanOrEqual(estimate.expectedEV, -Double(initial.state.seats[hero].stack))
            XCTAssertLessThanOrEqual(estimate.expectedEV, Double(initial.state.pot + initial.state.seats.reduce(0) { $0 + $1.stack }))
        }
        print("FULL_HAND_COST players=9 thirdBlind=100 candidates=\(actions.count) scenarios=3 samples=256 futureStreets=true milliseconds=\(result.elapsedMilliseconds)")
    }
}
