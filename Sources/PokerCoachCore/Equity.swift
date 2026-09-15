import Foundation

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func index(_ count: Int) -> Int {
        let n = UInt64(count), threshold = (0 &- n) % n
        while true { let value = next(); if value >= threshold { return Int(value % n) } }
    }
}

public struct ComputeBudget: Sendable {
    public var samples: Int
    public var milliseconds: Int
    public var seed: UInt64
    public var exactOutcomeLimit: Int
    public init(samples: Int = 10_000, milliseconds: Int = 1_000, seed: UInt64 = 20260915, exactOutcomeLimit: Int = 50_000) {
        self.samples = samples; self.milliseconds = milliseconds; self.seed = seed; self.exactOutcomeLimit = exactOutcomeLimit
    }
    func validate() throws {
        guard samples >= 2 && samples <= 10_000_000 && milliseconds > 0 && milliseconds <= 600_000
                && exactOutcomeLimit >= 0 && exactOutcomeLimit <= 1_000_000 else { throw PokerError.invalid("计算预算无效") }
    }
}

public struct EquityRequest: Sendable {
    public let hero: HoleCards
    public let board: [Card]
    public let opponents: [HandRange]
    public let deadCards: [Card]
    public init(hero: HoleCards, board: [Card], opponents: [HandRange], deadCards: [Card] = []) throws {
        let known = hero.cards + board + deadCards
        guard [0, 3, 4, 5].contains(board.count), (1...8).contains(opponents.count), Set(known).count == known.count,
              known.count + opponents.count * 2 + 5 - board.count <= 52 else { throw PokerError.invalid("已知牌或人数无效") }
        self.hero = hero; self.board = board; self.opponents = opponents; self.deadCards = deadCards
    }
}

public struct EquityResult: Sendable, Codable {
    /// Expected share at showdown, assuming everybody remains. This is NOT action EV.
    public let equity: Double
    public let outrightWinProbability: Double
    public let tieProbability: Double
    /// A two-sided 95% sampling interval for pot-share equity, conditional on the supplied ranges.
    /// Monte Carlo intervals account for stopping before the predeclared sample target; they do
    /// not cover card recognition, model error, or simultaneous comparisons with other results.
    public let confidence95: [Double]
    public let samples: Int
    public let exact: Bool
    public let elapsedMilliseconds: Double
    public let completedBudget: Bool
}

/// A union bound over every possible returned sample count, chosen before seeing any deals.
/// Half the error budget is reserved for reaching the target, half for all earlier stops.
/// This avoids using a fixed-sample interval at a data-dependent wall-clock stopping time.
enum SamplingConfidence {
    static func errorAllowance(sampleCount: Int, targetSamples: Int, errorProbability: Double) -> Double {
        guard sampleCount >= 2, targetSamples >= sampleCount,
              errorProbability > 0, errorProbability < 1 else { return 0 }
        if targetSamples == 2 { return errorProbability }
        return sampleCount == targetSamples ? errorProbability / 2
            : errorProbability / (2 * Double(targetSamples - 2))
    }
}

struct Moments {
    var n = 0
    var mean = 0.0
    var m2 = 0.0
    mutating func add(_ x: Double) { n += 1; let d = x - mean; mean += d / Double(n); m2 += d * (x - mean) }
    var variance: Double { n > 1 ? m2 / Double(n - 1) : 0 }
    var standardError: Double { sqrt(variance / Double(max(1, n))) }
    func boundedConfidence(targetSamples: Int, errorProbability: Double = 0.05) -> [Double] {
        // Maurer–Pontil (2009), Theorem 4 is one-sided: allocate half to each tail.
        // An additional, predeclared allocation over sample counts handles early stopping.
        let allowance = SamplingConfidence.errorAllowance(sampleCount: n, targetSamples: targetSamples,
                                                           errorProbability: errorProbability)
        guard allowance > 0 else { return [0, 1] }
        let l = log(4 / allowance)
        let width = sqrt(2 * max(0, variance) * l / Double(n)) + 7 * l / (3 * Double(n - 1))
        return [max(0, mean - width), min(1, mean + width)]
    }
}

struct SamplingRange {
    let combos: [WeightedCombo]
    let cumulative: [Double]
    init(_ range: HandRange, blocked: UInt64) throws {
        combos = range.combos.filter { $0.hand.mask & blocked == 0 && $0.weight > 0 && $0.weight.isFinite }
        guard !combos.isEmpty else { throw PokerError.incompatibleRanges }
        let total = combos.reduce(0) { $0 + $1.weight }
        var sum = 0.0
        cumulative = combos.map { sum += $0.weight / total; return sum }
    }
    func draw(_ rng: inout SplitMix64) -> HoleCards {
        let value = rng.unit()
        var low = 0, high = cumulative.count - 1
        while low < high { let mid = (low + high) / 2; if value < cumulative[mid] { high = mid } else { low = mid + 1 } }
        return combos[low].hand
    }
}

struct DealSampler {
    let request: EquityRequest
    let blocked: UInt64
    let ranges: [SamplingRange]
    init(_ request: EquityRequest) throws {
        self.request = request
        let known = (request.hero.cards + request.board + request.deadCards).reduce(UInt64(0)) { $0 | $1.mask }
        blocked = known
        ranges = try request.opponents.map { try SamplingRange($0, blocked: known) }
    }
    /// Reject the WHOLE independently sampled tuple on collision. Sequential reweighting biases seats.
    func holeDeal(_ rng: inout SplitMix64) -> [HoleCards]? {
        var used = blocked, hands: [HoleCards] = []
        for range in ranges {
            let hand = range.draw(&rng)
            if hand.mask & used != 0 { return nil }
            used |= hand.mask; hands.append(hand)
        }
        return hands
    }
    func runout(_ hands: [HoleCards], _ rng: inout SplitMix64) -> [Card] {
        let used = hands.reduce(blocked) { $0 | $1.mask }
        var available = Card.deck.filter { $0.mask & used == 0 }
        let needed = 5 - request.board.count
        for i in 0..<needed { available.swapAt(i, i + rng.index(available.count - i)) }
        return request.board + available.prefix(needed)
    }
}

public enum EquityEngine {
    public static func analyze(_ request: EquityRequest, budget: ComputeBudget = .init(),
                               isCancelled: () -> Bool = { false }) throws -> EquityResult {
        try budget.validate()
        let start = ProcessInfo.processInfo.systemUptime
        let sampler = try DealSampler(request)
        let unknownBoard = 5 - request.board.count
        let remaining = 52 - sampler.blocked.nonzeroBitCount - 2 * request.opponents.count
        var upperBound = combinations(remaining, unknownBoard)
        for range in sampler.ranges { upperBound *= Double(range.combos.count) }
        if upperBound <= Double(budget.exactOutcomeLimit) {
            return try exact(sampler, budget, start, isCancelled)
        }
        var rng = SplitMix64(state: budget.seed), moments = Moments()
        var wins = 0, ties = 0, attempts = 0
        while moments.n < budget.samples && attempts < max(10_000, budget.samples * 200) {
            if attempts % 32 == 0 {
                if isCancelled() { throw PokerError.cancelled }
                if (ProcessInfo.processInfo.systemUptime - start) * 1000 >= Double(budget.milliseconds) { break }
            }
            attempts += 1
            guard let hands = sampler.holeDeal(&rng) else { continue }
            let result = share(request.hero, hands, sampler.runout(hands, &rng))
            moments.add(result)
            if result == 1 { wins += 1 } else if result > 0 { ties += 1 }
        }
        guard moments.n >= 2 else { throw attempts >= max(10_000, budget.samples * 200) ? PokerError.incompatibleRanges : PokerError.budgetExceeded }
        return EquityResult(equity: moments.mean, outrightWinProbability: Double(wins) / Double(moments.n),
                            tieProbability: Double(ties) / Double(moments.n), confidence95: moments.boundedConfidence(targetSamples: budget.samples),
                            samples: moments.n, exact: false, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                            completedBudget: moments.n == budget.samples)
    }

    private static func share(_ hero: HoleCards, _ hands: [HoleCards], _ board: [Card]) -> Double {
        let own = HandEvaluator.value(hero.cards + board)
        var ties = 1
        for hand in hands {
            let other = HandEvaluator.value(hand.cards + board)
            if other > own { return 0 }
            if other == own { ties += 1 }
        }
        return 1 / Double(ties)
    }
    private static func combinations(_ n: Int, _ k: Int) -> Double {
        if k == 0 { return 1 }
        return (1...k).reduce(1.0) { $0 * Double(n - k + $1) / Double($1) }
    }
    private static func exact(_ sampler: DealSampler, _ budget: ComputeBudget, _ start: Double,
                              _ cancelled: () -> Bool) throws -> EquityResult {
        var weightSum = 0.0, equity = 0.0, wins = 0.0, ties = 0.0, count = 0, nodes = 0
        let needed = 5 - sampler.request.board.count
        func checkBudget() throws {
            nodes += 1
            if nodes % 32 == 1 {
                if cancelled() { throw PokerError.cancelled }
                if (ProcessInfo.processInfo.systemUptime - start) * 1000 >= Double(budget.milliseconds) { throw PokerError.budgetExceeded }
            }
        }
        func boardSearch(_ available: [Card], _ offset: Int, _ selected: [Card], _ hands: [HoleCards], _ weight: Double) throws {
            try checkBudget()
            if selected.count == needed {
                let s = share(sampler.request.hero, hands, sampler.request.board + selected)
                weightSum += weight; equity += weight * s; count += 1
                if s == 1 { wins += weight } else if s > 0 { ties += weight }
                return
            }
            let end = available.count - (needed - selected.count)
            guard offset <= end else { return }
            for i in offset...end { try boardSearch(available, i + 1, selected + [available[i]], hands, weight) }
        }
        func handSearch(_ index: Int, _ used: UInt64, _ hands: [HoleCards], _ weight: Double) throws {
            try checkBudget()
            if index == sampler.ranges.count {
                try boardSearch(Card.deck.filter { $0.mask & used == 0 }, 0, [], hands, weight)
                return
            }
            for combo in sampler.ranges[index].combos where combo.hand.mask & used == 0 {
                try handSearch(index + 1, used | combo.hand.mask, hands + [combo.hand], weight * combo.weight)
            }
        }
        try handSearch(0, sampler.blocked, [], 1)
        guard weightSum > 0 else { throw PokerError.incompatibleRanges }
        let e = equity / weightSum
        return EquityResult(equity: e, outrightWinProbability: wins / weightSum, tieProbability: ties / weightSum,
                            confidence95: [e, e], samples: count, exact: true,
                            elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, completedBudget: true)
    }
}
