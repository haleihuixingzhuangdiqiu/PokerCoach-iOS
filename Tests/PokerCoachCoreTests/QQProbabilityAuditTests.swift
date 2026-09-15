import XCTest
@testable import PokerCoachCore

final class QQProbabilityAuditTests: XCTestCase {
    /// Reference: independent PokerKit 0.7.4, 100,000 fixed-N uniform deals,
    /// tools/audit_qq_probability_pokerkit.py, seed 620711. Different sampler/seed
    /// here; 1.5 percentage points permits sampling error in both experiments.
    func testQQAgainstOneThroughSevenRandomOpponentsMatchesIndependentOracle() throws {
        let referenceWins = [0.79738, 0.64840, 0.53478, 0.44699, 0.37837, 0.32318, 0.28084]
        let referenceEquities = [0.800265, 0.65099167, 0.53743833, 0.44983333, 0.381410, 0.32645476, 0.28424917]
        for count in 1...7 {
            let result = try EquityEngine.analyze(
                EquityRequest(hero: HoleCards("QcQh"), board: [], opponents: Array(repeating: .random, count: count)),
                budget: .init(samples: 40_000, milliseconds: 20_000, seed: UInt64(92_000 + count), exactOutcomeLimit: 0))
            XCTAssertTrue(result.completedBudget)
            XCTAssertEqual(result.outrightWinProbability, referenceWins[count - 1], accuracy: 0.015)
            XCTAssertEqual(result.equity, referenceEquities[count - 1], accuracy: 0.015)
            XCTAssertLessThan(result.outrightWinProbability, result.equity)
            print("QQ random \(count): W=\(result.outrightWinProbability), T=\(result.tieProbability), E=\(result.equity)")
        }
    }

    func testQQKnownAllInRangeAndCallCostCanJustifiablyChangeTheAction() throws {
        let hero = try HoleCards("QcQh")
        // Other seat is all-in for 280; folded chips add 170 of dead money.
        // Hero's new call costs 280; the eligible final pot is exactly 730.
        let expensive = try TableState(seats: [Seat(id: 0, stack: 4_530),
            Seat(id: 1, stack: 0, committed: 280, streetCommitted: 280, actedAtBet: 280),
            Seat(id: 2, stack: 0, committed: 170, streetCommitted: 170, folded: true)],
            board: [], bigBlind: 10, button: 2, currentBet: 280, lastFullRaise: 110, pending: [0])
        for (opponent, oracle, expected): (String, Double, PokerAction) in [
            ("AhAs", 0.184195, .fold), ("AhKh", 0.54199, .call)
        ] {
            let result = try FullHandDecisionEngine.analyze(state: expensive, hero: 0, cards: hero,
                ranges: [1: .parse(opponent)], allowedActions: [.fold, .call], profiles: [.checkCall],
                budget: .init(samples: 12_000, milliseconds: 20_000, seed: 381))
            let call = try XCTUnwrap(result.actions.first { $0.action == .call })
            XCTAssertTrue(result.completedBudget)
            XCTAssertEqual(result.equity.equity, oracle, accuracy: 0.02)
            XCTAssertEqual(call.expectedEV, result.equity.equity * 730 - 280, accuracy: 1e-8)
            XCTAssertEqual(result.suggested, expected)
        }
        // The same QQ versus the same AA can call a sufficiently low incremental price.
        let cheap = try TableState(seats: [Seat(id: 0, stack: 4_270, committed: 260, streetCommitted: 260, actedAtBet: 260),
            Seat(id: 1, stack: 0, committed: 280, streetCommitted: 280, actedAtBet: 280)],
            board: [], bigBlind: 10, button: 1, currentBet: 280, lastFullRaise: 20, pending: [0])
        let result = try FullHandDecisionEngine.analyze(state: cheap, hero: 0, cards: hero,
            ranges: [1: .parse("AhAs")], allowedActions: [.fold, .call], profiles: [.checkCall],
            budget: .init(samples: 12_000, milliseconds: 20_000, seed: 381))
        let call = try XCTUnwrap(result.actions.first { $0.action == .call })
        XCTAssertEqual(call.additionalChips, 20)
        XCTAssertEqual(call.expectedEV, result.equity.equity * 560 - 20, accuracy: 1e-8)
        XCTAssertEqual(result.suggested, .call)
    }

    func testPendingOpponentsMustPayToContinueAndCannotReceiveFreeShowdownEquity() throws {
        // A concrete six-player counterexample with the reported QQ pot/call amounts.
        // It is a constructed legal state, not a claim about unseen live seat history.
        let contributions = [0, 280, 20, 50, 100, 0]
        let seats = contributions.enumerated().map { index, contribution in
            Seat(id: index, stack: 5_000 - contribution, committed: contribution,
                 streetCommitted: contribution, actedAtBet: index == 1 ? 280 : nil)
        }
        let state = try TableState(seats: seats, board: [], bigBlind: 50, button: 2,
            currentBet: 280, lastFullRaise: 180, pending: [0, 2, 3, 4, 5], preflopMinimum: 100)
        XCTAssertEqual(state.pot, 450)
        XCTAssertEqual(state.amountToCall(0), 280)
        let result = try DecisionEngine.analyze(state: state, hero: 0, cards: HoleCards("QcQh"),
            ranges: Dictionary(uniqueKeysWithValues: (1...5).map { ($0, HandRange.random) }),
            profiles: [.checkCall], heroContinuation: .checkCall, candidateActions: [.fold, .call],
            budget: .init(samples: 4_000, milliseconds: 20_000, seed: 523))
        let call = try XCTUnwrap(result.actions.first { $0.action == .call })
        XCTAssertTrue(result.completedBudget)
        // All six match 280: 1680, NOT just existing 450 + hero's 280.
        XCTAssertEqual(call.expectedEV, result.equity.equity * 1_680 - 280, accuracy: 1e-8)
        XCTAssertEqual(call.expectedEV - (result.equity.equity * 730 - 280), result.equity.equity * 950, accuracy: 1e-8)
        XCTAssertGreaterThan(call.expectedEV, 250)
        XCTAssertEqual(result.suggested, .call)
    }
}
