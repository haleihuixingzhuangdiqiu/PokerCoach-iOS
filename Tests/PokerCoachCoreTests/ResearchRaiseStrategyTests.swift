import XCTest
@testable import PokerCoachCore

/// Independent money-accounting oracles and policy counterexamples for the live research adapter.
/// Amounts are integer cents; public pots already include all visible street contributions.
final class ResearchRaiseStrategyTests: XCTestCase {
    private let budget = ResearchDecisionBudget(samplesPerScenario: 800, milliseconds: 15_000, seed: 71)

    private func money(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }

    private func position(_ hero: [String] = ["Ah", "Th"],
                          board: [String] = ["Kh", "Qh", "Jh", "2c", "3d"]) throws -> LiveCardPosition {
        try LiveCardPosition(slots: hero.map(Optional.some) + board.map(Optional.some)
            + Array(repeating: nil, count: 5 - board.count))
    }

    private func facts(pot: Int = 1_000, call: Int? = 300, stack: Int = 5_000,
                       folded: Int = 6, visibleAllIn: Bool = false) -> PublicBettingFacts {
        var raw = ["pot": money(pot), "stack": money(stack)]
        if let call { raw["call"] = money(call) }
        if visibleAllIn { raw["allin.visible"] = "true" }
        var scores = Dictionary(uniqueKeysWithValues: raw.keys.map { ($0, Float(1)) })
        for seat in 0..<folded {
            raw["seat.\(seat)"] = "弃牌"
            scores["seat.\(seat)"] = 1
        }
        return PublicBettingFacts(raw: raw, scores: scores, callControlVisible: call != nil)
    }

    private func request(cards: LiveCardPosition? = nil, pot: Int = 1_000, call: Int = 300,
                         stack: Int = 5_000, committed: Int? = 200, totals: [Int] = [900],
                         opponentStack: Int? = 5_000, folded: Int = 6,
                         counts: ClosedRange<Int>? = nil, visibleAllIn: Bool = false) throws -> ResearchDecisionRequest {
        ResearchDecisionRequest(position: try cards ?? position(),
            facts: facts(pot: pot, call: call, stack: stack, folded: folded, visibleAllIn: visibleAllIn),
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: call,
                           heroStreetCommitted: committed, visibleRaiseToAmounts: totals),
            opponentCounts: counts, knownHeadsUpOpponentStack: opponentStack)
    }

    func testSharedRoyalBoardRaiseCannotCreateFoldEquityOrChangeTheSplitPotValue() throws {
        let royal = try position(["2c", "3d"], board: ["Ah", "Kh", "Qh", "Jh", "Th"])
        let result = try ResearchDecisionEngine.analyze(
            request(cards: royal, committed: 200, totals: [600, 900, 1_200]), budget: budget)

        XCTAssertEqual(result.suggested, .call(300))
        XCTAssertEqual(result.additionalChips, 300)
        XCTAssertEqual(result.betComparisons.count, 27)
        XCTAssertEqual(Set(result.betComparisons.map(\.additionalChips)), Set([400, 700, 1_000]))
        for comparison in result.betComparisons {
            // Both players always own the same royal flush. Raising transfers equal
            // extra amounts to a split pot: incremental value is (P-C)/2 = 350.
            // P+2D instead of P+2D-C, or subtracting old H again, breaks this oracle.
            XCTAssertEqual(comparison.assumedFoldProbability, 0, accuracy: 1e-12)
            XCTAssertEqual(comparison.calledEquity.equity, 0.5, accuracy: 1e-12)
            XCTAssertEqual(comparison.value, 350, accuracy: 1e-8)
            XCTAssertEqual(comparison.checkValue, 350, accuracy: 1e-8)
        }
    }

    func testNutsSelectsAnObservedTotalUsingOnlyItsAdditionalCost() throws {
        let result = try ResearchDecisionEngine.analyze(
            request(stack: 700, committed: 200, totals: [500, 600, 900, 900, 5_000], opponentStack: 400),
            budget: budget)

        // 500 merely matches the current wager and is not a raise; 5,000 is unaffordable.
        // To reach 900, hero pays 700 and villain adds 400, exactly their remaining stacks.
        XCTAssertEqual(result.suggested, .raiseTo(total: 900, additional: 700))
        XCTAssertEqual(result.additionalChips, 700)
        XCTAssertEqual(Set(result.betComparisons.map(\.additionalChips)), Set([400, 700]))
        XCTAssertEqual(result.betComparisons.count, 18)
        XCTAssertEqual(result.actionLabel, "建议：加注到9.00")
        for comparison in result.betComparisons {
            XCTAssertEqual(comparison.calledEquity.equity, 1, accuracy: 1e-12)
            let villainAdds = Double(comparison.additionalChips - 300)
            // Hero has exclusive nuts: win existing pot plus the opponent's NEW call.
            // Hero's existing 200 and new wager are not deducted twice.
            let oracle = 1_000 + (1 - comparison.assumedFoldProbability) * villainAdds
            XCTAssertEqual(comparison.value, oracle, accuracy: 1e-8)
            XCTAssertEqual(comparison.checkValue, 1_000, accuracy: 1e-8)
        }
    }

    func testChangingOldContributionAndTotalTogetherDoesNotChangeIncrementalEconomics() throws {
        let first = try ResearchDecisionEngine.analyze(request(pot: 2_000, committed: 200, totals: [900]), budget: budget)
        let second = try ResearchDecisionEngine.analyze(request(pot: 2_000, committed: 500, totals: [1_200]), budget: budget)
        XCTAssertEqual(first.suggested, .raiseTo(total: 900, additional: 700))
        XCTAssertEqual(second.suggested, .raiseTo(total: 1_200, additional: 700))
        XCTAssertEqual(first.betComparisons.count, second.betComparisons.count)
        for (left, right) in zip(first.betComparisons, second.betComparisons) {
            XCTAssertEqual(left.additionalChips, right.additionalChips)
            XCTAssertEqual(left.assumedFoldProbability, right.assumedFoldProbability, accuracy: 1e-12)
            XCTAssertEqual(left.value, right.value, accuracy: 1e-8)
            XCTAssertEqual(left.checkValue, right.checkValue, accuracy: 1e-8)
        }
    }

    func testOpponentOnlyNeedsToCoverRaiseIncrementBeyondTheAlreadyPaidBet() throws {
        let admitted = try ResearchDecisionEngine.analyze(
            request(stack: 700, committed: 200, totals: [900], opponentStack: 400), budget: budget)
        XCTAssertEqual(admitted.suggested, .raiseTo(total: 900, additional: 700))
        XCTAssertEqual(admitted.betComparisons.count, 9)

        for input in [try request(stack: 699, committed: 200, totals: [900], opponentStack: 400),
                      try request(stack: 700, committed: 200, totals: [900], opponentStack: 399)] {
            let rejected = try ResearchDecisionEngine.analyze(input, budget: budget)
            XCTAssertEqual(rejected.suggested, .call(300))
            XCTAssertTrue(rejected.betComparisons.isEmpty)
        }
    }

    func testMissingContributionOpponentStackOrExactHeadsUpNeverEnablesRaises() throws {
        let inputs = [try request(committed: nil),
                      try request(opponentStack: nil),
                      try request(opponentStack: 0),
                      try request(folded: 5),
                      try request(cards: position(["As", "Ad"], board: []))]
        for input in inputs {
            let result = try ResearchDecisionEngine.analyze(input, budget: budget)
            XCTAssertTrue(result.betComparisons.isEmpty)
            if case .raiseTo = result.suggested { XCTFail("Unproven raise context admitted") }
        }
        // Selecting a single conditional count is not independent evidence of an occluded seat folding.
        let exact = try ResearchDecisionEngine.analyze(request(folded: 5, counts: 1...1), budget: budget)
        XCTAssertNil(exact.suggested)
        XCTAssertNotNil(exact.withheldActionReason)
        XCTAssertTrue(exact.betComparisons.isEmpty)

        XCTAssertThrowsError(try ResearchDecisionEngine.analyze(request(stack: 0), budget: budget))
    }

    func testOnlyEnabledTotalsDeliveredByTheAdapterCanBecomeRecommendations() throws {
        // The adapter excludes a disabled/missing 600 button. Core must not synthesize it.
        let enabledOnly = try ResearchDecisionEngine.analyze(request(totals: [900]), budget: budget)
        XCTAssertEqual(Set(enabledOnly.betComparisons.map(\.additionalChips)), Set([700]))
        XCTAssertEqual(enabledOnly.suggested, .raiseTo(total: 900, additional: 700))

        let none = try ResearchDecisionEngine.analyze(request(totals: []), budget: budget)
        XCTAssertEqual(none.suggested, .call(300))
        XCTAssertTrue(none.betComparisons.isEmpty)

        let wrongAmountKind = ResearchDecisionRequest(position: try position(), facts: facts(),
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 300,
                           visibleBetAmounts: [900], heroStreetCommitted: 200),
            knownHeadsUpOpponentStack: 5_000)
        let wrong = try ResearchDecisionEngine.analyze(wrongAmountKind, budget: budget)
        XCTAssertEqual(wrong.suggested, .call(300))
        XCTAssertTrue(wrong.betComparisons.isEmpty)
    }

    func testLargestPossibleCountIsAConditionNotAUniformDistributionOverCounts() throws {
        let royal = try position(["2c", "3d"], board: ["Ah", "Kh", "Qh", "Jh", "Th"])
        let result = try ResearchDecisionEngine.analyze(
            request(cards: royal, call: 400, totals: [], folded: 4), budget: budget)

        // The no-future-contribution counterfactual returns 1,400/4-400 = -50.
        // That does not establish whether pending players will pay/fold, so it cannot recommend folding.
        XCTAssertNil(result.suggested)
        XCTAssertNotNil(result.withheldActionReason)
        XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
        XCTAssertEqual(result.mainOpponentCount, 3)
        XCTAssertEqual(try XCTUnwrap(result.mainEquity), 0.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.mainOutrightWinProbability), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.mainTieProbability), 1, accuracy: 1e-12)
        XCTAssertEqual(result.mainScenarios.count, 3)
        XCTAssertEqual(Set(result.mainScenarios.map(\.opponentCount)), Set([3]))
        XCTAssertTrue(result.opponentCountUncertain)
        XCTAssertTrue(result.scenarios.contains { $0.preferred == .call })
        XCTAssertTrue(result.mainScenarios.allSatisfy { abs($0.passiveValue + 50) < 1e-8 })
        XCTAssertGreaterThan(result.scenarios.map(\.passiveValue).reduce(0, +), 0)
    }

    func testEqualRangeExpectedValueCanCallDespiteOneLosingRange() throws {
        let cards = try position(["9h", "8d"], board: ["Ah", "Kd", "9s", "7c", "2d"])
        let result = try ResearchDecisionEngine.analyze(
            request(cards: cards, pot: 100_000, call: 46_000, stack: 100_000, totals: []), budget: budget)

        // Fixed counterexample: random range is favorable, value-heavy range loses.
        // Calling is profitable under equal priors, whereas maximin would fold.
        XCTAssertEqual(result.scenarios.count, 3)
        XCTAssertTrue(result.scenarios.contains { $0.passiveValue < -1_000 })
        XCTAssertGreaterThan(result.scenarios.map(\.passiveValue).reduce(0, +) / 3, 1_000)
        XCTAssertEqual(result.suggested, .call(46_000))
        XCTAssertTrue(result.modelSensitive)
        XCTAssertEqual(try XCTUnwrap(result.mainEquity),
            result.scenarios.map { $0.equity.equity }.reduce(0, +) / 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.mainOutrightWinProbability),
            result.scenarios.map { $0.equity.outrightWinProbability }.reduce(0, +) / 3, accuracy: 1e-12)
    }

    func testNineRangeResponseComparisonsUseExpectedValueInsteadOfWorstCase() throws {
        let cards = try position(["9h", "8d"], board: ["Ah", "Kd", "9s", "7c", "2d"])
        let result = try ResearchDecisionEngine.analyze(request(cards: cards, call: 600,
            committed: 100, totals: [1_300, 1_700, 2_300]), budget: budget)
        XCTAssertEqual(result.betComparisons.count, 27)
        XCTAssertEqual(result.suggested, .call(600))
        let reference = result.betComparisons.filter { $0.additionalChips == 1_200 }
        XCTAssertEqual(reference.count, 9)
        let passiveValues = reference.map(\.checkValue)
        XCTAssertLessThan(try XCTUnwrap(passiveValues.min()), -100)
        XCTAssertGreaterThan(passiveValues.reduce(0, +) / 9, 50)
        for additional in [1_200, 1_600, 2_200] {
            let group = result.betComparisons.filter { $0.additionalChips == additional }
            XCTAssertEqual(group.count, 9)
            XCTAssertEqual(Set(group.map(\.rangeAssumption)), Set(ResearchRangeAssumption.allCases))
            XCTAssertEqual(Set(group.map(\.responseAssumption)), Set(ResearchResponseAssumption.allCases))
            XCTAssertLessThan(try XCTUnwrap(group.map(\.value).min()), -100)
            XCTAssertLessThan(group.map(\.value).reduce(0, +) / 9, 0)
        }
        // All aggressive actions and the call lose in their worst model; maximin
        // chooses fold (zero). Equal model priors select the positive-value call.
        XCTAssertTrue(result.modelSensitive)
    }

    func testVisibleAllInOrUnresolvedMultiwayAllInCannotClaimFullPotEligibility() throws {
        let inputs = [try request(visibleAllIn: true),
                      try request(call: 700, stack: 700, totals: [], folded: 5)]
        for input in inputs {
            let result = try ResearchDecisionEngine.analyze(input, budget: budget)
            XCTAssertNil(result.suggested)
            XCTAssertNotNil(result.mainEquity)
            XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
            XCTAssertTrue(result.betComparisons.isEmpty)
        }
        // A still-funded HU opponent does not prove that hero's capped call covers
        // the full wager. Unmatched excess can be refunded; the ledger must verify it.
        let exact = try ResearchDecisionEngine.analyze(
            request(call: 700, stack: 700, totals: [], opponentStack: 5_000), budget: budget)
        XCTAssertNil(exact.suggested)
        XCTAssertNotNil(exact.withheldActionReason)
    }
}
