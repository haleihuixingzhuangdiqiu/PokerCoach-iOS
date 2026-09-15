import XCTest
@testable import PokerCoachCore

final class ResearchDecisionTests: XCTestCase {
    private let budget = ResearchDecisionBudget(samplesPerScenario: 800, milliseconds: 5_000, seed: 18)
    private func position(_ hero: [String] = ["Ah", "Th"], board: [String] = ["Kh", "Qh", "Jh", "2c", "3d"]) throws -> LiveCardPosition {
        try LiveCardPosition(slots: hero.map(Optional.some) + board.map(Optional.some) + Array(repeating: nil, count: 5 - board.count))
    }
    private func facts(pot: String = "10", settled: String? = nil, call: String? = nil, stack: String = "20", folds: Int = 6) -> PublicBettingFacts {
        var raw = ["pot": pot, "stack": stack]
        if let settled { raw["settled"] = settled }
        if let call { raw["call"] = call }
        var scores = Dictionary(uniqueKeysWithValues: raw.keys.map { ($0, Float(1)) })
        for seat in 0..<folds { raw["seat.\(seat)"] = "弃牌"; scores["seat.\(seat)"] = 1 }
        return PublicBettingFacts(raw: raw, scores: scores, callControlVisible: call != nil)
    }
    private func opening(position: LiveCardPosition? = nil, facts: PublicBettingFacts? = nil,
                         amounts: [Int] = [50, 100], opponentStack: Int? = 1_000,
                         counts: ClosedRange<Int>? = nil) throws -> ResearchDecisionRequest {
        ResearchDecisionRequest(position: try position ?? self.position(), facts: facts ?? self.facts(settled: "10"),
            actions: .init(heroTurnConfirmed: true, checkAvailable: true, visibleBetAmounts: amounts),
            opponentCounts: counts, knownHeadsUpOpponentStack: opponentStack)
    }

    func testNoConfirmedTurnReturnsNoActionOrInventedWinRate() throws {
        let request = ResearchDecisionRequest(position: try position(), facts: facts(call: "3"),
            actions: .init(heroTurnConfirmed: false, foldAvailable: true, callAmount: 300))
        let result = try ResearchDecisionEngine.analyze(request, budget: budget)
        XCTAssertNil(result.suggested)
        XCTAssertTrue(result.outrightWinProbabilityRange.isEmpty)
        XCTAssertTrue(result.scenarios.isEmpty)
    }

    func testMissingCallNeverBecomesCheckAndConflictingControlsAreRejected() throws {
        let cards = try position()
        let empty = try ResearchDecisionEngine.analyze(.init(position: cards, facts: facts(), actions: .init(heroTurnConfirmed: true)), budget: budget)
        XCTAssertNil(empty.suggested)
        for actions in [VisiblePassiveActions(heroTurnConfirmed: true, checkAvailable: true, callAmount: 300),
                        .init(heroTurnConfirmed: true, foldAvailable: false, callAmount: 300),
                        .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 200)] {
            XCTAssertThrowsError(try ResearchDecisionEngine.analyze(.init(position: cards, facts: facts(call: "3"), actions: actions), budget: budget))
        }
    }

    func testNutsCallsExactVisibleAdditionalAmountAcrossThreeRanges() throws {
        let request = ResearchDecisionRequest(position: try position(), facts: facts(call: "3.2"),
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 320, visibleBetAmounts: [600]))
        let result = try ResearchDecisionEngine.analyze(request, budget: budget)
        XCTAssertEqual(result.suggested, .call(320))
        XCTAssertEqual(result.additionalChips, 320)
        XCTAssertEqual(result.outrightWinProbabilityRange, [1, 1])
        XCTAssertEqual(result.tieProbabilityRange, [0, 0])
        XCTAssertEqual(result.equityRange, [1, 1])
        XCTAssertEqual(result.scenarios.count, 3)
        XCTAssertFalse(result.modelSensitive)
        XCTAssertTrue(result.betComparisons.isEmpty)
        XCTAssertEqual(result.unsupportedAggressiveAmounts, [600])
    }

    func testNeverWinningRiverFoldsAnExpensiveVisibleCall() throws {
        let cards = try position(["2c", "3d"], board: ["As", "Ks", "Qs", "Js", "9s"])
        let result = try ResearchDecisionEngine.analyze(.init(position: cards, facts: facts(call: "10"),
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 1_000)), budget: budget)
        XCTAssertEqual(result.suggested, .fold)
        XCTAssertEqual(result.additionalChips, 0)
        XCTAssertEqual(result.outrightWinProbabilityRange, [0, 0])
        XCTAssertTrue(result.scenarios.allSatisfy { $0.passiveValue < 0 })
    }

    func testUnknownOpponentCountIsEvaluatedAsEveryPossibleScenario() throws {
        let cards = try position(["2c", "3d"], board: ["Ah", "Kh", "Qh", "Jh", "Th"])
        let result = try ResearchDecisionEngine.analyze(.init(position: cards, facts: facts(call: "1", folds: 4),
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 100)), budget: budget)
        XCTAssertEqual(Set(result.scenarios.map(\.opponentCount)), Set([1, 2, 3]))
        XCTAssertEqual(result.scenarios.count, 9)
        XCTAssertTrue(result.opponentCountUncertain)
        XCTAssertEqual(result.outrightWinProbabilityRange, [0, 0])
        XCTAssertEqual(result.tieProbabilityRange, [1, 1])
        XCTAssertEqual(result.equityRange[0], 0.25, accuracy: 1e-10)
        XCTAssertEqual(result.equityRange[1], 0.5, accuracy: 1e-10)
        XCTAssertNil(result.suggested)
        XCTAssertNotNil(result.withheldActionReason)
        XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
    }

    func testOpponentCountDisagreementCannotChooseAnActionWithoutContributionState() throws {
        let cards = try position(["2c", "3d"], board: ["Ah", "Kh", "Qh", "Jh", "Th"])
        let result = try ResearchDecisionEngine.analyze(.init(position: cards, facts: facts(call: "5", folds: 4),
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 500)), budget: budget)
        XCTAssertNil(result.suggested)
        XCTAssertNotNil(result.withheldActionReason)
        XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
        XCTAssertTrue(result.scenarios.contains { $0.preferred == .call })
        XCTAssertTrue(result.scenarios.contains { $0.preferred == .fold })
    }

    func testOpeningBetWithNutsChoosesOnlyAnObservedAffordableAmount() throws {
        let request = try opening(amounts: [50, 100, 5_000])
        let result = try ResearchDecisionEngine.analyze(request, budget: budget)
        XCTAssertEqual(result.suggested, .bet(100))
        XCTAssertEqual(result.additionalChips, 100)
        XCTAssertEqual(result.betComparisons.count, 18)
        XCTAssertEqual(Set(result.betComparisons.map(\.additionalChips)), Set([50, 100]))
        XCTAssertEqual(result.unsupportedAggressiveAmounts, [5_000])
        for comparison in result.betComparisons {
            let fold = comparison.assumedFoldProbability, amount = Double(comparison.additionalChips)
            let expected = fold * 1_000 + (1 - fold) * (comparison.calledEquity.equity * (1_000 + 2 * amount) - amount)
            XCTAssertEqual(comparison.value, expected, accuracy: 1e-8)
            XCTAssertGreaterThan(comparison.value, comparison.checkValue)
        }
    }

    func testSharedRoyalBoardDoesNotInventOpponentFoldsOrAProfitableBet() throws {
        let cards = try position(["2c", "3d"], board: ["Ah", "Kh", "Qh", "Jh", "Th"])
        let result = try ResearchDecisionEngine.analyze(opening(position: cards), budget: budget)
        XCTAssertEqual(result.suggested, .check)
        XCTAssertEqual(result.outrightWinProbabilityRange, [0, 0])
        XCTAssertEqual(result.tieProbabilityRange, [1, 1])
        XCTAssertEqual(result.equityRange, [0.5, 0.5])
        for comparison in result.betComparisons {
            XCTAssertEqual(comparison.assumedFoldProbability, 0, accuracy: 1e-10)
            XCTAssertEqual(comparison.value, 500, accuracy: 1e-8)
            XCTAssertEqual(comparison.checkValue, 500, accuracy: 1e-8)
        }
    }

    func testMissingOpeningConditionsRestrictResultToConfirmedCheck() throws {
        let inputs = [try opening(opponentStack: nil),
                      try opening(facts: facts(settled: "9")),
                      try opening(facts: facts(settled: "10", folds: 5)),
                      try opening(amounts: []),
                      try opening(amounts: [100], opponentStack: 50),
                      try opening(position: position(["As", "Kd"], board: []))]
        for input in inputs {
            let result = try ResearchDecisionEngine.analyze(input, budget: budget)
            XCTAssertEqual(result.suggested, .check)
            XCTAssertTrue(result.betComparisons.isEmpty)
            XCTAssertEqual(result.additionalChips, 0)
        }
    }

    func testTighterResponseHasAtLeastAsMuchAssumedFolding() throws {
        let result = try ResearchDecisionEngine.analyze(opening(amounts: [100]), budget: budget)
        for range in ResearchRangeAssumption.allCases {
            let values = result.betComparisons.filter { $0.rangeAssumption == range }
            let tight = try XCTUnwrap(values.first { $0.responseAssumption == .tight })
            let neutral = try XCTUnwrap(values.first { $0.responseAssumption == .neutral })
            let loose = try XCTUnwrap(values.first { $0.responseAssumption == .loose })
            XCTAssertGreaterThanOrEqual(tight.assumedFoldProbability, neutral.assumedFoldProbability)
            XCTAssertGreaterThanOrEqual(neutral.assumedFoldProbability, loose.assumedFoldProbability)
        }
    }

    func testAllFiveFlopButtonsAreComparedWithSharedSamples() throws {
        let cards = try position(["Kh", "Qs"], board: ["7h", "Qd", "Ks"])
        let request = try opening(position: cards, facts: facts(pot: "3.5", settled: "3.5"),
                                  amounts: [120, 180, 230, 350, 420])
        let result = try ResearchDecisionEngine.analyze(request, budget: .init())
        XCTAssertEqual(result.betComparisons.count, 45)
        XCTAssertEqual(Set(result.betComparisons.map(\.additionalChips)), Set([120, 180, 230, 350, 420]))
        XCTAssertTrue(result.betComparisons.allSatisfy { $0.calledEquity.samples >= 500 })
        XCTAssertTrue(result.betComparisons.allSatisfy { $0.calledEquity.confidence95[0] <= $0.calledEquity.equity && $0.calledEquity.equity <= $0.calledEquity.confidence95[1] })
        XCTAssertNotNil(result.suggested)
    }

    func testRangeAssumptionsHaveExplicitDifferentWeightsAndRespectBlockers() throws {
        let cards = try position(["Ks", "Qh"], board: ["Ac", "7s", "8d"])
        let ranges = try ResearchDecisionEngine.scenarioRanges(position: cards)
        let blocked = (cards.hero.cards + cards.board).reduce(UInt64(0)) { $0 | $1.mask }
        for range in ranges.values {
            XCTAssertTrue(range.combos.allSatisfy { $0.hand.mask & blocked == 0 && $0.weight > 0 })
            XCTAssertEqual(range.combos.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-10)
        }
        let aces = try HoleCards("AhAd"), low = try HoleCards("2c3d")
        let value = try XCTUnwrap(ranges[.valueWeighted])
        XCTAssertGreaterThan(try XCTUnwrap(value.combos.first { $0.hand == aces }).weight,
                             try XCTUnwrap(value.combos.first { $0.hand == low }).weight)
    }

    func testCancellationAndInvalidBudgetDoNotYieldPartialAction() throws {
        let request = try opening()
        XCTAssertThrowsError(try ResearchDecisionEngine.analyze(request, budget: budget, isCancelled: { true })) {
            XCTAssertEqual($0 as? PokerError, .cancelled)
        }
        XCTAssertThrowsError(try ResearchDecisionEngine.analyze(request, budget: .init(samplesPerScenario: 499)))
        let badCounts = try opening(counts: 1...2)
        XCTAssertThrowsError(try ResearchDecisionEngine.analyze(badCounts, budget: budget))
    }

    func testInputEqualityChangesWhenAnObservedControlOrOpponentStackChanges() throws {
        XCTAssertEqual(try opening(), try opening())
        XCTAssertNotEqual(try opening(), try opening(amounts: [50]))
        XCTAssertNotEqual(try opening(), try opening(opponentStack: 500))
    }
}
