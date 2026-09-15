import XCTest
@testable import PokerCoachCore

final class CardAndRangeTests: XCTestCase {
    func testRoundTripAndInvalidInputs() throws {
        for c in Card.deck { XCTAssertEqual(try Card(c.description), c) }
        XCTAssertThrowsError(try Card("1s")); XCTAssertThrowsError(try Card(id: 52))
        XCTAssertThrowsError(try Card.parse("AsAs")); XCTAssertThrowsError(try HoleCards("As"))
        XCTAssertThrowsError(try JSONDecoder().decode(Card.self, from: Data("\"xx\"".utf8)))
    }
    func testRangeGrammarAndBlockers() throws {
        let expectations = ["AA": 6, "AKs": 4, "AKo": 12, "AK": 16, "QQ+": 18, "AJs+": 12, "99-66": 24, "random": 1326, "AsKd": 1]
        for (text, count) in expectations { XCTAssertEqual(try HandRange.parse(text).combos.count, count, text) }
        XCTAssertEqual(try HandRange.parse("AA,AA").combos.count, 6)
        XCTAssertEqual(try HandRange.parse("AA").excluding(Card.parse("As")).combos.count, 3)
        XCTAssertThrowsError(try HandRange.parse("AKs:-1")); XCTAssertThrowsError(try HandRange.parse("QQ:0"))
        XCTAssertThrowsError(try HandRange.parse("KKs")); XCTAssertThrowsError(try HandRange.parse("ATs-QQ"))
    }
    func testBayesianUpdateAndSmallSampleShrinkage() throws {
        let range = try HandRange.parse("AsAh,KsKh").observing { $0.cards.contains(try! Card("As")) ? 0.8 : 0.2 }
        XCTAssertEqual(range.combos.first { $0.hand.cards.contains(try! Card("As")) }!.weight, 0.8, accuracy: 1e-12)
        var frequency = try FrequencyEstimate(priorMean: 0.4, priorStrength: 20)
        frequency.record(opportunitySucceeded: true)
        XCTAssertEqual(frequency.mean, 9.0 / 21, accuracy: 1e-12)
        XCTAssertEqual(frequency.opportunities, 1)
        XCTAssertThrowsError(try range.observing { _ in .nan })
    }
}

final class EvaluatorTests: XCTestCase {
    func testCategoryOrderingAndKickers() throws {
        let hands = ["AsJd9h5c3s", "AsAd9h5c3s", "AsAd9h9c3s", "AsAdAh5c3s", "As2d3h4c5s", "AsJs9s5s3s", "AsAdAh5c5s", "AsAdAhAc3s", "9sTsJsQsKs"]
        let values = try hands.map { try HandEvaluator.evaluate(Card.parse($0)) }
        XCTAssertEqual(values.map(\.category), HandCategory.allCases)
        for i in 0..<8 { XCTAssertLessThan(values[i], values[i + 1]) }
        XCTAssertLessThan(try HandEvaluator.evaluate(Card.parse("As2d3h4c5s")), try HandEvaluator.evaluate(Card.parse("2s3d4h5c6s")))
        XCTAssertGreaterThan(try HandEvaluator.evaluate(Card.parse("AsAdAhKsKdKh2c")), try HandEvaluator.evaluate(Card.parse("KsKdKhQsQdAs2c")))
        XCTAssertEqual(try HandEvaluator.evaluate(Card.parse("AsKsQsJsTs2d3h")), try HandEvaluator.evaluate(Card.parse("AsKsQsJsTs8d9h")))
    }
    func testAllFiveCardCategoryCounts() throws {
        // Exhaustive 52 choose 5 audit against the standard combinatorial distribution.
        var counts = [Int](repeating: 0, count: 9)
        for a in 0..<48 { for b in (a + 1)..<49 { for c in (b + 1)..<50 { for d in (c + 1)..<51 { for e in (d + 1)..<52 {
            counts[HandEvaluator.value([Card.deck[a], Card.deck[b], Card.deck[c], Card.deck[d], Card.deck[e]]).category.rawValue] += 1
        } } } } }
        XCTAssertEqual(counts, [1302540, 1098240, 123552, 54912, 10200, 5108, 3744, 624, 40])
        XCTAssertEqual(counts.reduce(0, +), 2_598_960)
    }
    func testSevenCardsAgainstIndependentFiveCardOracle() throws {
        var rng = SplitMix64(state: 991)
        for _ in 0..<3000 {
            var deck = Card.deck
            for i in 0..<7 { deck.swapAt(i, i + rng.index(52 - i)) }
            let seven = Array(deck.prefix(7))
            var best = 0
            for a in 0..<6 { for b in (a + 1)..<7 {
                best = max(best, referenceFive(seven.enumerated().filter { $0.offset != a && $0.offset != b }.map(\.element)))
            } }
            XCTAssertEqual(HandEvaluator.value(seven).score, best)
        }
    }
    /// Deliberately different implementation: sort groups and explicitly detect five-card straights.
    private func referenceFive(_ cards: [Card]) -> Int {
        let sorted = cards.map(\.rank).sorted(by: >)
        let groups: [Int: [Int]] = Dictionary(grouping: sorted, by: { $0 })
        let unsorted: [(rank: Int, n: Int)] = groups.map { (rank: $0.key, n: $0.value.count) }
        let grouped = unsorted.sorted { a, b in a.n == b.n ? a.rank > b.rank : a.n > b.n }
        let flush = Set(cards.map(\.suit)).count == 1
        let wheel = sorted == [14, 5, 4, 3, 2]
        let straight = Set(sorted).count == 5 && (sorted[0] - sorted[4] == 4 || wheel)
        let category: Int, kickers: [Int]
        if flush && straight { category = 8; kickers = [wheel ? 5 : sorted[0]] }
        else if grouped[0].n == 4 { category = 7; kickers = grouped.map(\.rank) }
        else if grouped[0].n == 3 && grouped[1].n == 2 { category = 6; kickers = grouped.map(\.rank) }
        else if flush { category = 5; kickers = sorted }
        else if straight { category = 4; kickers = [wheel ? 5 : sorted[0]] }
        else if grouped[0].n == 3 { category = 3; kickers = grouped.map(\.rank) }
        else if grouped[0].n == 2 && grouped[1].n == 2 { category = 2; kickers = grouped.map(\.rank) }
        else if grouped[0].n == 2 { category = 1; kickers = grouped.map(\.rank) }
        else { category = 0; kickers = sorted }
        return (category << 20) + kickers.enumerated().reduce(0) { $0 + ($1.element << (16 - $1.offset * 4)) }
    }
}

final class EquityTests: XCTestCase {
    func testRiverRelativeFeatureMatchesExactUniformEquity() throws {
        let board = try Card.parse("2c3d7h9sJc"), hero = try HoleCards("AhAd")
        let relative = try RelativeHandStrength(board: board)
        let equity = try EquityEngine.analyze(EquityRequest(hero: hero, board: board, opponents: [.random]))
        XCTAssertEqual(try relative.share(for: hero), equity.equity, accuracy: 1e-12)
        let tied = try RelativeHandStrength(board: Card.parse("AsKsQsJsTs"))
        XCTAssertEqual(try tied.share(for: HoleCards("2c3d")), 0.5, accuracy: 1e-12)
    }
    func testRoyalBoardThreeWaySplitIsExact() throws {
        let request = try EquityRequest(hero: HoleCards("2c3c"), board: Card.parse("AsKsQsJsTs"), opponents: [.parse("4c5c"), .parse("6c7c")])
        let result = try EquityEngine.analyze(request)
        XCTAssertTrue(result.exact); XCTAssertEqual(result.equity, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(result.tieProbability, 1); XCTAssertEqual(result.outrightWinProbability, 0)
    }
    func testTurnExactSixOuts() throws {
        let request = try EquityRequest(hero: HoleCards("2c2d"), board: Card.parse("3c4d5h9s"), opponents: [.parse("AcAd")])
        let result = try EquityEngine.analyze(request)
        // Remaining two aces make hero wheel; a deuce makes villain wheel. Four sixes make hero 2–6 straight.
        XCTAssertEqual(result.samples, 44)
        XCTAssertEqual(result.equity, 6.0 / 44, accuracy: 1e-12)
    }
    func testWeightedRiverAndBlockers() throws {
        let request = try EquityRequest(hero: HoleCards("AhAd"), board: Card.parse("2c3d7h9sJc"), opponents: [.parse("KhKd:3,JhJd:1")])
        let result = try EquityEngine.analyze(request)
        XCTAssertTrue(result.exact); XCTAssertEqual(result.equity, 0.75, accuracy: 1e-12)
        XCTAssertThrowsError(try EquityEngine.analyze(EquityRequest(hero: HoleCards("AhAd"), board: Card.parse("2c3d7h9sJc"), opponents: [.parse("AhKh")])))
    }
    func testJointCollisionConditioningAndSeatPermutation() throws {
        let request = try EquityRequest(hero: HoleCards("AhAd"), board: Card.parse("2c3d7h9sJc"),
                                        opponents: [.parse("KhKd,JhJd"), .parse("KhQh,4c5c")])
        let exact = try EquityEngine.analyze(request)
        XCTAssertEqual(exact.samples, 3)
        XCTAssertEqual(exact.equity, 1.0 / 3, accuracy: 1e-12)
        let mc = try EquityEngine.analyze(request, budget: .init(samples: 30_000, milliseconds: 10_000, exactOutcomeLimit: 0))
        XCTAssertEqual(mc.equity, exact.equity, accuracy: 0.015)
        let swapped = try EquityEngine.analyze(EquityRequest(hero: request.hero, board: request.board, opponents: request.opponents.reversed()))
        XCTAssertEqual(swapped.equity, exact.equity, accuracy: 1e-12)
    }
    func testImpossibleJointRangesAndCancellation() throws {
        let r = try EquityRequest(hero: HoleCards("AsAh"), board: Card.parse("2c3d7h9sJc"), opponents: [.parse("KsKh"), .parse("KsQh")])
        XCTAssertThrowsError(try EquityEngine.analyze(r))
        let valid = try EquityRequest(hero: HoleCards("AsAh"), board: [], opponents: [.random])
        XCTAssertThrowsError(try EquityEngine.analyze(valid, isCancelled: { true })) { XCTAssertEqual($0 as? PokerError, .cancelled) }
        XCTAssertThrowsError(try EquityEngine.analyze(valid, budget: .init(samples: 0)))
    }
    func testMonteCarloDeterminismAndNonzeroIntervalAtBoundary() throws {
        let r = try EquityRequest(hero: HoleCards("AsKs"), board: Card.parse("QsJsTs"), opponents: [.random, .random])
        let budget = ComputeBudget(samples: 2000, milliseconds: 10_000, exactOutcomeLimit: 0)
        let a = try EquityEngine.analyze(r, budget: budget), b = try EquityEngine.analyze(r, budget: budget)
        XCTAssertEqual(a.equity, 1); XCTAssertEqual(a.equity, b.equity); XCTAssertEqual(a.samples, 2000)
        XCTAssertLessThan(a.confidence95[0], 1); XCTAssertEqual(a.confidence95[1], 1)
    }
}

final class BettingTests: XCTestCase {
    func testRaiseToAmountAndPotFraction() throws {
        let t = try table()
        XCTAssertEqual(t.amountToCall(0), 100)
        XCTAssertTrue(t.legalActions().contains(.raiseTo(350))) // pot 400, call 100, half-pot raise by 250.
        let next = try t.applying(.raiseTo(350))
        XCTAssertEqual(next.seats[0].committed, 450); XCTAssertEqual(next.lastFullRaise, 250)
        XCTAssertThrowsError(try t.applying(.check)); XCTAssertThrowsError(try t.applying(.raiseTo(150)))
    }
    func testShortAllInDoesNotReopenButCumulativeDoes() throws {
        let seats = [Seat(id: 0, stack: 400, committed: 100, streetCommitted: 100, actedAtBet: 100),
                     Seat(id: 1, stack: 50, committed: 100, streetCommitted: 100),
                     Seat(id: 2, stack: 100, committed: 100, streetCommitted: 100),
                     Seat(id: 3, stack: 400, committed: 100, streetCommitted: 100)]
        let t = try TableState(seats: seats, board: Card.parse("2c3d7h"), bigBlind: 50, button: 0, currentBet: 100, lastFullRaise: 100, pending: [1, 2, 3])
        let short = try t.applying(.raiseTo(150))
        XCTAssertFalse(short.mayRaise(0)); XCTAssertTrue(short.mayRaise(2))
        let cumulative = try short.applying(.raiseTo(200))
        XCTAssertTrue(cumulative.mayRaise(0)); XCTAssertEqual(cumulative.lastFullRaise, 100)
    }
    func testCheckThenIncompleteOpeningBetAllowsRaise() throws {
        let t = try TableState(seats: [Seat(id: 0, stack: 500, actedAtBet: 0), Seat(id: 1, stack: 5), Seat(id: 2, stack: 500)],
                               board: Card.parse("2c3d7h"), bigBlind: 10, button: 2, currentBet: 0, lastFullRaise: 10, pending: [1, 2])
        let short = try t.applying(.raiseTo(5))
        XCTAssertEqual(short.minimumRaiseTo, 15); XCTAssertTrue(short.mayRaise(0))
    }
    func testSidePotsDeadMoneyUncalledRefundAndOddChips() throws {
        let seats = [Seat(id: 0, stack: 0, committed: 50), Seat(id: 1, stack: 0, committed: 100), Seat(id: 2, stack: 0, committed: 200), Seat(id: 3, stack: 0, committed: 100, folded: true)]
        let values = [0: try HandEvaluator.evaluate(Card.parse("AsKsQsJsTs")), 1: try HandEvaluator.evaluate(Card.parse("AcAdAhAs2c")), 2: try HandEvaluator.evaluate(Card.parse("2c3d4h5s6c"))]
        let awards = try PotSettlement.expectedAwards(seats: seats, values: values)
        XCTAssertEqual(awards, [200, 150, 100, 0]); XCTAssertEqual(awards.reduce(0, +), 450)
        let equal = [Seat(id: 0, stack: 0, committed: 5), Seat(id: 1, stack: 0, committed: 5), Seat(id: 2, stack: 0, committed: 5, folded: true)]
        XCTAssertEqual(try PotSettlement.integerAwards(seats: equal, values: [0: values[0]!, 1: values[0]!], button: 0), [7, 8, 0])
    }
    func testRandomLegalRoundsConserveChipsAndFinish() throws {
        var rng = SplitMix64(state: 43)
        for _ in 0..<500 {
            let n = 2 + rng.index(8)
            var t = try TableState(seats: (0..<n).map { Seat(id: $0, stack: 1 + rng.index(1000), committed: 10) },
                                   board: Card.parse("2c3d7h"), bigBlind: 10, button: n - 1, currentBet: 0, lastFullRaise: 10, pending: Array(0..<n))
            let total = t.seats.reduce(0) { $0 + $1.stack + $1.committed }
            var steps = 0
            while !t.roundComplete {
                let legal = t.legalActions()
                XCTAssertFalse(legal.isEmpty)
                t = try t.applying(legal[rng.index(legal.count)])
                try t.validate()
                XCTAssertEqual(t.seats.reduce(0) { $0 + $1.stack + $1.committed }, total)
                steps += 1; XCTAssertLessThan(steps, 1000)
            }
        }
    }
    func testStreetAndMissingActorValidation() throws {
        var t = try table()
        while !t.roundComplete { t = try t.applying(t.amountToCall(t.actor!) == 0 ? .check : .call) }
        let next = try t.advancing(to: Card.parse("2c3d7h9s"))
        XCTAssertEqual(next.currentBet, 0); XCTAssertTrue(next.seats.allSatisfy { $0.streetCommitted == 0 })
        XCTAssertThrowsError(try table().advancing(to: Card.parse("2c3d7h9s")))
        var invalid = try table(); invalid.pending = []
        XCTAssertThrowsError(try invalid.validate())
    }
    func table() throws -> TableState {
        try TableState(seats: [Seat(id: 0, stack: 900, committed: 100), Seat(id: 1, stack: 800, committed: 200, streetCommitted: 100, actedAtBet: 100), Seat(id: 2, stack: 900, committed: 100)],
                       board: Card.parse("2c3d7h"), bigBlind: 10, button: 2, currentBet: 100, lastFullRaise: 100, pending: [0, 2])
    }
}

final class DecisionAndObservationTests: XCTestCase {
    func testRepeatedCaptureCannotPretendToBeTwoStableFrames() throws {
        let (state, cards) = try river()
        let table = RecognizedTable(tableID: "t", handID: "h", state: state, hero: 0, holeCards: cards, historyComplete: true)
        var gate = ObservationGate()
        for seq: UInt64 in [1, 2] { gate.ingest(FrameObservation(sequence: seq, capturedAt: 10, table: table, criticalConfidence: 1), now: 10.1) }
        XCTAssertNil(gate.ticket)
        gate.ingest(FrameObservation(sequence: 3, capturedAt: 10.2, table: table, criticalConfidence: 1), now: 10.2)
        XCTAssertNotNil(gate.ticket)
    }
    func river(_ own: String = "AsKs") throws -> (TableState, HoleCards) {
        let t = try TableState(seats: [Seat(id: 0, stack: 400, committed: 100), Seat(id: 1, stack: 300, committed: 200, streetCommitted: 100, actedAtBet: 100)],
                               board: Card.parse("QsJsTs2d3h"), bigBlind: 10, button: 0, currentBet: 100, lastFullRaise: 100, pending: [0])
        return (t, try HoleCards(own))
    }
    func testRiverNutsAndExactPolicyPayoffs() throws {
        let (state, cards) = try river()
        let result = try DecisionEngine.analyze(state: state, hero: 0, cards: cards, ranges: [1: .parse("AhAd")], profiles: [.checkCall], budget: .init(samples: 600, milliseconds: 10_000))
        XCTAssertEqual(result.equity.equity, 1)
        XCTAssertEqual(result.suggested, .raiseTo(400))
        XCTAssertEqual(result.actions.first { $0.action == .call }!.worstScenarioEV, 300, accuracy: 1e-10)
        XCTAssertEqual(result.actions.first { $0.action == .raiseTo(400) }!.worstScenarioEV, 600, accuracy: 1e-10)
        XCTAssertEqual(result.actions.first { $0.action == .fold }!.worstScenarioEV, 0)
    }
    func testRiverDeadHandChoosesFoldAgainstCaller() throws {
        let (state, cards) = try river("4c5c")
        let r = try DecisionEngine.analyze(state: state, hero: 0, cards: cards, ranges: [1: .parse("AhAd")], profiles: [.checkCall], budget: .init(samples: 600, milliseconds: 10_000))
        XCTAssertEqual(r.suggested, .fold)
        XCTAssertEqual(r.actions.first { $0.action == .call }!.worstScenarioEV, -100)
    }
    func testStabilityAndImmediateInvalidation() throws {
        let (state, cards) = try river()
        let table = RecognizedTable(tableID: "test", handID: "h1", state: state, hero: 0, holeCards: cards, historyComplete: true)
        var gate = ObservationGate()
        gate.ingest(FrameObservation(sequence: 1, capturedAt: 10, table: table, criticalConfidence: 0.99), now: 10)
        XCTAssertNil(gate.ticket)
        gate.ingest(FrameObservation(sequence: 2, capturedAt: 10.1, table: table, criticalConfidence: 0.99), now: 10.1)
        let ticket = try XCTUnwrap(gate.ticket)
        XCTAssertTrue(gate.accepts(ticket, now: 10.2))
        gate.ingest(FrameObservation(sequence: 3, capturedAt: 10.3, table: nil, criticalConfidence: 0.5), now: 10.3)
        XCTAssertFalse(gate.accepts(ticket, now: 10.3)); XCTAssertEqual(gate.status, .unstable)
    }
    func testStaleHistoryOutOfOrderAndNewHand() throws {
        let (state, cards) = try river()
        let table = RecognizedTable(tableID: "test", handID: "h1", state: state, hero: 0, holeCards: cards, historyComplete: false)
        var gate = ObservationGate()
        for seq: UInt64 in [1, 2] { let time = 10 + Double(seq) * 0.1; gate.ingest(FrameObservation(sequence: seq, capturedAt: time, table: table, criticalConfidence: 1), now: time) }
        XCTAssertEqual(gate.status, .incompleteHistory); XCTAssertNil(gate.ticket)
        gate.expire(now: 11); XCTAssertEqual(gate.status, .stale)
        gate.reset()
        let complete = RecognizedTable(tableID: "test", handID: "h2", state: state, hero: 0, holeCards: cards, historyComplete: true)
        for seq: UInt64 in [1, 2] { let time = 20 + Double(seq) * 0.1; gate.ingest(FrameObservation(sequence: seq, capturedAt: time, table: complete, criticalConfidence: 1), now: time) }
        let ticket = try XCTUnwrap(gate.ticket)
        gate.ingest(FrameObservation(sequence: 1, capturedAt: 19, table: nil, criticalConfidence: 0), now: 20.2)
        XCTAssertEqual(gate.ticket, ticket)
        XCTAssertFalse(gate.accepts(ticket, now: 21))
    }
}
