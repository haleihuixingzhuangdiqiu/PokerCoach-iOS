import Foundation

/// A card-only estimate. It never represents a complete betting history or a legal-action recommendation.
public struct LiveCardPosition: Hashable, Sendable {
    public let hero: HoleCards
    public let board: [Card]
    public init(slots: [String?]) throws {
        guard slots.count == 7, let first = slots[0], let second = slots[1] else { throw PokerError.invalid("底牌尚未读全") }
        hero = try HoleCards(Card(first), Card(second))
        let boardSlots = Array(slots.dropFirst(2))
        let present = boardSlots.prefix { $0 != nil }
        guard [0, 3, 4, 5].contains(present.count), boardSlots.dropFirst(present.count).allSatisfy({ $0 == nil }) else {
            throw PokerError.invalid("公共牌尚未读全")
        }
        board = try present.map { try Card($0!) }
        guard Set(hero.cards + board).count == hero.cards.count + board.count else { throw PokerError.invalid("发现重复牌") }
    }
    public var handName: String {
        if !board.isEmpty { return HandEvaluator.value(hero.cards + board).category.name }
        let ranks = hero.cards.sorted { $0.rank > $1.rank }.map { String($0.description.first!) }.joined()
        if hero.first.rank == hero.second.rank { return "口袋对\(String(hero.first.description.first!))" }
        return ranks + (hero.first.suit == hero.second.suit ? "同花" : "非同花")
    }
}

public struct PublicBettingFacts: Sendable, Equatable, Codable {
    public let pot: Int?
    public let settledPot: Int?
    public let call: Int?
    public let heroStack: Int?
    public let foldedSeats: Set<Int>
    /// Explicitly detected player all-in; absence of a label is not proof of no all-in.
    public let visibleAllIn: Bool?
    public init(raw: [String: String], scores: [String: Float], callControlVisible: Bool) {
        func number(_ key: String) -> Int? {
            guard (scores[key] ?? 0) >= 0.90, let text = raw[key] else { return nil }
            return try? ChipAmountParser.parse(text)
        }
        let settled = number("settled"), total = number("pot"), stack = number("stack")
        settledPot = settled; heroStack = stack
        if let total, settled.map({ total >= $0 }) ?? true { pot = total } else { pot = nil }
        let amount: Int? = callControlVisible ? number("call") : nil
        if let amount, amount > 0, let pot, amount <= pot, stack.map({ amount <= $0 }) ?? false { call = amount }
        else { call = nil }
        foldedSeats = Set((0..<7).filter { (scores["seat.\($0)"] ?? 0) >= 0.90 && raw["seat.\($0)"] == "弃牌" })
        visibleAllIn = raw["allin.visible"] == "true" && (scores["allin.visible"] ?? 0) >= 0.90 ? true : nil
    }
    /// Eight-seat video profile; unconfirmed opponents remain possible opponents.
    public var maximumOpponents: Int { 7 - foldedSeats.count }
    /// Simple immediate-showdown threshold, ignoring future betting, rake and unequal pot eligibility.
    public var callThreshold: Double? {
        guard let pot, let call, pot > 0, call > 0 else { return nil }
        return Double(call) / (Double(pot) + Double(call))
    }
}

/// Separate OCR timestamps prevent cached fields from being counted as new observations.
public struct PublicFactsGate: Sendable {
    private var candidate: PublicBettingFacts?
    private var lastTimestamp: Double?
    private var repeats = 0
    public private(set) var confirmed: PublicBettingFacts?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func ingest(_ facts: PublicBettingFacts, at timestamp: Double, now: Double) {
        guard timestamp.isFinite, now.isFinite, timestamp <= now, now - timestamp <= 0.8 else { reset(); return }
        guard lastTimestamp.map({ timestamp > $0 }) ?? true else { return }
        if let lastTimestamp, timestamp - lastTimestamp > 0.8 { reset() }
        lastTimestamp = timestamp
        if candidate == facts { repeats += 1 } else { candidate = facts; repeats = 1; confirmed = nil }
        if repeats >= 2 { confirmed = facts }
    }
    public mutating func current(now: Double) -> PublicBettingFacts? {
        guard let lastTimestamp, now >= lastTimestamp, now - lastTimestamp <= 0.8 else { reset(); return nil }
        return confirmed
    }
}

public struct CardEquityEstimate: Sendable, Codable {
    public let maximumOpponents: Int
    public let headsUp: EquityResult
    public let mostOpponents: EquityResult
    /// Outright wins exclude ties; keep separate from the pot-share equity used for EV.
    public var winPercentLabel: String {
        String(format: "独赢估计%.0f%%", mostOpponents.outrightWinProbability * 100)
    }
    public var percentLabel: String {
        if maximumOpponents == 1 { return String(format: "约%.0f%%", headsUp.equity * 100) }
        let low = min(headsUp.equity, mostOpponents.equity) * 100
        let high = max(headsUp.equity, mostOpponents.equity) * 100
        return String(format: "约%.0f–%.0f%%", low, high)
    }
    public var assumptionLabel: String { maximumOpponents == 1 ? "1名对手随机假设" : "按最多\(maximumOpponents)名对手 · 随机假设" }
}

public enum LiveCardAnalyzer {
    public static func analyze(_ position: LiveCardPosition, maximumOpponents: Int = 7,
                               budget: ComputeBudget = .init(samples: 4_000, milliseconds: 120, exactOutcomeLimit: 0)) throws -> CardEquityEstimate {
        guard (1...8).contains(maximumOpponents) else { throw PokerError.invalid("人数超出支持范围") }
        let headsUp = try EquityEngine.analyze(EquityRequest(hero: position.hero, board: position.board, opponents: [.random]), budget: budget,
                                               isCancelled: { Task.isCancelled })
        guard !Task.isCancelled else { throw PokerError.cancelled }
        let multi = maximumOpponents == 1 ? headsUp : try EquityEngine.analyze(
            EquityRequest(hero: position.hero, board: position.board, opponents: Array(repeating: .random, count: maximumOpponents)), budget: budget,
            isCancelled: { Task.isCancelled })
        guard headsUp.samples >= 500, multi.samples >= 500 else { throw PokerError.budgetExceeded }
        return CardEquityEstimate(maximumOpponents: maximumOpponents, headsUp: headsUp, mostOpponents: multi)
    }
}
