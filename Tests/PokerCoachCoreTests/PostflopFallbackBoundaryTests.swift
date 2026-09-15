import XCTest
@testable import PokerCoachCore

final class PostflopFallbackBoundaryTests: XCTestCase {
    private let budget = ResearchDecisionBudget(samplesPerScenario: 500, milliseconds: 10_000)
    private func request(board: [String], call: String? = "3", folds: Int = 5,
                         counts: ClosedRange<Int>? = nil, allIn: Bool = false) throws -> ResearchDecisionRequest {
        var raw = ["pot": "10", "stack": "20"]
        if let call { raw["call"] = call } else { raw["settled"] = "10" }
        if allIn { raw["allin.visible"] = "true" }
        for seat in 0..<folds { raw["seat.\(seat)"] = "弃牌" }
        let facts = PublicBettingFacts(raw: raw, scores: raw.mapValues { _ in Float(1) }, callControlVisible: call != nil)
        return ResearchDecisionRequest(
            position: try LiveCardPosition(slots: ["Ah", "Th"] + board.map(Optional.some) + Array(repeating: nil, count: 5 - board.count)),
            facts: facts, actions: .init(heroTurnConfirmed: true, foldAvailable: true, checkAvailable: call == nil,
                callAmount: facts.call, visibleBetAmounts: call == nil ? [100, 200] : [],
                heroStreetCommitted: 0, visibleRaiseToAmounts: call == nil ? [] : [700, 900]),
            opponentCounts: counts, knownHeadsUpOpponentStack: 2_000)
    }

    func testFlopTurnAndRiverMultiwayCallsCannotAssumeFreePendingResponsesEvenWithNuts() throws {
        for board in [["Kh", "Qh", "Jh"], ["Kh", "Qh", "Jh", "2c"], ["Kh", "Qh", "Jh", "2c", "3d"]] {
            let result = try ResearchDecisionEngine.analyze(request(board: board), budget: budget)
            XCTAssertEqual(result.mainOutrightWinProbability, 1)
            XCTAssertNil(result.suggested)
            XCTAssertNotNil(result.withheldActionReason)
            XCTAssertTrue(result.betComparisons.isEmpty)
            XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
        }
    }

    func testArbitrarySingleCountDoesNotAuthorizeMultiwayOpeningBetsOrRaises() throws {
        let board = ["Kh", "Qh", "Jh"]
        let facingBet = try ResearchDecisionEngine.analyze(request(board: board, counts: 1...1), budget: budget)
        XCTAssertNil(facingBet.suggested)
        XCTAssertTrue(facingBet.betComparisons.isEmpty)
        let freeCheck = try ResearchDecisionEngine.analyze(request(board: board, call: nil, counts: 1...1), budget: budget)
        XCTAssertEqual(freeCheck.suggested, .check)
        XCTAssertTrue(freeCheck.betComparisons.isEmpty)
        XCTAssertEqual(freeCheck.unsupportedAggressiveAmounts, [100, 200])
        XCTAssertTrue(freeCheck.scenarios.allSatisfy { !$0.actionValueApplicable })
    }

    func testKnownAllInCannotEnableOpeningBetsEvenWithAnApparentlyFundedOpponentRead() throws {
        let result = try ResearchDecisionEngine.analyze(
            request(board: ["Kh", "Qh", "Jh"], call: nil, folds: 6, allIn: true), budget: budget)
        XCTAssertEqual(result.suggested, .check)
        XCTAssertTrue(result.betComparisons.isEmpty)
        XCTAssertEqual(result.unsupportedAggressiveAmounts, [100, 200])
        XCTAssertTrue(result.scenarios.allSatisfy { !$0.actionValueApplicable })
    }
}
