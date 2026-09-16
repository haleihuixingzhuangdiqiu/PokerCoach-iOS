import Foundation

// Compiled in the same module as Core so the tested hero policy is precisely
// BehaviorProfile.action + StrengthFeature, rather than a copied approximation.
// This trains two rollout-policy parameters, NOT equity, ranges or the full AI.

private struct Scenario: Codable {
    let players: Int
    let straddle: Bool
    var id: String { "p\(players)-\(straddle ? "straddle" : "ordinary")" }
}
private struct Candidate: Codable {
    let id: String
    let callOffset: Double
    let aggression: Double
    var profile: BehaviorProfile { try! .init(name: id, callOffset: callOffset, aggression: aggression) }
}
private struct Deal {
    let holes: [HoleCards]
    let board: [Card]
    let stacks: [Int]
    init(players: Int, seed: UInt64) throws {
        var rng = SplitMix64(state: seed), deck = Card.deck
        for i in stride(from: deck.count - 1, through: 1, by: -1) { deck.swapAt(i, rng.index(i + 1)) }
        holes = try (0..<players).map { try HoleCards(deck[2 * $0], deck[2 * $0 + 1]) }
        board = Array(deck[(players * 2)..<(players * 2 + 5)])
        // Rotations expose hero to 20/60/100 BB and occasional short blinds.
        let sizes = [1_000, 3_000, 5_000, 3_000, 5_000, 1_000, 75]
        stacks = (0..<players).map { _ in sizes[rng.index(sizes.count)] }
    }
}

// The policy boundary contains only public betting state and this actor's hand.
// No Deal, opponents' hole cards or undealt board suffix crosses this boundary.
private struct PolicyObservation {
    let state: TableState
    let own: HoleCards
    let raises: Int
    let decisionSeed: UInt64
}
private enum FrozenOpponent: Int, CaseIterable, Codable {
    case station, selective, valuePressure, mixedPressure

    func choose(_ observation: PolicyObservation) throws -> PokerAction {
        let state = observation.state, own = observation.own, actor = state.actor!
        let cost = state.amountToCall(actor), passive: PokerAction = cost == 0 ? .check : .call
        if self == .station { return passive }
        let high = max(own.first.rank, own.second.rank), low = min(own.first.rank, own.second.rank)
        let pair = high == low, suited = own.first.suit == own.second.suit
        let strong: Bool, playable: Bool, drawing: Bool
        if state.board.isEmpty {
            strong = (pair && high >= 10) || (high == 14 && low >= 12)
            playable = pair || (high >= 12 && low >= 10) || (suited && high - low <= 2 && low >= 6)
            drawing = suited && high - low <= 2
        } else {
            let value = try HandEvaluator.evaluate(own.cards + state.board)
            let pairRank = (value.score >> 16) & 15
            let ownPair = value.category == .pair && own.cards.contains { $0.rank == pairRank }
            strong = value.category.rawValue >= HandCategory.twoPair.rawValue ||
                (ownPair && pairRank >= state.board.map(\.rank).max()!)
            playable = strong || ownPair
            let all = own.cards + state.board
            let suitCounts = Dictionary(grouping: all, by: \.suit).mapValues(\.count)
            drawing = state.board.count < 5 && own.cards.contains { suitCounts[$0.suit] == 4 }
        }
        var rng = SplitMix64(state: observation.decisionSeed)
        let bluff = self == .mixedPressure && rng.unit() < 0.12
        let halfPot = state.legalActions(potFractions: [self == .mixedPressure ? 1 : 0.5])
            .compactMap { action -> Int? in if case .raiseTo(let n) = action { return n }; return nil }.sorted()
        // Frozen opponents use independent category rules, not production policy
        // features. The 4-raise cap is a declared script limit, not a poker rule.
        if observation.raises < 4, strong || bluff,
           let target = halfPot.first(where: { $0 >= max(state.minimumRaiseTo, state.currentBet + state.pot / 2) }) {
            return .raiseTo(target)
        }
        if cost == 0 { return .check }
        if strong { return passive }
        let price = Double(cost) / Double(max(1, state.pot + cost))
        let limit = self == .selective ? 0.20 : (self == .valuePressure ? 0.29 : 0.40)
        if (playable || drawing) && price <= limit { return passive }
        return .fold
    }
}
private struct Outcome { let profit: Int; let decisions: Int; let allIns: Int }

private func chooseHero(_ observation: PolicyObservation, profile: BehaviorProfile) -> PokerAction {
    var rng = SplitMix64(state: observation.decisionSeed)
    let strength = StrengthFeature.value(hand: observation.own, board: observation.state.board)
    return profile.action(state: observation.state, strength: strength, raiseCount: observation.raises,
                          maximumRaises: 2, rng: &rng)
}

private func play(deal: Deal, scenario: Scenario, rotation: Int, seed: UInt64,
                  profile: BehaviorProfile, mix: Int) throws -> Outcome {
    let n = scenario.players, button = (n - rotation) % n
    let holes = (0..<n).map { deal.holes[($0 + rotation) % n] }
    let stacks = (0..<n).map { deal.stacks[($0 + rotation) % n] }
    let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, ante: 10,
        utgStraddle: scenario.straddle ? .mandatory(amount: 100) : .disabled)
    var state = try rules.startHand(seats: (0..<n).map { Seat(id: $0, stack: stacks[$0]) }, button: button).state
    var steps = 0, raises = 0, decisions = 0, allIns = 0
    var ownDecisionCounts = [Int](repeating: 0, count: n)
    while state.live.count > 1 {
        if state.roundComplete {
            if state.board.count == 5 { break }
            let count = state.board.isEmpty ? 3 : state.board.count + 1
            state = try state.advancing(to: Array(deal.board.prefix(count)))
            raises = 0; ownDecisionCounts = [Int](repeating: 0, count: n)
            continue
        }
        steps += 1
        guard steps <= 512, let actor = state.actor else { throw PokerError.invalid("training action bound/actor") }
        ownDecisionCounts[actor] += 1
        // Common random numbers are indexed by actor/street/local action count,
        // so an unrelated actor's extra action does not consume this draw.
        let actionSeed = seed &+ UInt64(actor * 1_000_003 + state.board.count * 10_007 + ownDecisionCounts[actor] * 103)
        let observation = PolicyObservation(state: state, own: holes[actor], raises: raises, decisionSeed: actionSeed)
        let action: PokerAction
        if actor == 0 { action = chooseHero(observation, profile: profile); decisions += 1 }
        else { action = try FrozenOpponent(rawValue: (actor - 1 + mix) % FrozenOpponent.allCases.count)!.choose(observation) }
        if case .raiseTo = action { raises += 1 }
        let beforeStack = state.seats[actor].stack
        state = try state.applying(action)
        try state.validate()
        if beforeStack > 0 && state.seats[actor].stack == 0 { allIns += 1 }
        guard state.seats.reduce(0, { $0 + $1.stack + $1.committed }) == stacks.reduce(0, +) else {
            throw PokerError.invalid("training per-action chip conservation")
        }
    }
    var values: [Int: HandValue] = [:]
    if state.live.count > 1 { for i in state.live { values[i] = try HandEvaluator.evaluate(holes[i].cards + state.board) } }
    let awards = try PotSettlement.integerAwards(seats: state.seats, values: values, button: button)
    let final = (0..<n).map { state.seats[$0].stack + awards[$0] }
    guard final.reduce(0, +) == stacks.reduce(0, +) else { throw PokerError.invalid("training settlement chip conservation") }
    return Outcome(profit: final[0] - stacks[0], decisions: decisions, allIns: allIns)
}

private struct Score: Codable {
    let clusterMeansBB: [String: [Double]]
    let pairs: Int
    let heroDecisions: Int
    let allIns: Int
    var meanBB: Double {
        clusterMeansBB.values.map { $0.reduce(0, +) / Double($0.count) }.reduce(0, +) / Double(clusterMeansBB.count)
    }
    var independentDeals: Int { clusterMeansBB.values.reduce(0) { $0 + $1.count } }
}
private func bootstrap(_ score: Score, seed: UInt64) -> [Double] {
    var rng = SplitMix64(state: seed), means: [Double] = []
    let strata = score.clusterMeansBB.keys.sorted().map { score.clusterMeansBB[$0]! }
    for _ in 0..<10_000 {
        let value = strata.map { values in
            (0..<values.count).reduce(0.0) { result, _ in result + values[rng.index(values.count)] } / Double(values.count)
        }.reduce(0, +) / Double(strata.count)
        means.append(value * 100)
    }
    means.sort()
    return [means[249], means[9749]]
}

@main private struct ContinuationTraining {
    static func main() throws {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--output"), at + 1 < args.count else { throw PokerError.invalid("--output required") }
        let directory = URL(fileURLWithPath: args[at + 1], isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.appendingPathComponent("preregistered-plan.json").path) else {
            throw PokerError.invalid("experiment already preregistered; refusing test reuse")
        }
        func writeJSON(_ object: Any, _ name: String) throws {
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        let started = Date(), clock = ProcessInfo.processInfo.systemUptime
        let scenarios = (2...9).map { Scenario(players: $0, straddle: false) } +
            [3, 6, 8, 9].map { Scenario(players: $0, straddle: true) }
        var candidates: [Candidate] = []
        for offset in [-0.2, -0.1, 0, 0.1, 0.2] { for aggression in [0.2, 0.8, 1.4, 2.0] {
            candidates.append(Candidate(id: "c\(candidates.count)", callOffset: offset, aggression: aggression))
        } }
        let neutral = candidates.first { $0.callOffset == 0 && $0.aggression == 0.8 }!
        let splits: [(String, UInt64, Int)] = [("train", 20_260_917_001, 32), ("validation", 20_260_917_002, 48), ("test", 20_260_917_003, 128)]
        let promotion = "Validation mean > 0; fixed held-out test stratified cluster-bootstrap 95% lower endpoint > 0; means nonnegative in p6-ordinary,p8-ordinary,p8-straddle; zero legality/conservation errors. This gates only synthetic continuation research, never automatic phone deployment."
        try writeJSON(["experiment": "synthetic-continuation-v1", "createdAt": ISO8601DateFormatter().string(from: started),
            "scope": "Production BehaviorProfile action policy only; NOT full decision engine, equity calibration or human strength",
            "candidates": try encoded(candidates), "baseline": try encoded(neutral), "scenarios": try encoded(scenarios),
            "splits": splits.map { ["name": $0.0, "masterSeed": String($0.1), "independentDealsPerScenario": $0.2] as [String: Any] },
            "selection": "Top 3 train scores plus neutral enter validation; choose highest validation mean, tie prefer closest neutral. Freeze selected model before test. Run test once against neutral.",
            "weights": "Equal scenario weights; full seat-rotation mean within each independent deal; 50-chip big blind is score unit even with 100-chip straddle.",
            "promotionRule": promotion, "bootstrapResamples": 10_000, "bootstrapSeed": "20260917999",
            "ante": 10, "smallBlind": 20, "bigBlind": 50, "straddleAmount": 100,
            "heroRaiseCapPerStreet": 2, "scriptRaiseCapPerStreet": 4,
            "opponents": ["station", "selective", "valuePressure", "mixedPressure"],
            "stackAmounts": [1000,3000,5000,3000,5000,1000,75]], "preregistered-plan.json")
        let rawURL = directory.appendingPathComponent("paired-hands.csv")
        guard fm.createFile(atPath: rawURL.path, contents: nil) else { throw PokerError.invalid("cannot create raw data") }
        let raw = try FileHandle(forWritingTo: rawURL)
        defer { try? raw.close() }
        raw.write(Data("split,candidate,scenario,cluster,rotation,dealSeed,heroProfitChips,neutralProfitChips,differenceBB,heroDecisions,allIns\n".utf8))
        var allDealSeeds = Set<UInt64>(), totalGames = 0, totalPairs = 0
        func evaluate(split: (String, UInt64, Int), models: [Candidate]) throws -> [String: Score] {
            var master = SplitMix64(state: split.1)
            var groups = Dictionary(uniqueKeysWithValues: models.map { ($0.id, [String: [Double]]()) })
            var pairs = [String: Int](), decisions = [String: Int](), allIns = [String: Int]()
            for scenario in scenarios {
                for cluster in 0..<split.2 {
                    let seed = master.next()
                    guard allDealSeeds.insert(seed).inserted else { throw PokerError.invalid("split seed overlap") }
                    let deal = try Deal(players: scenario.players, seed: seed)
                    var clusterDifferences = [String: [Double]]()
                    for rotation in 0..<scenario.players {
                        let base = try play(deal: deal, scenario: scenario, rotation: rotation, seed: seed,
                                            profile: neutral.profile, mix: cluster % 4)
                        totalGames += 1
                        for model in models {
                            let result: Outcome
                            if model.id == neutral.id { result = base }
                            else {
                                result = try play(deal: deal, scenario: scenario, rotation: rotation, seed: seed,
                                                  profile: model.profile, mix: cluster % 4)
                                totalGames += 1
                            }
                            let difference = Double(result.profit - base.profit) / 50
                            clusterDifferences[model.id, default: []].append(difference)
                            pairs[model.id, default: 0] += 1; decisions[model.id, default: 0] += result.decisions
                            allIns[model.id, default: 0] += result.allIns; totalPairs += 1
                            raw.write(Data("\(split.0),\(model.id),\(scenario.id),\(cluster),\(rotation),\(seed),\(result.profit),\(base.profit),\(difference),\(result.decisions),\(result.allIns)\n".utf8))
                        }
                    }
                    for model in models {
                        let values = clusterDifferences[model.id]!
                        guard values.count == scenario.players else { throw PokerError.invalid("incomplete rotation block") }
                        groups[model.id, default: [:]][scenario.id, default: []].append(values.reduce(0, +) / Double(values.count))
                    }
                }
                log("\(split.0): \(scenario.id) complete; games \(totalGames)")
            }
            return Dictionary(uniqueKeysWithValues: models.map { model in
                (model.id, Score(clusterMeansBB: groups[model.id]!, pairs: pairs[model.id]!,
                                 heroDecisions: decisions[model.id]!, allIns: allIns[model.id]!))
            })
        }
        func ranked(_ models: [Candidate], scores: [String: Score]) -> [Candidate] {
            models.sorted { a, b in
                let gap = scores[a.id]!.meanBB - scores[b.id]!.meanBB
                if abs(gap) > 1e-12 { return gap > 0 }
                let distanceA = abs(a.callOffset) + abs(a.aggression - 0.8)
                let distanceB = abs(b.callOffset) + abs(b.aggression - 0.8)
                return distanceA != distanceB ? distanceA < distanceB : a.id < b.id
            }
        }
        let train = try evaluate(split: splits[0], models: candidates)
        try writeJSON(try encoded(train), "train-scores.json")
        var finalists = Array(ranked(candidates, scores: train).prefix(3))
        if !finalists.contains(where: { $0.id == neutral.id }) { finalists.append(neutral) }
        let validation = try evaluate(split: splits[1], models: finalists)
        try writeJSON(try encoded(validation), "validation-scores.json")
        let selected = ranked(finalists, scores: validation)[0]
        try writeJSON(["selected": try encoded(selected), "selectedAt": ISO8601DateFormatter().string(from: Date()),
            "selectionData": "train + validation only", "validationDifferenceBBPer100": validation[selected.id]!.meanBB * 100,
            "automaticPhoneActivation": false, "scope": "continuation-policy parameters only"], "selected-model.json")
        // Test is unsealed only AFTER the selection artifact is written. No
        // selection or retuning path exists after the following single call.
        try writeJSON(["unsealedAt": ISO8601DateFormatter().string(from: Date()), "selectedID": selected.id,
                       "masterSeed": String(splits[2].1), "fixedTestCalls": 1], "test-unsealed.json")
        let test = try evaluate(split: splits[2], models: [selected])[selected.id]!
        try writeJSON(try encoded(test), "test-score.json")
        let interval = bootstrap(test, seed: 20_260_917_999)
        let critical = ["p6-ordinary", "p8-ordinary", "p8-straddle"]
        let criticalNonnegative = critical.allSatisfy { test.clusterMeansBB[$0]!.reduce(0, +) >= 0 }
        let passed = validation[selected.id]!.meanBB > 0 && interval[0] > 0 && criticalNonnegative
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("source-manifest.json")))
        let report: [String: Any] = ["experiment": "synthetic-continuation-v1", "selected": try encoded(selected),
            "neutral": try encoded(neutral), "finalists": try encoded(finalists),
            "trainSelectedDifferenceBBPer100": train[selected.id]!.meanBB * 100,
            "validationSelectedDifferenceBBPer100": validation[selected.id]!.meanBB * 100,
            "testPairedDifferenceBBPer100": test.meanBB * 100, "testApprox95StratifiedClusterBootstrapBBPer100": interval,
            "testIndependentDeals": test.independentDeals, "testPairedRotations": test.pairs,
            "testHeroDecisions": test.heroDecisions, "testObservedAllInTransitions": test.allIns,
            "testScenarioMeansBBPer100": test.clusterMeansBB.mapValues { $0.reduce(0, +) / Double($0.count) * 100 },
            "uniqueDealSeedsAcrossSplits": allDealSeeds.count, "totalSimulatedGames": totalGames,
            "totalPairedCandidateRotations": totalPairs, "illegalActions": 0, "chipConservationFailures": 0,
            "syntheticPromotionGatePassed": passed, "promotionRule": promotion,
            "automaticPhoneActivation": false, "source": manifest,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - clock,
            "limitations": ["Only two continuation-policy parameters were fitted; this does not train or validate the full search engine, opponent ranges, card recognition or equity estimator.",
                "No real human histories were used. Scripted opponents are weak, frozen, independent of production StrengthFeature/BehaviorProfile; gains exploit this declared mixture.",
                "Train/validation/test use disjoint independent deal seeds; test was evaluated once after selection. Rotations within a deal are dependent and treated as a single cluster.",
                "Interval is an approximate fixed-sample stratified cluster bootstrap, conditional on this opponent/scenario generator; not a guarantee for unseen opponent populations.",
                "Hero policy uses production StrengthFeature without current-street RelativeHandStrength override; the deployed search can use that override and is a different policy.",
                "Public state and own hole cards only enter policy functions. Deck/runout remain in the environment. Different branches can reach different actor-local random indices.",
                "Production rules/evaluator/settlement are reused. Every action is applied and state-validated and chips are conserved; this is not an independent rules oracle.",
                "No rake, tournament ICM, psychological inference, timing features or hidden-information access. No model was deployed to the phone.",
                "A positive synthetic gate only nominates an offline candidate; full-engine paired evaluation and consenting held-out human data are still required."]]
        try writeJSON(report, "report.json")
        log("Selected \(selected.id): offset=\(selected.callOffset), aggression=\(selected.aggression)")
        log("Held-out continuation delta \(test.meanBB * 100) BB/100; approximate 95% \(interval); synthetic gate \(passed)")
    }
}
