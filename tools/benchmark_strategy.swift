import Foundation
import PokerCoachCore

// Synthetic paired-deal diagnostic. Opponents deliberately do not call the
// production BehaviorProfile/StrengthFeature. This is NOT a human-strength test.
private struct RNG {
    var value: UInt64
    mutating func next() -> UInt64 {
        value &+= 0x9E3779B97F4A7C15
        var z = value; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
private enum Baseline: String, CaseIterable {
    case callingStation, tightValue, pressure
    /// Only own cards, already public board, legal amounts and a decision seed
    /// cross this information boundary. No dealt future board or other holes.
    func choose(state: TableState, own: HoleCards, seed: UInt64) throws -> PokerAction {
        let i = state.actor!, cost = state.amountToCall(i)
        let passive: PokerAction = cost == 0 ? .check : .call
        if self == .callingStation { return passive }
        let allowed = state.legalActions(potFractions: [0.5])
        let raises = allowed.compactMap { action -> Int? in
            if case .raiseTo(let size) = action { return size }; return nil
        }.sorted()
        let hi = max(own.first.rank, own.second.rank), lo = min(own.first.rank, own.second.rank)
        let paired = hi == lo, suited = own.first.suit == own.second.suit
        let value: Bool, playable: Bool
        if state.board.isEmpty {
            value = (paired && hi >= 11) || (hi == 14 && lo >= 13)
            playable = paired || (hi >= 12 && lo >= 10) || (suited && hi - lo == 1 && hi >= 7)
        } else {
            let hand = try HandEvaluator.evaluate(own.cards + state.board)
            value = hand.category.rawValue >= HandCategory.twoPair.rawValue
            let pairRank = (hand.score >> 16) & 15
            playable = value || (hand.category == .pair && own.cards.contains { $0.rank == pairRank })
        }
        var rng = RNG(value: seed)
        let bluff = self == .pressure && rng.next() % 8 == 0
        // Frozen deliberately simple opponents, not tuned against the tested policy.
        if (value || bluff), let target = raises.first(where: { $0 >= max(state.minimumRaiseTo, state.currentBet + state.pot / 2) }) {
            return .raiseTo(target)
        }
        if cost == 0 { return .check }
        if value { return passive }
        let priceLimit = self == .pressure ? 0.5 : 0.25
        if playable && Double(cost) <= Double(max(1, state.pot)) * priceLimit { return passive }
        return .fold
    }
}

private struct Deal {
    let holes: [HoleCards]
    let board: [Card]
    private init(holes: [HoleCards], board: [Card]) { self.holes = holes; self.board = board }
    func rotated(_ offset: Int) -> Deal {
        .init(holes: holes.indices.map { holes[($0 + offset) % holes.count] }, board: board)
    }
    init(players: Int, seed: UInt64) throws {
        var rng = RNG(value: seed), deck = Card.deck
        for i in stride(from: deck.count - 1, through: 1, by: -1) { deck.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        holes = try (0..<players).map { try HoleCards(deck[2 * $0], deck[2 * $0 + 1]) }
        board = Array(deck[(players * 2)..<(players * 2 + 5)])
    }
}
private struct Run {
    let profit: Int?
    let decisions: Int
    let completeBudgets: Int
    let rangeActions: Int
    let ledgerFallbacks: Int
    let elapsed: Double
    let trace: [[String: Any]]
    let failureStage: String?
    let error: String?
    var json: [String: Any] {
        var value: [String: Any] = ["completed": error == nil, "engineDecisions": decisions,
            "heroActions": trace.filter { ($0["applied"] as? Bool) == true }.count,
            "completeComputeBudgets": completeBudgets, "conditionedOpponentActions": rangeActions,
            "ledgerFallbacks": ledgerFallbacks, "elapsedSeconds": elapsed, "decisionTrace": trace]
        if let profit { value["netBB"] = Double(profit) / 50 }
        if let error { value["error"] = error; value["failureStage"] = failureStage }
        return value
    }
}

private struct Options {
    let pairs: Int, players: Int, samples: Int
    let seed: UInt64
    let straddle: Bool, compareContinuation: Bool
    let heroContinuation: BehaviorProfile
    init(_ arguments: [String]) throws {
        let valueKeys: Set<String> = ["--pairs", "--players", "--samples", "--seed", "--hero-call-offset", "--hero-aggression"]
        let flagKeys: Set<String> = ["--straddle", "--compare-continuation"]
        var values: [String: String] = [:], flags: Set<String> = [], i = 0
        while i < arguments.count {
            let key = arguments[i]
            guard values[key] == nil, !flags.contains(key) else { throw PokerError.invalid("duplicate argument: " + key) }
            if flagKeys.contains(key) { flags.insert(key); i += 1; continue }
            guard valueKeys.contains(key), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else {
                throw PokerError.invalid("unknown argument or missing value: " + key)
            }
            values[key] = arguments[i + 1]; i += 2
        }
        func integer(_ key: String, _ fallback: Int) throws -> Int {
            guard let raw = values[key] else { return fallback }
            guard let value = Int(raw) else { throw PokerError.invalid("invalid integer: " + key) }
            return value
        }
        func real(_ key: String, _ fallback: Double) throws -> Double {
            guard let raw = values[key] else { return fallback }
            guard let value = Double(raw), value.isFinite else { throw PokerError.invalid("invalid finite number: " + key) }
            return value
        }
        pairs = try integer("--pairs", 24); players = try integer("--players", 8); samples = try integer("--samples", 256)
        let rawSeed = try integer("--seed", 20260916)
        straddle = flags.contains("--straddle"); compareContinuation = flags.contains("--compare-continuation")
        guard rawSeed >= 0, (2...9).contains(players), pairs >= players * 2, pairs <= 10_000,
              pairs % players == 0, (64...100_000).contains(samples), !straddle || players >= 3 else {
            throw PokerError.invalid("pairs must be multiple of players and >=2 rotations; players2–9; samples64–100000; seed>=0; straddle requires >=3 players")
        }
        guard compareContinuation || (values["--hero-call-offset"] == nil && values["--hero-aggression"] == nil) else {
            throw PokerError.invalid("hero continuation parameters require --compare-continuation")
        }
        seed = UInt64(rawSeed)
        heroContinuation = try BehaviorProfile(name: compareContinuation ? "candidate-continuation" : BehaviorProfile.neutral.name,
            callOffset: real("--hero-call-offset", BehaviorProfile.neutral.callOffset),
            aggression: real("--hero-aggression", BehaviorProfile.neutral.aggression))
    }
}

@main private struct StrategyMatch {
    static func main() {
        do { try run() }
        catch {
            let object: [String: Any] = ["mode": "benchmark-configuration-error", "scoreValid": false, "error": String(describing: error)]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(2)
        }
    }
    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func run() throws {
        let options = try Options(Array(CommandLine.arguments.dropFirst()))
        let pairs = options.pairs, players = options.players, samples = options.samples, seed = options.seed
        let straddle = options.straddle, compare = options.compareContinuation
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50,
            utgStraddle: straddle ? .mandatory(amount: 100) : .disabled)
        var rows: [[String: Any]] = [], differences: [Double] = [], groups: [Int: [Double]] = [:], errors: [[String: Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        var master = RNG(value: seed)
        let dealSeeds = (0..<(pairs / players)).map { _ in master.next() }
        var aiRuns: [Run] = [], baseRuns: [Run] = []
        for index in 0..<pairs {
            let group = index / players, rotation = index % players, dealSeed = dealSeeds[group]
            let deal = try Deal(players: players, seed: dealSeed).rotated(rotation), button = (players - rotation) % players
            // Both arms start from the same deal/seat, with independent ledgers and RNGs.
            // Even a rejected AI run must not prevent recording the baseline outcome.
            let ai = play(deal: deal, rules: rules, button: button, engineHero: true,
                          heroContinuation: options.heroContinuation, samples: samples, seed: dealSeed)
            let base = play(deal: deal, rules: rules, button: button, engineHero: compare,
                            heroContinuation: .neutral, samples: samples, seed: dealSeed)
            aiRuns.append(ai); baseRuns.append(base)
            var row: [String: Any] = ["pair": index, "independentDeal": group, "dealSeed": dealSeed,
                "rotation": rotation, "button": button, "pairValid": ai.error == nil && base.error == nil,
                "ai": ai.json, "baseline": base.json,
                "aiDecisions": ai.decisions, "baselineDecisions": base.decisions,
                "completeComputeBudgets": ai.completeBudgets, "baselineCompleteComputeBudgets": base.completeBudgets,
                "conditionedOpponentActions": ai.rangeActions, "baselineConditionedOpponentActions": base.rangeActions,
                "ledgerFallbacks": ai.ledgerFallbacks, "baselineLedgerFallbacks": base.ledgerFallbacks,
                "elapsedSeconds": ai.elapsed + base.elapsed]
            for (name, arm) in [("ai", ai), ("baseline", base)] {
                if let error = arm.error {
                    errors.append(["pair": index, "arm": name, "failureStage": arm.failureStage ?? "unknown", "error": error])
                }
            }
            if let aiProfit = ai.profit, let baseProfit = base.profit, ai.error == nil && base.error == nil {
                let difference = Double(aiProfit - baseProfit) / 50
                differences.append(difference); groups[group, default: []].append(difference)
                row["aiNetBB"] = Double(aiProfit) / 50; row["baselineNetBB"] = Double(baseProfit) / 50
                row["differenceBB"] = difference
            }
            rows.append(row)
        }
        // Rotations from the same deal are dependent. CI uses independent deal
        // cluster means, NOT the number of replayed seats as its sample size.
        let clusterMeans = groups.keys.sorted().compactMap { key -> Double? in
            let values = groups[key]!
            return values.count == players ? values.reduce(0, +) / Double(players) : nil
        }
        let mean = clusterMeans.isEmpty ? 0 : clusterMeans.reduce(0, +) / Double(clusterMeans.count)
        let variance = clusterMeans.count > 1 ? clusterMeans.reduce(0) { $0 + pow($1 - mean, 2) } / Double(clusterMeans.count - 1) : 0
        let se = sqrt(variance / Double(max(1, clusterMeans.count)))
        func totals(_ runs: [Run]) -> [String: Any] {
            ["attemptedHands": runs.count, "completedHands": runs.filter { $0.error == nil }.count,
             "engineDecisions": runs.reduce(0) { $0 + $1.decisions },
             "completeComputeBudgets": runs.reduce(0) { $0 + $1.completeBudgets },
             "ledgerFallbacks": runs.reduce(0) { $0 + $1.ledgerFallbacks },
             "rejectedIllegalActions": runs.filter { $0.failureStage == "illegalAction" }.count,
             "rejectedIncompleteBudgets": runs.filter { $0.failureStage == "incompleteBudget" }.count,
             "rejectedOther": runs.filter { $0.error != nil && $0.failureStage != "illegalAction" && $0.failureStage != "incompleteBudget" }.count]
        }
        var limitations = ["Frozen weak scripted opponents; not proof of beating humans or a trained poker agent.",
            "Identical cards in both arms; all hole-card assignments and button positions rotate in complete deal blocks. Different action paths change responses.",
            "Opponent policy never receives other private cards or undealt public cards.",
            "Rules/evaluator are production Swift; settlement conservation is checked but this is not an independent rules oracle.",
            "No rake, tournament payout or device/screenshot recognition; one fixed-stack hand is evaluated at a time.",
            "95% normal-approximation interval uses fixed-N independent-deal cluster means; rotations are not independent samples. Small-sample intervals are not decisive.",
            "Exact synthetic states use ledger-conditioned ranges where verified, otherwise explicitly counted random-range fallbacks; fallback is not verified history."]
        if compare {
            limitations.append("Only the hero's continuation assumption inside search changes. Both arms execute a fresh full-engine decision each turn; this does not evaluate direct execution of the learned continuation policy.")
        }
        var result: [String: Any] = ["schemaVersion": 2,
            "mode": compare ? "synthetic-paired-continuation-diagnostic" : "synthetic-paired-deal-diagnostic",
            "compareContinuation": compare,
            "aiPolicy": "full-hand-engine", "baselinePolicy": compare ? "full-hand-engine" : "tightValue-script",
            "aiHeroContinuation": try json(options.heroContinuation),
            "baselineHeroContinuation": compare ? try json(BehaviorProfile.neutral) : NSNull(),
            "frozenOpponentPolicy": "script-v1-callingStation-tightValue-pressure",
            "opponentSeats": (1..<players).map { ["seat": $0, "policy": Baseline.allCases[($0 - 1) % Baseline.allCases.count].rawValue] as [String: Any] },
            "requestedPairs": pairs, "completedPairs": differences.count, "independentDeals": clusterMeans.count,
            "requestedIndependentDeals": pairs / players, "players": players, "straddle": straddle,
            "smallBlindChips": 20, "bigBlindChips": 50, "straddleChips": straddle ? 100 : 0,
            "initialStackChips": 5_000, "heroSeat": 0, "netProfitUnit": "traditional big blind (50 chips)",
            "samplesPerDecision": samples, "decisionDeadlineMilliseconds": 10_000, "seed": seed,
            "errors": errors, "rows": rows, "aiTotals": totals(aiRuns), "baselineTotals": totals(baseRuns),
            "scoreValid": errors.isEmpty && differences.count == pairs,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "limitations": limitations]
        if errors.isEmpty && differences.count == pairs {
            result["pairedDifferenceBBPer100"] = mean * 100
            result["pairedApprox95BBPer100"] = [(mean - 1.96 * se) * 100, (mean + 1.96 * se) * 100]
            result["clusterStandardErrorBBPer100"] = se * 100
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if !errors.isEmpty { exit(1) }
    }

    private static func play(deal: Deal, rules: PokerGameRules, button: Int,
                             engineHero: Bool, heroContinuation: BehaviorProfile, samples: Int, seed: UInt64) -> Run {
        let start = ProcessInfo.processInfo.systemUptime, players = deal.holes.count, stack = 5_000
        var decisions = 0, full = 0, rangeActions = 0, fallbacks = 0, stage = "initialization"
        var trace: [[String: Any]] = []
        func outcome(profit: Int? = nil, error: String? = nil) -> Run {
            Run(profit: profit, decisions: decisions, completeBudgets: full, rangeActions: rangeActions,
                ledgerFallbacks: fallbacks, elapsed: ProcessInfo.processInfo.systemUptime - start,
                trace: trace, failureStage: error == nil ? nil : stage, error: error)
        }
        do {
            let beginning = try rules.startHand(seats: (0..<players).map { Seat(id: $0, stack: stack) }, button: button)
            var state = beginning.state, ledger = PublicHandLedger(), tick = 1.0, steps = 0
            let straddler = beginning.positions.straddle
            func snapshot() -> PublicTableSnapshot {
                .init(seats: state.seats.map { .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded) },
                      hero: 0, cards: deal.holes[0], board: state.board, pot: state.pot, button: button, actor: state.actor,
                      rules: rules, optionalStraddle: false, straddleSeat: straddler)
            }
            func observe() {
                tick += 0.1; ledger.ingest(snapshot(), timestamp: tick, now: tick)
                tick += 0.01; ledger.ingest(snapshot(), timestamp: tick, now: tick)
            }
            observe()
            while state.live.count > 1 {
                if state.roundComplete {
                    if state.board.count == 5 { break }
                    let n = state.board.isEmpty ? 3 : state.board.count + 1
                    stage = "streetAdvance"
                    state = try state.advancing(to: Array(deal.board.prefix(n))); observe(); continue
                }
                steps += 1; stage = "actionBound"
                guard steps <= 512, let actor = state.actor else { throw PokerError.invalid("match action bound/actor") }
                let actionSeed = seed &+ UInt64(steps * 257 + actor * 31 + state.board.count)
                let action: PokerAction
                if actor == 0 {
                    trace.append(["step": steps, "decisionSeed": actionSeed, "state": try json(state),
                                  "heroCards": deal.holes[0].cards.map(\.description), "applied": false])
                }
                if actor == 0 && engineHero {
                    let ranges: [Int: HandRange]
                    stage = "ledgerValidation"
                    if let hand = ledger.current(now: tick) {
                        guard hand.state == state, hand.hero == 0, hand.cards == deal.holes[0] else {
                            throw PokerError.invalid("ledger differs from synthetic ground truth")
                        }
                        stage = "rangeAnalysis"
                        let model = try PublicActionRangeModel.analyze(hand: hand)
                        ranges = model.ranges; rangeActions += model.actionsUsedBySeat.values.reduce(0, +)
                        trace[trace.count - 1]["rangeSource"] = "verified-public-ledger"
                        trace[trace.count - 1]["conditionedOpponentActions"] = model.actionsUsedBySeat.values.reduce(0, +)
                    } else {
                        fallbacks += 1
                        // State is exact in this synthetic harness; do not fabricate history.
                        ranges = Dictionary(uniqueKeysWithValues: state.live.filter { $0 != 0 }.map { ($0, HandRange.random) })
                        trace[trace.count - 1]["rangeSource"] = "random-range-exact-synthetic-state"
                    }
                    let allowed = state.legalActions(potFractions: [0.5, 1])
                    trace[trace.count - 1]["allowedActions"] = allowed.map(\.description)
                    stage = "decision"
                    let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: deal.holes[0], ranges: ranges,
                        allowedActions: allowed, heroContinuation: heroContinuation,
                        budget: .init(samples: samples, milliseconds: 10_000, seed: actionSeed))
                    trace[trace.count - 1]["decision"] = try json(result)
                    trace[trace.count - 1]["selectedAction"] = result.suggested.description
                    stage = "incompleteBudget"
                    guard result.completedBudget, result.samplesPerScenario == samples else {
                        throw PokerError.invalid("fixed-sample decision budget incomplete")
                    }
                    full += 1; stage = "illegalAction"
                    guard allowed.contains(result.suggested) else { throw PokerError.invalid("engine selected an action outside allowed candidates") }
                    decisions += 1; action = result.suggested
                } else {
                    stage = "scriptedPolicy"
                    let policy: Baseline = actor == 0 ? .tightValue : Baseline.allCases[(actor - 1) % Baseline.allCases.count]
                    action = try policy.choose(state: state, own: deal.holes[actor], seed: actionSeed)
                    if actor == 0 {
                        trace[trace.count - 1]["policy"] = policy.rawValue
                        trace[trace.count - 1]["selectedAction"] = action.description
                    }
                }
                stage = "illegalAction"
                state = try state.applying(action)
                if actor == 0 { trace[trace.count - 1]["applied"] = true }
                observe()
            }
            stage = "settlement"
            var values: [Int: HandValue] = [:]
            if state.live.count > 1 {
                for i in state.live { values[i] = try HandEvaluator.evaluate(deal.holes[i].cards + state.board) }
            }
            let awards = try PotSettlement.integerAwards(seats: state.seats, values: values, button: button)
            let final = state.seats.indices.map { state.seats[$0].stack + awards[$0] }
            guard final.reduce(0, +) == players * stack else { throw PokerError.invalid("match chips not conserved") }
            return outcome(profit: final[0] - stack)
        } catch {
            if let poker = error as? PokerError, poker == .budgetExceeded { stage = "incompleteBudget" }
            // No replacement fold, partial-hand profit, or score from only successful deals.
            return outcome(error: String(describing: error))
        }
    }
}
