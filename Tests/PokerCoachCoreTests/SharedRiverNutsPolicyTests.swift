import XCTest
@testable import PokerCoachCore

final class SharedRiverNutsPolicyTests: XCTestCase {
    func testConstantTimeBoardGuardMatchesIndependentEnumerationOfAllHoleCombinations() throws {
        let cases: [(String, Bool)] = [
            ("AhKhQhJhTh", true), ("AcAdAhAsKc", true), ("KcKdKhKsAc", true),
            ("AhKdQsJcTh", true),
            ("9hThJhQhKh", false), ("KcKdKhKs9c", false),
            ("7h8d9sTcJh", false), ("AhKhQhJsTd", false),
            ("AhKhQhJh9h", false), ("AsAdAhKcKd", false)
        ]
        for (text, expected) in cases {
            let board = try Card.parse(text), boardValue = try HandEvaluator.evaluate(board)
            let available = Card.deck.filter { !board.contains($0) }
            var canBeBeaten = false
            for a in 0..<(available.count - 1) {
                for b in (a + 1)..<available.count {
                    if try HandEvaluator.evaluate(board + [available[a], available[b]]) > boardValue {
                        canBeBeaten = true
                    }
                }
            }
            XCTAssertEqual(!canBeBeaten, expected, text)
            XCTAssertEqual(SharedRiverNuts.isUnbeatable(board), !canBeBeaten, text)
        }
    }

    func testSharedNutsNeverFoldInDefaultProfilesWithOrWithoutRelativeFeature() throws {
        let hand = try HoleCards("2c3d"), board = try Card.parse("AhKhQhJhTh")
        let relative = try RelativeHandStrength(board: board)
        let state = try TableState(seats: [Seat(id: 0, stack: 1_000, committed: 100),
            Seat(id: 1, stack: 500, committed: 600, streetCommitted: 500, actedAtBet: 500)],
            board: board, bigBlind: 10, button: 1, currentBet: 500, lastFullRaise: 500, pending: [0])
        for feature in [StrengthFeature.value(hand: hand, board: board),
                        StrengthFeature.value(hand: hand, board: board, relative: relative)] {
            for profile in [BehaviorProfile.tight, .neutral, .loose] {
                XCTAssertEqual(profile.categoryLikelihood(action: .fold, state: state, strength: feature), 0)
                for seed: UInt64 in 0..<32 {
                    var rng = SplitMix64(state: seed)
                    XCTAssertNotEqual(profile.action(state: state, strength: feature, raiseCount: 0, rng: &rng), .fold)
                }
            }
        }
    }

    func testPlayingABeatableBoardStillAllowsFolding() throws {
        let hand = try HoleCards("2c3d")
        for text in ["7h8d9sTcJh", "KcKdKhKs9c", "AhKhQhJsTd", "AhKhQhJh9h", "AsAdAhKcKd"] {
            let board = try Card.parse(text), relative = try RelativeHandStrength(board: board)
            XCTAssertEqual(try HandEvaluator.evaluate(hand.cards + board), try HandEvaluator.evaluate(board))
            let state = try TableState(seats: [Seat(id: 0, stack: 1_000, committed: 100),
                Seat(id: 1, stack: 500, committed: 600, streetCommitted: 500, actedAtBet: 500)],
                board: board, bigBlind: 10, button: 1, currentBet: 500, lastFullRaise: 500, pending: [0])
            for feature in [StrengthFeature.value(hand: hand, board: board),
                            StrengthFeature.value(hand: hand, board: board, relative: relative)] {
                XCTAssertGreaterThan(BehaviorProfile.neutral.categoryLikelihood(action: .fold, state: state, strength: feature), 0, text)
            }
        }
    }

    func testCurrentRiverDefaultModelCannotInventProfitableRoyalBoardBluff() throws {
        let board = try Card.parse("AhKhQhJhTh")
        let state = try TableState(seats: (0..<3).map { Seat(id: $0, stack: 1_000, committed: 100) },
            board: board, bigBlind: 10, button: 2, currentBet: 0, lastFullRaise: 10, pending: [0, 1, 2])
        let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: HoleCards("2c3d"),
            ranges: [1: .parse("4c5d"), 2: .parse("6c7d")], allowedActions: [.check, .raiseTo(100), .raiseTo(1_000)],
            budget: .init(samples: 128, milliseconds: 10_000, seed: 29))
        XCTAssertTrue(result.completedBudget)
        XCTAssertEqual(result.equity.outrightWinProbability, 0)
        XCTAssertEqual(result.equity.tieProbability, 1)
        XCTAssertEqual(result.suggested, .check)
        for action in result.actions {
            XCTAssertEqual(action.expectedEV, 100, accuracy: 1e-9)
        }
    }

    func testFutureRiverSharedNutsKeepEverySeatEligibleUnderDefaultProfiles() throws {
        let turn = try Card.parse("AhKdQsJc"), complete = try Card.parse("AhKdQsJcTh")
        let initial = try TableState(seats: (0..<3).map { Seat(id: $0, stack: 1_000, committed: 100) },
            board: turn, bigBlind: 10, button: 2, currentBet: 0, lastFullRaise: 10, pending: [])
        let hands = try [0: HoleCards("2c3d"), 1: HoleCards("4c5d"), 2: HoleCards("6c7d")]
        let values = try hands.mapValues { try HandEvaluator.evaluate($0.cards + complete) }
        var sawWager = false
        for profile in [BehaviorProfile.tight, .neutral, .loose] {
            for seed: UInt64 in 0..<16 {
                var rng = SplitMix64(state: seed)
                let final = try BettingRollout.finishFutureStreets(state: initial, completeBoard: complete,
                    hands: hands, hero: 0, opponentProfile: profile, heroProfile: .neutral,
                    configuration: .fullHand, rng: &rng, checkpoint: {})
                XCTAssertEqual(final.live, [0, 1, 2])
                XCTAssertTrue(final.roundComplete)
                sawWager = sawWager || final.seats.contains { $0.streetCommitted > 0 }
                let awards = try PotSettlement.expectedAwards(seats: final.seats, values: values)
                for seat in 0..<3 {
                    XCTAssertEqual(awards[seat] - Double(final.seats[seat].committed - 100), 100, accuracy: 1e-9)
                }
            }
        }
        XCTAssertTrue(sawWager, "Exercise actual facing-bet responses, not only a checked-through river")
    }
}
