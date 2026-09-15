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
    let profit: Int
    let decisions: Int
    let completeBudgets: Int
    let rangeActions: Int
    let ledgerFallbacks: Int
    let elapsed: Double
}

@main private struct StrategyMatch {
    static func main() throws {
        let args = CommandLine.arguments
        func number(_ key: String, _ fallback: Int) -> Int {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
            return Int(args[i + 1]) ?? fallback
        }
        let pairs = number("--pairs", 24), players = number("--players", 8), samples = number("--samples", 256)
        let rawSeed = number("--seed", 20260916), straddle = args.contains("--straddle")
        guard rawSeed >= 0, (2...9).contains(players), pairs >= players * 2, pairs <= 10_000,
              pairs % players == 0, samples >= 64, samples <= 100_000,
              !straddle || players >= 3 else { throw PokerError.invalid("pairs must be multiple of players and >=2 rotations; players2–9; samples64–100000; seed>=0") }
        let seed = UInt64(rawSeed)
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50,
            utgStraddle: straddle ? .mandatory(amount: 100) : .disabled)
        var rows: [[String: Any]] = [], differences: [Double] = [], groups: [Int: [Double]] = [:], errors: [[String: Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        var master = RNG(value: seed)
        let dealSeeds = (0..<(pairs / players)).map { _ in master.next() }
        for index in 0..<pairs {
            let group = index / players, rotation = index % players
            let dealSeed = dealSeeds[group]
            let deal = try Deal(players: players, seed: dealSeed).rotated(rotation), button = (players - rotation) % players
            do {
                let ai = try play(deal: deal, rules: rules, button: button, aiHero: true, samples: samples, seed: dealSeed)
                let base = try play(deal: deal, rules: rules, button: button, aiHero: false, samples: samples, seed: dealSeed)
                let difference = Double(ai.profit - base.profit) / 50
                differences.append(difference); groups[group, default: []].append(difference)
                rows.append(["pair": index, "independentDeal": group, "rotation": rotation, "button": button, "aiNetBB": Double(ai.profit) / 50,
                    "baselineNetBB": Double(base.profit) / 50, "differenceBB": difference,
                    "aiDecisions": ai.decisions, "completeComputeBudgets": ai.completeBudgets,
                    "conditionedOpponentActions": ai.rangeActions, "ledgerFallbacks": ai.ledgerFallbacks,
                    "elapsedSeconds": ai.elapsed + base.elapsed])
            } catch {
                // Failed deals are listed and invalidate the score; never replace an
                // engine failure with a fold and then pretend the tested policy chose it.
                errors.append(["pair": index, "error": String(describing: error)])
            }
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
        var result: [String: Any] = ["mode": "synthetic-paired-deal-diagnostic", "requestedPairs": pairs,
            "completedPairs": differences.count, "independentDeals": clusterMeans.count, "players": players, "straddle": straddle,
            "samplesPerDecision": samples, "seed": seed, "errors": errors, "rows": rows,
            "scoreValid": errors.isEmpty && differences.count == pairs,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "limitations": ["Frozen weak scripted opponents; not proof of beating humans or a trained poker agent.",
                "Identical cards in both arms; all hole-card assignments and button positions rotate in complete deal blocks. Different action paths change responses.",
                "Opponent policy never receives other private cards or undealt public cards.",
                "Rules/evaluator are production Swift; settlement conservation is checked but this is not an independent rules oracle.",
                "No rake, tournament payout or device/screenshot recognition; one fixed-stack hand is evaluated at a time.",
                "95% normal-approximation interval uses fixed-N independent-deal cluster means; rotations are not independent samples. Small-sample intervals are not decisive."]]
        if errors.isEmpty && differences.count == pairs {
            result["pairedDifferenceBBPer100"] = mean * 100
            result["pairedApprox95BBPer100"] = [(mean - 1.96 * se) * 100, (mean + 1.96 * se) * 100]
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if !errors.isEmpty { exit(1) }
    }

    private static func play(deal: Deal, rules: PokerGameRules, button: Int,
                             aiHero: Bool, samples: Int, seed: UInt64) throws -> Run {
        let start = ProcessInfo.processInfo.systemUptime, players = deal.holes.count, stack = 5_000
        var state = try rules.startHand(seats: (0..<players).map { Seat(id: $0, stack: stack) }, button: button).state
        var ledger = PublicHandLedger(), tick = 1.0, steps = 0, decisions = 0, full = 0, rangeActions = 0, fallbacks = 0
        let straddler = try rules.startHand(seats: (0..<players).map { Seat(id: $0, stack: stack) }, button: button).positions.straddle
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
                state = try state.advancing(to: Array(deal.board.prefix(n))); observe(); continue
            }
            steps += 1
            guard steps <= 512, let actor = state.actor else { throw PokerError.invalid("match action bound/actor") }
            let actionSeed = seed &+ UInt64(steps * 257 + actor * 31 + state.board.count)
            let action: PokerAction
            if actor == 0 && aiHero {
                let ranges: [Int: HandRange]
                if let hand = ledger.current(now: tick) {
                    guard hand.state == state, hand.hero == 0, hand.cards == deal.holes[0] else {
                        throw PokerError.invalid("ledger differs from synthetic ground truth")
                    }
                    let model = try PublicActionRangeModel.analyze(hand: hand)
                    ranges = model.ranges; rangeActions += model.actionsUsedBySeat.values.reduce(0, +)
                } else {
                    fallbacks += 1
                    // State is exact in this synthetic harness; do not fabricate history.
                    ranges = Dictionary(uniqueKeysWithValues: state.live.filter { $0 != 0 }.map { ($0, HandRange.random) })
                }
                let result = try FullHandDecisionEngine.analyze(state: state, hero: 0, cards: deal.holes[0], ranges: ranges,
                    allowedActions: state.legalActions(potFractions: [0.5, 1]),
                    budget: .init(samples: samples, milliseconds: 10_000, seed: actionSeed))
                guard result.completedBudget else { throw PokerError.invalid("fixed-sample decision budget incomplete") }
                decisions += 1; full += 1; action = result.suggested
            } else {
                let policy: Baseline = actor == 0 ? .tightValue : Baseline.allCases[(actor - 1) % Baseline.allCases.count]
                action = try policy.choose(state: state, own: deal.holes[actor], seed: actionSeed)
            }
            state = try state.applying(action); observe()
        }
        var values: [Int: HandValue] = [:]
        if state.live.count > 1 {
            for i in state.live { values[i] = try HandEvaluator.evaluate(deal.holes[i].cards + state.board) }
        }
        let awards = try PotSettlement.integerAwards(seats: state.seats, values: values, button: button)
        let final = state.seats.indices.map { state.seats[$0].stack + awards[$0] }
        guard final.reduce(0, +) == players * stack else { throw PokerError.invalid("match chips not conserved") }
        return Run(profit: final[0] - stack, decisions: decisions, completeBudgets: full,
                   rangeActions: rangeActions, ledgerFallbacks: fallbacks,
                   elapsed: ProcessInfo.processInfo.systemUptime - start)
    }
}
