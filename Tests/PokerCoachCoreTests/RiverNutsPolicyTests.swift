import XCTest
@testable import PokerCoachCore

final class RiverNutsPolicyTests: XCTestCase {
    private let nuts = [
        ("AsKd", "QhJsTc2d3c"), // private Broadway, no boat or flush possible
        ("As2s", "KsQs8s4d3h"), // private ace-high flush, no straight flush possible
        ("7h7d", "7s7cAhKd2c"), // private quads
        ("AhKh", "QcQdQhQs2c"), // public quads, private top kicker
        ("AhKh", "QhJhTh2c3d")  // private royal
    ]
    private let beatable = [
        ("AsKd", "QhJhTh2d3c"), // Broadway can lose to a flush
        ("AsKd", "QhQsJcTd3c"), // Broadway can lose to a boat/quads
        ("As2s", "QsJs9s4d3h"), // ace-high flush can lose to KsTs straight flush
        ("Qs2s", "KsJs8s4d3h"), // king-high flush can lose to an ace-high flush
        ("2c2d", "2h2s9c9dAh"), // private quads can lose to higher quads
        ("Kh2h", "QcQdQhQs3c"), // public quads, non-nut private kicker
        ("6c7d", "8h9sTc2dAh")  // ten-high straight can lose to QJ
    ]

    private func facingBet(board: [Card]) throws -> TableState {
        try TableState(seats: [Seat(id: 0, stack: 3_000, committed: 1_000),
            Seat(id: 1, stack: 2_000, committed: 2_000, streetCommitted: 1_000, actedAtBet: 1_000)],
            board: board, bigBlind: 10, button: 1, currentBet: 1_000,
            lastFullRaise: 1_000, pending: [0])
    }

    // Exhaustive opponent holdings validate the inexpensive sufficient guard.
    // This shares the production hand evaluator and is not an independent evaluator oracle.
    func testSufficientGuardAgainstEveryLegalOpponentHolding() throws {
        for (pairs, expected) in [(nuts, true), (beatable, false)] {
            for (holeText, boardText) in pairs {
                let hand = try HoleCards(holeText), board = try Card.parse(boardText)
                let own = try HandEvaluator.evaluate(hand.cards + board)
                let available = Card.deck.filter { !(hand.cards + board).contains($0) }
                var stronger = 0
                for a in 0..<(available.count - 1) {
                    for b in (a + 1)..<available.count {
                        if try HandEvaluator.evaluate(board + [available[a], available[b]]) > own { stronger += 1 }
                    }
                }
                XCTAssertEqual(stronger == 0, expected, "\(holeText) / \(boardText)")
                XCTAssertEqual(RiverNutsPolicyGuard.isCertainlyUnbeatable(hand: hand, board: board, value: own), expected)
            }
        }
    }

    func testCurrentAndFutureRiverFeaturesNeverFoldCoveredPrivateNuts() throws {
        for (holeText, boardText) in nuts {
            let hand = try HoleCards(holeText), board = try Card.parse(boardText)
            let state = try facingBet(board: board), relative = try RelativeHandStrength(board: board)
            for feature in [StrengthFeature.value(hand: hand, board: board),
                            StrengthFeature.value(hand: hand, board: board, relative: relative)] {
                for profile in [BehaviorProfile.tight, .neutral, .loose] {
                    XCTAssertEqual(profile.categoryLikelihood(action: .fold, state: state, strength: feature), 0)
                    // Seed 23 folded Broadway before this correction: u=.90954,
                    // tight continuation=.90065 with cost=1000, pot=3000.
                    for seed: UInt64 in 0..<64 {
                        var rng = SplitMix64(state: seed)
                        XCTAssertNotEqual(profile.action(state: state, strength: feature, raiseCount: 0, rng: &rng), .fold)
                    }
                }
            }
        }
    }

    func testGuardDoesNotProtectBeatableHandsOrEarlierStreets() throws {
        for (holeText, boardText) in beatable {
            let hand = try HoleCards(holeText), board = try Card.parse(boardText)
            let feature = StrengthFeature.value(hand: hand, board: board)
            let state = try facingBet(board: board)
            XCTAssertGreaterThan(BehaviorProfile.tight.categoryLikelihood(action: .fold,
                state: state, strength: feature), 0)
        }
        let hand = try HoleCards("AsKd"), turn = try Card.parse("QhJsTc2d")
        XCTAssertLessThan(StrengthFeature.value(hand: hand, board: turn), 0.99,
                          "A future river must not enter the current-street nuts guard")
    }

    func testActualFutureRiverRolloutKeepsPrivateNutsEligible() throws {
        let turn = try Card.parse("QhJsTc2d"), board = try Card.parse("QhJsTc2d3c")
        let initial = try TableState(seats: (0..<3).map { Seat(id: $0, stack: 3_000, committed: 1_000) },
            board: turn, bigBlind: 10, button: 0, currentBet: 0, lastFullRaise: 10, pending: [])
        let hands = try [0: HoleCards("AsKd"), 1: HoleCards("QdQc"), 2: HoleCards("JhJc")]
        var sawContributionsFromOtherSeats = false
        for profile in [BehaviorProfile.tight, .neutral, .loose] {
            for seed: UInt64 in 0..<128 {
                var rng = SplitMix64(state: seed)
                let final = try BettingRollout.finishFutureStreets(state: initial, completeBoard: board,
                    hands: hands, hero: 0, opponentProfile: profile, heroProfile: .tight,
                    configuration: .fullHand, rng: &rng, checkpoint: {})
                XCTAssertFalse(final.seats[0].folded, "private nuts folded with seed \(seed)")
                XCTAssertTrue(final.roundComplete)
                sawContributionsFromOtherSeats = sawContributionsFromOtherSeats || final.seats.dropFirst().contains { $0.streetCommitted > 0 }
            }
        }
        XCTAssertTrue(sawContributionsFromOtherSeats)
    }

    func testCurrentRiverBluffCannotMakeCoveredPrivateNutsFold() throws {
        let board = try Card.parse("QhJsTc2d3c")
        let state = try TableState(seats: (0..<2).map { Seat(id: $0, stack: 3_000, committed: 1_000) },
            board: board, bigBlind: 10, button: 1, currentBet: 0, lastFullRaise: 10, pending: [0, 1])
        let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: HoleCards("QdQc"),
            ranges: [1: .parse("AsKd")], allowedActions: [.check, .raiseTo(3_000)],
            budget: .init(samples: 128, milliseconds: 10_000, seed: 23))
        XCTAssertEqual(result.equity.outrightWinProbability, 0)
        XCTAssertEqual(result.equity.tieProbability, 0)
        let shove = try XCTUnwrap(result.actions.first(where: { $0.action == .raiseTo(3_000) }))
        XCTAssertEqual(shove.expectedEV, -3_000, accuracy: 1e-9)
        XCTAssertEqual(result.suggested, .check)
    }
}
