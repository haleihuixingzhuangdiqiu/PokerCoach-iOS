import XCTest
@testable import PokerCoachCore

final class MainScenarioProbabilityTests: XCTestCase {
    func testMainProbabilityIsEqualModelMixtureNotBoundsMidpointOrWorstCase() {
        let result = result(scenarios: scenarios(count: 2, wins: [0.12, 0.18, 0.81]))
        XCTAssertEqual(result.mainOpponentCount, 2)
        XCTAssertEqual(result.mainOutrightWinProbability!, 0.37, accuracy: 1e-12)
        XCTAssertEqual(result.mainTieProbability!, 0.03, accuracy: 1e-12)
        XCTAssertEqual(result.mainEquity!, 0.38, accuracy: 1e-12)
        // Sensitivity bounds deliberately differ, so taking their midpoint/minimum fails.
        XCTAssertEqual(result.outrightWinProbabilityRange, [0.001, 0.999])
        XCTAssertEqual(result.winLabel, "摊牌独赢37%")
        XCTAssertFalse(result.winLabel.contains("–"))
    }

    func testUnknownCountsAreNotGivenAnInventedProbabilityDistribution() {
        let lowerCount = scenarios(count: 1, wins: [0.95, 0.96, 0.97])
        let main = scenarios(count: 3, wins: [0.12, 0.18, 0.81])
        let result = result(scenarios: [main[2], lowerCount[0], main[0], lowerCount[1], main[1], lowerCount[2]], uncertain: true)
        XCTAssertEqual(result.mainOpponentCount, 3)
        XCTAssertEqual(result.mainScenarios.map(\.opponentCount), [3, 3, 3])
        XCTAssertEqual(result.mainScenarios.map(\.assumption), ResearchRangeAssumption.allCases)
        XCTAssertEqual(result.mainOutrightWinProbability!, 0.37, accuracy: 1e-12)
        XCTAssertTrue(result.mainAssumptionLabel.contains("最多3名对手"))
        XCTAssertTrue(result.mainAssumptionLabel.contains("人数待确认"))
        XCTAssertTrue(result.mainAssumptionLabel.contains("等权，未校准"))
    }

    func testCompleteTieKeepsOutrightWinSeparateFromSplitEquity() {
        let rows = ResearchRangeAssumption.allCases.map { assumption in
            scenario(assumption: assumption, count: 1, win: 0, tie: 1, equity: 0.5)
        }
        let result = result(scenarios: rows)
        XCTAssertEqual(result.mainOutrightWinProbability, 0)
        XCTAssertEqual(result.mainTieProbability, 1)
        XCTAssertEqual(result.mainEquity, 0.5)
        XCTAssertEqual(result.winLabel, "摊牌独赢0%")
        XCTAssertFalse(result.mainAssumptionLabel.contains("人数待确认"))
    }

    func testRaiseLabelShowsStreetTotalRatherThanAdditionalCost() {
        let result = result(scenarios: scenarios(count: 1, wins: [0.5, 0.6, 0.7]),
                            action: .raiseTo(total: 1_000_000_000, additional: 12_345))
        XCTAssertEqual(result.actionLabel, "建议：加注到10000000.00")
        XCTAssertEqual(result.additionalChips, 12_345)
    }

    func testMissingOrDuplicatedMainModelDoesNotFabricateEstimate() {
        let complete = scenarios(count: 1, wins: [0.5, 0.6, 0.7])
        let partial = Array(scenarios(count: 2, wins: [0.1, 0.2, 0.3]).prefix(2))
        for rows in [[], partial, complete + partial, [complete[0], complete[0], complete[1]]] {
            let result = result(scenarios: rows)
            XCTAssertNil(result.mainOutrightWinProbability)
            XCTAssertNil(result.mainOpponentCount)
            XCTAssertEqual(result.winLabel, "赢面待估算")
        }
    }

    private func scenarios(count: Int, wins: [Double]) -> [ResearchDecisionScenario] {
        zip(ResearchRangeAssumption.allCases, wins).map { assumption, win in
            scenario(assumption: assumption, count: count, win: win, tie: 0.03,
                     equity: win + 0.03 / Double(count + 1))
        }
    }
    private func scenario(assumption: ResearchRangeAssumption, count: Int, win: Double, tie: Double,
                          equity: Double) -> ResearchDecisionScenario {
        let equity = EquityResult(equity: equity, outrightWinProbability: win, tieProbability: tie,
                                  confidence95: [0, 1], samples: 1_000, exact: false,
                                  elapsedMilliseconds: 1, completedBudget: true)
        return ResearchDecisionScenario(assumption: assumption, opponentCount: count, equity: equity,
            passiveAction: .call, additionalChips: 100, passiveValue: 0,
            passiveValueSamplingBounds: [-100, 100], preferred: .fold)
    }
    private func result(scenarios: [ResearchDecisionScenario], uncertain: Bool = false,
                        action: ResearchAction = .fold) -> ResearchDecisionResult {
        ResearchDecisionResult(suggested: action, additionalChips: action.additionalChips,
            outrightWinProbabilityRange: [0.001, 0.999], tieProbabilityRange: [0, 1], equityRange: [0, 1],
            scenarios: scenarios, betComparisons: [], modelSensitive: true,
            opponentCountUncertain: uncertain, samplingUncertain: false, reason: "test", limitations: [],
            unsupportedAggressiveAmounts: [], elapsedMilliseconds: 1)
    }
}
