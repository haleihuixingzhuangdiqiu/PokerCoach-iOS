import Foundation

// Independent PCG32 truth generator; production uses SplitMix64. No private data.
private struct TruthGenerator {
    private var state: UInt64 = 0
    private let increment: UInt64 = 0xDA3E39CB94B95BDB
    init(seed: UInt64) { _ = next(); state &+= seed; _ = next() }
    mutating func next() -> UInt32 {
        let old = state
        state = old &* 6364136223846793005 &+ increment
        let x = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let r = UInt32(old >> 59)
        return (x >> r) | (x << ((0 &- r) & 31))
    }
    mutating func index(_ count: Int) -> Int {
        let bound = UInt32(count), threshold = (0 &- bound) % bound
        while true { let x = next(); if x >= threshold { return Int(x % bound) } }
    }
    mutating func deal(_ count: Int) -> [Card] {
        var deck = Card.deck
        for i in 0..<count { deck.swapAt(i, i + index(deck.count - i)) }
        return Array(deck.prefix(count))
    }
}

// A deliberately separate 5-card evaluator. Seven cards are evaluated by all 21
// subsets; no production evaluator, rank bitmasks, sampler, or share routine is used.
private enum Oracle {
    static func five(_ cards: [Card]) -> Int {
        let ranks = cards.map(\.rank).sorted(by: >)
        let flush = cards.allSatisfy { $0.suit == cards[0].suit }
        let unique = Array(Set(ranks)).sorted(by: >)
        let straight: Int = unique.count == 5
            ? (unique[0] - unique[4] == 4 ? unique[0] : (unique == [14, 5, 4, 3, 2] ? 5 : 0)) : 0
        var counts: [Int: Int] = [:]
        for rank in ranks { counts[rank, default: 0] += 1 }
        let groups = counts.map { (rank: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.rank > $1.rank }
        let category: Int, kickers: [Int]
        if flush && straight > 0 { category = 8; kickers = [straight] }
        else if groups[0].count == 4 { category = 7; kickers = groups.map(\.rank) }
        else if groups[0].count == 3 && groups[1].count == 2 { category = 6; kickers = groups.map(\.rank) }
        else if flush { category = 5; kickers = ranks }
        else if straight > 0 { category = 4; kickers = [straight] }
        else if groups[0].count == 3 { category = 3; kickers = groups.map(\.rank) }
        else if groups[0].count == 2 && groups[1].count == 2 { category = 2; kickers = groups.map(\.rank) }
        else if groups[0].count == 2 { category = 1; kickers = groups.map(\.rank) }
        else { category = 0; kickers = ranks }
        return (kickers + Array(repeating: 0, count: 5 - kickers.count)).reduce(category) { $0 * 15 + $1 }
    }
    static func seven(_ cards: [Card]) -> Int {
        precondition(cards.count == 7 && Set(cards).count == 7)
        var best = 0
        for a in 0..<3 { for b in (a + 1)..<4 { for c in (b + 1)..<5 {
            for d in (c + 1)..<6 { for e in (d + 1)..<7 {
                best = max(best, five([cards[a], cards[b], cards[c], cards[d], cards[e]]))
            } }
        } } }
        return best
    }
    static func labels(hero: [Card], others: [[Card]], board: [Card]) -> [Double] {
        let own = seven(hero + board), scores = others.map { seven($0 + board) }
        if scores.contains(where: { $0 > own }) { return [0, 0, 0] }
        let tied = scores.filter { $0 == own }.count
        return tied == 0 ? [1, 0, 1] : [0, 1, 1 / Double(tied + 1)]
    }
}

private struct CaseResult {
    let players: Int
    let street: String
    let predicted: [Double]
    let observed: [Double]
    let samples: Int
}

private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
private func variance(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let average = mean(values)
    return values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count - 1)
}
private func interval(_ values: [Double], bounded: Bool = false) -> [Double] {
    let average = mean(values), width = 1.96 * sqrt(variance(values) / Double(values.count))
    return bounded ? [max(0, average - width), min(1, average + width)] : [average - width, average + width]
}
private func wilson(_ outcomes: [Double]) -> [Double] {
    let n = Double(outcomes.count), p = mean(outcomes), z2 = 1.96 * 1.96
    let center = (p + z2 / (2 * n)) / (1 + z2 / n)
    let width = 1.96 * sqrt((p * (1 - p) + z2 / (4 * n)) / n) / (1 + z2 / n)
    return [max(0, center - width), min(1, center + width)]
}
private let metricNames = ["outright_win", "tie", "pot_share_equity"]
private func summarize(_ rows: [CaseResult], bins: Bool, familywiseComparisons: Int? = nil) -> [String: Any] {
    var metrics: [String: Any] = [:]
    for index in 0..<3 {
        let predictions = rows.map { $0.predicted[index] }, observations = rows.map { $0.observed[index] }
        let errors = zip(predictions, observations).map(-)
        var metric: [String: Any] = [
            "prediction_mean": mean(predictions), "observed_mean": mean(observations),
            "observed_sum": observations.reduce(0, +),
            "mean_prediction_minus_outcome": mean(errors), "bias_approx_95": interval(errors),
            "score_name": index == 2 ? "squared_error_for_fractional_share" : "binary_brier_score",
            "score": mean(errors.map { $0 * $0 }),
            "forecast_sampling_variance_upper_bound_mean": mean(rows.map { 1 / (4 * Double($0.samples)) })
        ]
        if index < 2 { metric["observed_event_count"] = Int(observations.reduce(0, +)) }
        if let comparisons = familywiseComparisons {
            // Fixed independent rows; each residual is in [-1,1]. Hoeffding's
            // two-sided bound plus Bonferroni, with family declared as 12 x 3.
            let width = sqrt(2 * log(2 * Double(comparisons) / 0.05) / Double(rows.count))
            metric["bias_hoeffding_familywise_95"] = [max(-1, mean(errors) - width), min(1, mean(errors) + width)]
            metric["familywise_comparisons"] = comparisons
        }
        if bins {
            var table: [[String: Any]] = [], ece = 0.0
            for bin in 0..<10 {
                let included = rows.filter { min(9, Int($0.predicted[index] * 10)) == bin }
                guard !included.isEmpty else { continue }
                let p = included.map { $0.predicted[index] }, y = included.map { $0.observed[index] }
                ece += Double(included.count) / Double(rows.count) * abs(mean(p) - mean(y))
                table.append([
                    "lower": Double(bin) / 10, "upper": Double(bin + 1) / 10, "count": included.count,
                    "prediction_mean": mean(p), "observed_mean": mean(y),
                    "observed_interval_approx_95": index < 2 ? wilson(y) : interval(y, bounded: true),
                    "interval_method": index < 2 ? "Wilson Bernoulli" : "independent fractional observations normal approximation"
                ])
            }
            metric["reliability_bins"] = table
            metric["descriptive_ece_10_bins"] = ece
        }
        metrics[metricNames[index]] = metric
    }
    return ["independent_deals": rows.count, "metrics": metrics]
}

@main
private enum CalibrationAudit {
    static func main() throws {
        let args = CommandLine.arguments
        func integer(_ flag: String, _ fallback: Int) -> Int {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
            return Int(args[i + 1]) ?? fallback
        }
        let perCell = integer("--deals-per-cell", 500), samples = integer("--samples", 2048)
        guard (10...100_000).contains(perCell), (128...100_000).contains(samples) else {
            throw PokerError.invalid("Use 10...100000 deals per cell and 128...100000 MC samples")
        }
        let started = ProcessInfo.processInfo.systemUptime
        func hexSeed(_ flag: String, _ fallback: UInt64) throws -> UInt64 {
            guard let i = args.firstIndex(of: flag) else { return fallback }
            guard i + 1 < args.count, let seed = UInt64(args[i + 1], radix: 16) else {
                throw PokerError.invalid("Seed must be an unsigned hexadecimal integer without 0x prefix")
            }
            return seed
        }
        let truthSeed = try hexSeed("--truth-seed", 0x504F4B4552545255)
        let predictionSeed = try hexSeed("--prediction-seed", 0x43414C4942524154)
        var truth = TruthGenerator(seed: truthSeed)
        let random = HandRange.random
        var rows: [CaseResult] = [], cellReports: [[String: Any]] = [], jitter: [[String: Any]] = []
        var incompleteBudgets = 0, totalSamples = 0, evaluatorDisagreements = 0
        for players in [2, 6, 8] {
            for (street, prefix) in [("preflop", 0), ("flop", 3), ("turn", 4), ("river", 5)] {
                var cell: [CaseResult] = []
                for index in 0..<perCell {
                    // Every row is an independent deal, not another street from the same deal.
                    let deal = truth.deal(players * 2 + 5)
                    let hero = try HoleCards(deal[0], deal[1]), board = Array(deal[2..<7])
                    let others = (0..<(players - 1)).map { Array(deal[(7 + 2 * $0)..<(9 + 2 * $0)]) }
                    let labels = Oracle.labels(hero: hero.cards, others: others, board: board)
                    // Cross-check rank ordering, while labels above remain entirely oracle-owned.
                    let productionHero = try HandEvaluator.evaluate(hero.cards + board)
                    let oracleHero = Oracle.seven(hero.cards + board)
                    for other in others {
                        let productionOther = try HandEvaluator.evaluate(other + board), oracleOther = Oracle.seven(other + board)
                        if (productionHero > productionOther) != (oracleHero > oracleOther)
                            || (productionHero == productionOther) != (oracleHero == oracleOther) { evaluatorDisagreements += 1 }
                    }
                    let request = try EquityRequest(hero: hero, board: Array(board.prefix(prefix)),
                                                    opponents: Array(repeating: random, count: players - 1))
                    // Prediction streams never depend on a truth PRNG output or hidden card value.
                    let seed = predictionSeed &+ UInt64(rows.count) &* 0x9E3779B97F4A7C15
                    let estimate = try EquityEngine.analyze(request, budget: .init(samples: samples, milliseconds: 600_000, seed: seed, exactOutcomeLimit: 0))
                    totalSamples += estimate.samples
                    if !estimate.completedBudget { incompleteBudgets += 1 }
                    let row = CaseResult(players: players, street: street,
                        predicted: [estimate.outrightWinProbability, estimate.tieProbability, estimate.equity],
                        observed: labels, samples: estimate.samples)
                    rows.append(row); cell.append(row)
                    if index < 2 {
                        let repeatEstimate = try EquityEngine.analyze(request, budget: .init(samples: samples, milliseconds: 600_000,
                                seed: seed ^ 0x8EBC6AF09C88C6E3, exactOutcomeLimit: 0))
                        jitter.append(["players": players, "street": street,
                            "equity_difference_independent_mc_seeds": estimate.equity - repeatEstimate.equity,
                            "outright_difference_independent_mc_seeds": estimate.outrightWinProbability - repeatEstimate.outrightWinProbability,
                            "conservative_equity_intervals_overlap": max(estimate.confidence95[0], repeatEstimate.confidence95[0])
                                <= min(estimate.confidence95[1], repeatEstimate.confidence95[1]),
                            "completed_budgets": estimate.completedBudget && repeatEstimate.completedBudget])
                    }
                }
                var summary = summarize(cell, bins: true, familywiseComparisons: 36)
                summary["players_including_hero"] = players; summary["street"] = street
                cellReports.append(summary)
                FileHandle.standardError.write(Data("Completed \(players) players / \(street): \(cell.count) independent deals\n".utf8))
            }
        }
        // Exact independent 990-combo river heads-up oracle versus production exact enumeration.
        // Separate generator domain; not selected according to the preceding audit's results.
        var exactTruth = TruthGenerator(seed: 0x4558414354524956), exactReports: [[String: Any]] = []
        var exactFailures = 0
        for index in 0..<16 {
            let deal = exactTruth.deal(7), hero = try HoleCards(deal[0], deal[1]), board = Array(deal[2..<7])
            let remaining = Card.deck.filter { !deal.contains($0) }
            var sums = [Double](repeating: 0, count: 3), n = 0
            for a in 0..<(remaining.count - 1) { for b in (a + 1)..<remaining.count {
                let labels = Oracle.labels(hero: hero.cards, others: [[remaining[a], remaining[b]]], board: board)
                for metric in 0..<3 { sums[metric] += labels[metric] }; n += 1
            } }
            let oracle = sums.map { $0 / Double(n) }
            let result = try EquityEngine.analyze(try EquityRequest(hero: hero, board: board, opponents: [random]),
                budget: .init(samples: samples, milliseconds: 600_000, seed: predictionSeed, exactOutcomeLimit: 2000))
            let produced = [result.outrightWinProbability, result.tieProbability, result.equity]
            let maximumError = zip(oracle, produced).map { abs($0 - $1) }.max()!
            let passed = result.exact && n == 990 && result.samples == 990 && maximumError < 1e-10
            if !passed { exactFailures += 1 }
            exactReports.append(["case": index, "hero": hero.description, "board": board.map(\.description),
                                 "outcomes": n, "oracle": oracle, "engine": produced, "max_absolute_error": maximumError, "pass": passed])
        }
        // Certify that fractional ties are not accidentally encoded as binary wins.
        var splitPotReports: [[String: Any]] = [], splitPotFailures = 0
        for players in [2, 6, 8] {
            let request = try EquityRequest(hero: HoleCards("2c3d"), board: Card.parse("AhKhQhJhTh"),
                                            opponents: Array(repeating: random, count: players - 1))
            let result = try EquityEngine.analyze(request, budget: .init(samples: samples, milliseconds: 600_000,
                                                                        seed: predictionSeed, exactOutcomeLimit: 0))
            let passed = result.outrightWinProbability == 0 && result.tieProbability == 1
                && abs(result.equity - 1 / Double(players)) < 1e-12 && result.completedBudget
            if !passed { splitPotFailures += 1 }
            splitPotReports.append(["players_including_hero": players, "expected": [0.0, 1.0, 1 / Double(players)],
                                    "engine": [result.outrightWinProbability, result.tieProbability, result.equity], "pass": passed])
        }
        let output: [String: Any] = [
            "schema": 1, "name": "Independent synthetic random-range probability calibration audit",
            "scope": "Uniform legal cards; every opponent remains to showdown; no betting, selection, human ranges, OCR, pot-size or side-pot inference",
            "design": ["deals_per_cell": perCell, "players_including_hero": [2, 6, 8], "streets": ["preflop", "flop", "turn", "river"],
                "independent_deals": rows.count, "truth_generator": "PCG32 + unbiased partial Fisher-Yates shuffle", "truth_seed_hex": String(truthSeed, radix: 16),
                "prediction_seed_domain_hex": String(predictionSeed, radix: 16), "mc_samples_per_prediction": samples,
                "exact_outcome_limit_for_empirical_audit": 0, "sampling_deadline_ms": 600_000,
                "fixed_design": "No fitting, hyperparameter selection, test-driven probability correction, or production promotion"],
            "overall": summarize(rows, bins: true),
            "by_players": [2, 6, 8].map { players -> [String: Any] in
                var s = summarize(rows.filter { $0.players == players }, bins: true); s["players_including_hero"] = players; return s
            },
            "by_players_and_street": cellReports,
            "mc_seed_jitter": jitter, "independent_exact_river_oracle": exactReports, "guaranteed_split_pot_fixtures": splitPotReports,
            "checks": ["evaluator_ordering_disagreements": evaluatorDisagreements, "exact_oracle_failures": exactFailures,
                       "guaranteed_split_pot_failures": splitPotFailures,
                       "incomplete_main_mc_budgets": incompleteBudgets, "main_mc_samples": totalSamples],
            "statistical_notes": [
                "Outright win and tie are distinct Bernoulli events; pot share is 0, 1/k, or 1 and uses a fractional-response score and empirical residual variance.",
                "Bias intervals are descriptive 95% normal approximations across independent deals, not simultaneous certificates; rare events and small bins need more data.",
                "The 36 cell-level bias means additionally use Bonferroni-Hoeffding simultaneous 95% intervals for residuals in [-1,1]. These bounds are valid but conservative; no such simultaneous claim is made for other summaries or bins.",
                "ECE is upward-biased by finite outcomes and binning; neither one nonzero ECE nor a bin outside its interval proves a model defect.",
                "Monte Carlo noise upper bound uses bounded observation variance 1/4 divided by completed sample count; it is not human-model uncertainty.",
                "No learned recalibration is promoted: a correct random-card calculation cannot learn unknown human ranges from synthetic uniformly random labels.",
                "No EV calibration claim: showdown share excludes folds, future betting, side pots and human response probabilities."
            ], "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        if evaluatorDisagreements > 0 || exactFailures > 0 || incompleteBudgets > 0 || splitPotFailures > 0 { exit(1) }
    }
}
