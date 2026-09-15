import XCTest
@testable import PokerCoachCore

final class PreflopFallbackBoundaryTests: XCTestCase {
    private let budget = ResearchDecisionBudget(samplesPerScenario: 1_000, milliseconds: 10_000)
    private func request(_ cards: [String] = ["Qc", "Qh"], pot: String = "4.50", call: String? = "2.80",
                         stack: String = "45.30", folds: Int = 2, counts: ClosedRange<Int>? = nil,
                         allIn: Bool = false) throws -> ResearchDecisionRequest {
        var raw = ["pot": pot, "stack": stack]
        if let call { raw["call"] = call }
        if allIn { raw["allin.visible"] = "true" }
        for seat in 0..<folds { raw["seat.\(seat)"] = "弃牌" }
        let facts = PublicBettingFacts(raw: raw, scores: raw.mapValues { _ in Float(1) }, callControlVisible: call != nil)
        return ResearchDecisionRequest(position: try LiveCardPosition(slots: cards.map(Optional.some) + Array(repeating: nil, count: 5)),
            facts: facts, actions: .init(heroTurnConfirmed: true, foldAvailable: true,
                checkAvailable: call == nil, callAmount: facts.call, heroStreetCommitted: 0,
                visibleRaiseToAmounts: [520, 650, 770, 1_000, 1_200]), opponentCounts: counts)
    }

    func testReportedQQKeepsConditionalProbabilityButDoesNotRecommendFreeOpponentFold() throws {
        let result = try ResearchDecisionEngine.analyze(request(), budget: budget)
        XCTAssertNil(result.suggested)
        XCTAssertEqual(result.additionalChips, 0)
        XCTAssertNotNil(result.mainOutrightWinProbability)
        XCTAssertEqual(result.mainOpponentCount, 5)
        XCTAssertEqual(result.scenarios.count, 15)
        XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
        XCTAssertEqual(result.actionLabel, "正在核对下注状态")
        XCTAssertTrue(result.guidanceSubtitle.contains("摊牌独赢"))
        XCTAssertTrue(result.strategySummary.contains("暂不判断跟弃"))
        XCTAssertTrue(result.reason.contains("未跟齐玩家仍需跟注或弃牌"))
        XCTAssertEqual(result.unsupportedRaiseToAmounts, [520, 650, 770, 1_000, 1_200])
    }

    func testBoundaryAppliesToPremiumAndWeakHandsAndBothSignsOfCounterfactualEV() throws {
        for input in [try request(["As", "Ah"], pot: "10", call: "0.10"),
                      try request(["7c", "2h"], pot: "3", call: "3")] {
            let result = try ResearchDecisionEngine.analyze(input, budget: budget)
            XCTAssertNil(result.suggested)
            XCTAssertNotNil(result.withheldActionReason)
            XCTAssertNotNil(result.mainEquity)
            XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
        }
    }

    func testSpecifyingOneOpponentDoesNotReplaceObservedFoldEvidence() throws {
        let result = try ResearchDecisionEngine.analyze(request(counts: 1...1), budget: budget)
        XCTAssertEqual(result.mainOpponentCount, 1)
        XCTAssertNil(result.suggested)
        XCTAssertNotNil(result.withheldActionReason)
    }

    func testVerifiedNonCappedHeadsUpRetainsCallOrFoldAccordingToModel() throws {
        for (cards, expected): ([String], ResearchAction) in [(["Qc", "Qh"], .call(280)), (["7c", "2h"], .fold)] {
            let result = try ResearchDecisionEngine.analyze(request(cards, folds: 6), budget: budget)
            XCTAssertEqual(result.suggested, expected)
            XCTAssertNil(result.withheldActionReason)
            XCTAssertTrue(result.scenarios.allSatisfy(\.actionValueApplicable))
            for scenario in result.scenarios {
                XCTAssertEqual(scenario.passiveValue, scenario.equity.equity * 730 - 280, accuracy: 1e-8)
            }
        }
    }

    func testCappedHeadsUpAndVisibleAllInRetainProbabilityWithoutInventingPotEligibility() throws {
        for input in [try request(stack: "2.80", folds: 6), try request(folds: 6, allIn: true)] {
            let result = try ResearchDecisionEngine.analyze(input, budget: budget)
            XCTAssertNil(result.suggested)
            XCTAssertNotNil(result.mainEquity)
            XCTAssertTrue(result.withheldActionReason?.contains("实际可争夺底池") == true)
            XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
        }
    }

    func testObservedFreeCheckRemainsAvailableWithoutClaimingRaiseOptimality() throws {
        let result = try ResearchDecisionEngine.analyze(request(call: nil), budget: budget)
        XCTAssertEqual(result.suggested, .check)
        XCTAssertNil(result.withheldActionReason)
        XCTAssertNotNil(result.mainOutrightWinProbability)
        XCTAssertTrue(result.reason.contains("下注金额尚未比较"))
    }
}
