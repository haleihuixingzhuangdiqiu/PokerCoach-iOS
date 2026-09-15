import XCTest
@testable import PokerCoachCore

final class ProbabilityAuditTests: XCTestCase {
    func testMixedTwoAndThreeWayTiesCannotUseHalfOfTieProbability() throws {
        let request = try EquityRequest(hero: HoleCards("AsKd"), board: Card.parse("Ac7d7hQc2s"),
            opponents: [.parse("AhKc,3c4c"), .parse("AdKh,5c6c"), .parse("QhQs,8c9c")])
        // Eight equal-weight deals: four lose to queens full; the other four return
        // shares 1/3, 1/2, 1/2 and 1. This is independent of the evaluator implementation.
        let exact = try EquityEngine.analyze(request)
        XCTAssertEqual(exact.samples, 8)
        XCTAssertEqual(exact.outrightWinProbability, 1.0 / 8, accuracy: 1e-12)
        XCTAssertEqual(exact.tieProbability, 3.0 / 8, accuracy: 1e-12)
        XCTAssertEqual(exact.equity, 7.0 / 24, accuracy: 1e-12)
        XCTAssertNotEqual(exact.equity, exact.outrightWinProbability + exact.tieProbability / 2)
        let sampled = try EquityEngine.analyze(request,
            budget: .init(samples: 40_000, milliseconds: 20_000, seed: 481, exactOutcomeLimit: 0))
        XCTAssertTrue(sampled.completedBudget)
        XCTAssertEqual(sampled.equity, 7.0 / 24, accuracy: 0.008)
        XCTAssertEqual(sampled.outrightWinProbability, 1.0 / 8, accuracy: 0.008)
        XCTAssertEqual(sampled.tieProbability, 3.0 / 8, accuracy: 0.008)
    }

    func testRoyalBoardSharesForEverySupportedPlayerCount() throws {
        let hero = try HoleCards("2c3c"), board = try Card.parse("AsKsQsJsTs")
        let available = Card.deck.filter { !hero.cards.contains($0) && !board.contains($0) }
        for opponents in 1...8 {
            let ranges = try (0..<opponents).map { index in
                try HandRange([WeightedCombo(HoleCards(available[2 * index], available[2 * index + 1]))])
            }
            let result = try EquityEngine.analyze(EquityRequest(hero: hero, board: board, opponents: ranges))
            XCTAssertEqual(result.outrightWinProbability, 0)
            XCTAssertEqual(result.tieProbability, 1)
            XCTAssertEqual(result.equity, 1 / Double(opponents + 1), accuracy: 1e-12)
        }
    }

    func testWeightedJointCollisionConditioningPreservesLegalTupleWeights() throws {
        let hero = try HoleCards("AhAd"), board = try Card.parse("2c3d7h9sJc")
        let ranges: [HandRange] = try [.parse("KhKd:3,JhJd:1"), .parse("KhQh:2,4c5c:1")]
        // KK/KQ collide. Legal unnormalized weights: KK/45=3, JJ/KQ=2, JJ/45=1.
        // AA wins only in the first legal tuple: 3/(3+2+1), not a sequentially reweighted 3/4.
        let request = try EquityRequest(hero: hero, board: board, opponents: ranges)
        let exact = try EquityEngine.analyze(request)
        XCTAssertEqual(exact.samples, 3)
        XCTAssertEqual(exact.equity, 0.5, accuracy: 1e-12)
        for opponents in [ranges, Array(ranges.reversed())] {
            let sampled = try EquityEngine.analyze(EquityRequest(hero: hero, board: board, opponents: opponents),
                budget: .init(samples: 40_000, milliseconds: 20_000, seed: 211, exactOutcomeLimit: 0))
            XCTAssertTrue(sampled.completedBudget)
            XCTAssertEqual(sampled.equity, 0.5, accuracy: 0.008)
        }
    }

    func testSampledDealsAndRunoutsNeverReuseKnownDeadOrOtherSeatCards() throws {
        let request = try EquityRequest(hero: HoleCards("As2c"), board: Card.parse("4sTs9d"),
            opponents: Array(repeating: .random, count: 7), deadCards: Card.parse("AhAd"))
        let sampler = try DealSampler(request)
        var rng = SplitMix64(state: 333), accepted = 0
        for _ in 0..<100_000 {
            guard let hands = sampler.holeDeal(&rng) else { continue }
            let board = sampler.runout(hands, &rng)
            let cards = request.hero.cards + board + request.deadCards + hands.flatMap(\.cards)
            XCTAssertEqual(board.count, 5)
            XCTAssertEqual(Array(board.prefix(3)), request.board)
            XCTAssertEqual(Set(cards).count, cards.count)
            accepted += 1
            if accepted == 2_000 { break }
        }
        XCTAssertEqual(accepted, 2_000)
    }

    func testScreenshotFlopAgainstIndependentFullRunoutEnumeration() throws {
        let hero = try HoleCards("As2c"), opponent = try HoleCards("QhQs"), board = try Card.parse("4sTs9d")
        let available = Card.deck.filter { !(hero.cards + opponent.cards + board).contains($0) }
        var wins = 0, ties = 0, outcomes = 0
        for a in 0..<(available.count - 1) { for b in (a + 1)..<available.count {
            let complete = board + [available[a], available[b]]
            let own = referenceBestFive(hero.cards + complete), other = referenceBestFive(opponent.cards + complete)
            wins += own > other ? 1 : 0
            ties += own == other ? 1 : 0
            outcomes += 1
        } }
        let exact = try EquityEngine.analyze(EquityRequest(hero: hero, board: board,
            opponents: [HandRange([WeightedCombo(opponent)])]), budget: .init(milliseconds: 20_000))
        XCTAssertEqual(outcomes, 990)
        XCTAssertTrue(exact.exact)
        XCTAssertEqual(exact.samples, outcomes)
        XCTAssertEqual(exact.outrightWinProbability, Double(wins) / Double(outcomes), accuracy: 1e-12)
        XCTAssertEqual(exact.tieProbability, Double(ties) / Double(outcomes), accuracy: 1e-12)
        XCTAssertEqual(exact.equity, (Double(wins) + Double(ties) / 2) / Double(outcomes), accuracy: 1e-12)
        print("Independent A♠2♣ vs Q♥Q♠ on 4♠T♠9♦: \(wins) wins, \(ties) ties, \(outcomes) runouts")
    }

    func testHypotheticalCallEVUsesSplitPotEquityButCannotRecommendWithoutContributionState() throws {
        let position = try LiveCardPosition(slots: ["2c", "3c", "As", "Ks", "Qs", "Js", "Ts"])
        var raw = ["pot": "10", "call": "3", "stack": "20"]
        for seat in 0..<5 { raw["seat.\(seat)"] = "弃牌" }
        let facts = PublicBettingFacts(raw: raw, scores: raw.mapValues { _ in 1 }, callControlVisible: true)
        let result = try ResearchDecisionEngine.analyze(ResearchDecisionRequest(position: position, facts: facts,
            actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 300), opponentCounts: 2...2),
            budget: .init(samplesPerScenario: 500, milliseconds: 10_000))
        XCTAssertNil(result.suggested)
        XCTAssertEqual(result.additionalChips, 0)
        XCTAssertNotNil(result.withheldActionReason)
        for scenario in result.scenarios {
            XCTAssertFalse(scenario.actionValueApplicable)
            XCTAssertEqual(scenario.equity.outrightWinProbability, 0)
            XCTAssertEqual(scenario.equity.tieProbability, 1)
            XCTAssertEqual(scenario.equity.equity, 1.0 / 3, accuracy: 1e-12)
            XCTAssertEqual(scenario.passiveValue, 1300.0 / 3 - 300, accuracy: 1e-9)
        }
        XCTAssertEqual(result.winLabel, "摊牌独赢0%")
    }

    func testConfidenceSpendingCoversAllPossibleEarlyStoppingCounts() {
        for target in [2, 3, 16, 1_000, 10_000] {
            let allowances = (2...target).map { SamplingConfidence.errorAllowance(sampleCount: $0,
                targetSamples: target, errorProbability: 0.05) }
            XCTAssertTrue(allowances.allSatisfy { $0 > 0 })
            XCTAssertEqual(allowances.reduce(0, +), 0.05, accuracy: 1e-12)
        }
        var allWins = Moments()
        for _ in 0..<1_000 { allWins.add(1) }
        let expectedWidth = 7 * log(4 / 0.025) / (3 * 999)
        XCTAssertEqual(allWins.boundedConfidence(targetSamples: 1_000)[0], 1 - expectedWidth, accuracy: 1e-12)
        // The same observed sample count is less certain when it is an early stop.
        XCTAssertLessThan(allWins.boundedConfidence(targetSamples: 2_000)[0],
                          allWins.boundedConfidence(targetSamples: 1_000)[0])
        XCTAssertEqual(Moments().boundedConfidence(targetSamples: 1_000), [0, 1])
    }

    /// Independent oracle: evaluate exactly five cards by sorting multiplicities, then
    /// enumerate all 21 five-card subsets. No production evaluator is called here.
    private func referenceBestFive(_ seven: [Card]) -> Int {
        var best = 0
        for a in 0..<6 { for b in (a + 1)..<7 {
            let cards = seven.enumerated().filter { $0.offset != a && $0.offset != b }.map(\.element)
            let ranks = cards.map(\.rank).sorted(by: >)
            let rankGroups: [Int: [Int]] = Dictionary(grouping: ranks, by: { $0 })
            let unsorted: [(rank: Int, count: Int)] = rankGroups.map { (rank: $0.key, count: $0.value.count) }
            let groups = unsorted.sorted { left, right in
                left.count == right.count ? left.rank > right.rank : left.count > right.count
            }
            let flush = Set(cards.map(\.suit)).count == 1
            let wheel = ranks == [14, 5, 4, 3, 2]
            let straight = Set(ranks).count == 5 && (ranks[0] - ranks[4] == 4 || wheel)
            let category: Int, kickers: [Int]
            if flush && straight { category = 8; kickers = [wheel ? 5 : ranks[0]] }
            else if groups[0].count == 4 { category = 7; kickers = groups.map(\.rank) }
            else if groups[0].count == 3 && groups[1].count == 2 { category = 6; kickers = groups.map(\.rank) }
            else if flush { category = 5; kickers = ranks }
            else if straight { category = 4; kickers = [wheel ? 5 : ranks[0]] }
            else if groups[0].count == 3 { category = 3; kickers = groups.map(\.rank) }
            else if groups[0].count == 2 && groups[1].count == 2 { category = 2; kickers = groups.map(\.rank) }
            else if groups[0].count == 2 { category = 1; kickers = groups.map(\.rank) }
            else { category = 0; kickers = ranks }
            let score = (category << 20) + kickers.enumerated().reduce(0) { $0 + ($1.element << (16 - 4 * $1.offset)) }
            best = max(best, score)
        } }
        return best
    }
}
