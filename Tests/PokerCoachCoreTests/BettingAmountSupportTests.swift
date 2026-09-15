import XCTest
@testable import PokerCoachCore

final class BettingAmountSupportTests: XCTestCase {
    private func facts(pot: String = "9.5", call: String = "3.2", stack: String = "52.83",
                       blue: Bool = true, folds: Int = 6) -> PublicBettingFacts {
        var raw = ["pot": pot, "call": call, "stack": stack]
        var scores = Dictionary(uniqueKeysWithValues: raw.keys.map { ($0, Float(1)) })
        for seat in 0..<folds { raw["seat.\(seat)"] = "弃牌"; scores["seat.\(seat)"] = 1 }
        return PublicBettingFacts(raw: raw, scores: scores, callControlVisible: blue)
    }
    private func equity(_ value: Double, samples: Int = 1000, confidence: [Double]? = nil) -> EquityResult {
        EquityResult(equity: value, outrightWinProbability: value, tieProbability: 0,
                     confidence95: confidence ?? [value, value], samples: samples, exact: false,
                     elapsedMilliseconds: 10, completedBudget: true)
    }

    func testRecordedCallAmountDistinguishesPotFractionFromBreakEvenEquity() throws {
        let result = BettingAmountSupport.summarize(facts: facts())
        XCTAssertEqual(result.status, .callCostKnown)
        XCTAssertEqual(result.call, 320)
        XCTAssertEqual(result.remainingStackAfterCall, 4963)
        XCTAssertEqual(try XCTUnwrap(result.callToCurrentPotRatio), 3.2 / 9.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.breakEvenEquity), 3.2 / 12.7, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.callToStackRatio), 3.2 / 52.83, accuracy: 1e-12)
        XCTAssertEqual(result.callTitle, "需补跟3.20")
        XCTAssertEqual(result.thresholdSubtitle, "需权益 25% · 摊牌假设")
        XCTAssertNil(result.conditionalShowdownValue)
    }

    func testNoConfirmedCallIsNeverInterpretedAsFreeCheck() {
        let missing = BettingAmountSupport.summarize(facts: nil)
        XCTAssertEqual(missing.status, .awaitingAmounts)
        XCTAssertNil(missing.breakEvenEquity)
        XCTAssertEqual(missing.callTitle, "金额未读清")
        XCTAssertEqual(missing.thresholdSubtitle, "仅牌面估算")
        for input in [facts(blue: false), facts(call: "0"), facts(call: "让牌"), facts(stack: "")] {
            let result = BettingAmountSupport.summarize(facts: input)
            XCTAssertEqual(result.status, .unconfirmedCall)
            XCTAssertNil(result.call)
            XCTAssertNil(result.breakEvenEquity)
            XCTAssertEqual(result.callTitle, "底池9.50")
            XCTAssertEqual(result.thresholdSubtitle, "加注未接通")
            XCTAssertTrue(result.amountDetails.contains("不能据此认定可以过牌"))
        }
    }

    func testKnownCallMayUseAllStackButDoesNotProduceARaise() {
        let result = BettingAmountSupport.summarize(facts: facts(stack: "3.2"))
        XCTAssertTrue(result.wouldUseAllKnownStack)
        XCTAssertEqual(result.remainingStackAfterCall, 0)
        XCTAssertEqual(result.callToStackRatio, 1)
        XCTAssertTrue(result.amountDetails.contains("边池"))
        XCTAssertTrue(result.limitation.contains("无法确定合法加注到多少"))
    }

    func testAllFoldedDoesNotOfferAnUnnecessaryCall() {
        let result = BettingAmountSupport.summarize(facts: facts(folds: 7))
        XCTAssertEqual(result.status, .handEnded)
        XCTAssertNil(result.call)
        XCTAssertNil(result.breakEvenEquity)
        XCTAssertEqual(result.callTitle, "等待下一手")
    }

    func testConditionalValueDeductsOnlyAdditionalCallAndUsesShareForTies() throws {
        let e = EquityResult(equity: 0.5, outrightWinProbability: 0, tieProbability: 1,
                             confidence95: [0.45, 0.55], samples: 1000, exact: false,
                             elapsedMilliseconds: 10, completedBudget: true)
        let estimate = CardEquityEstimate(maximumOpponents: 1, headsUp: e, mostOpponents: e)
        let result = try XCTUnwrap(BettingAmountSupport.summarize(facts: facts(), estimate: estimate).conditionalShowdownValue)
        XCTAssertEqual(result.minimumScenarioMean, 315, accuracy: 1e-9)
        XCTAssertEqual(result.maximumScenarioMean, 315, accuracy: 1e-9)
        XCTAssertEqual(result.minimumSamplingBound, 251.5, accuracy: 1e-9)
        XCTAssertEqual(result.maximumSamplingBound, 378.5, accuracy: 1e-9)
        XCTAssertTrue(result.explanation.contains("不能作为跟注或弃牌指令"))
    }

    func testConditionalValueIsZeroAtTheBreakEvenShare() throws {
        let threshold = 3.2 / 12.7, e = equity(threshold)
        let estimate = CardEquityEstimate(maximumOpponents: 1, headsUp: e, mostOpponents: e)
        let result = try XCTUnwrap(BettingAmountSupport.summarize(facts: facts(), estimate: estimate).conditionalShowdownValue)
        XCTAssertEqual(result.minimumScenarioMean, 0, accuracy: 1e-9)
    }

    func testMultiwayScenarioSpreadIsSeparateFromSamplingBounds() throws {
        let estimate = CardEquityEstimate(maximumOpponents: 7, headsUp: equity(0.5, confidence: [0.45, 0.55]),
                                          mostOpponents: equity(0.1, confidence: [0.07, 0.13]))
        let result = try XCTUnwrap(BettingAmountSupport.summarize(facts: facts(folds: 0), estimate: estimate).conditionalShowdownValue)
        XCTAssertEqual(result.minimumScenarioMean, -193, accuracy: 1e-9)
        XCTAssertEqual(result.maximumScenarioMean, 315, accuracy: 1e-9)
        XCTAssertEqual(result.minimumSamplingBound, -231.1, accuracy: 1e-9)
        XCTAssertEqual(result.maximumSamplingBound, 378.5, accuracy: 1e-9)
        XCTAssertEqual(result.maximumOpponents, 7)
    }

    func testMismatchedPlayerCountsAndUnreliableSamplesHaveNoConditionalValue() {
        let e = equity(0.5)
        XCTAssertNil(BettingAmountSupport.summarize(facts: facts(), estimate: .init(maximumOpponents: 7, headsUp: e, mostOpponents: e)).conditionalShowdownValue)
        for invalid in [equity(0.5, samples: 499), equity(.nan), equity(1.01),
                        equity(0.5, confidence: []), equity(0.5, confidence: [0.6, 0.7]),
                        equity(0.5, confidence: [0.4, .infinity])] {
            XCTAssertNil(BettingAmountSupport.summarize(facts: facts(), estimate: .init(maximumOpponents: 1, headsUp: invalid, mostOpponents: invalid)).conditionalShowdownValue)
        }
    }
}
