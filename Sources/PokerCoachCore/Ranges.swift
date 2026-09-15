import Foundation

public struct WeightedCombo: Sendable, Codable {
    public let hand: HoleCards
    public let weight: Double
    public init(_ hand: HoleCards, weight: Double = 1) { self.hand = hand; self.weight = weight }
}

public struct HandRange: Sendable, Codable {
    public let combos: [WeightedCombo]
    enum CodingKeys: String, CodingKey { case combos }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self).decode([WeightedCombo].self, forKey: .combos)
        try self.init(values)
    }
    public init(_ combos: [WeightedCombo]) throws {
        guard !combos.isEmpty, combos.allSatisfy({ $0.weight.isFinite && $0.weight >= 0 }) else {
            throw PokerError.invalid("范围权重必须为有限非负数，且范围非空")
        }
        // Normalize by max before combining to keep arbitrary external weights numerically safe.
        let maximum = combos.map(\.weight).max()!
        guard maximum > 0 else { throw PokerError.invalid("范围不能全部为零") }
        var merged: [HoleCards: Double] = [:]
        for c in combos where c.weight > 0 { merged[c.hand, default: 0] += c.weight / maximum }
        let sum = merged.values.reduce(0, +)
        self.combos = merged.map { WeightedCombo($0.key, weight: $0.value / sum) }.sorted { $0.hand.description < $1.hand.description }
    }
    public static var random: HandRange {
        var combos: [WeightedCombo] = []
        for a in 0..<51 { for b in (a + 1)..<52 { combos.append(WeightedCombo(try! HoleCards(Card(unchecked: a), Card(unchecked: b)))) } }
        return try! HandRange(combos)
    }
    /// Supported grammar: random, AsKd, AA, AK, AKs, AKo, QQ+, AJs+, 99-66; optional :0.5 weight.
    /// Overlapping notation uses the last token's weight, rather than double-counting hands.
    public static func parse(_ text: String) throws -> HandRange {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "random" { return .random }
        let tokens = text.split { $0.isWhitespace || $0 == "," || $0 == ";" }
        let ranks = Array("23456789TJQKA")
        var dictionary: [HoleCards: Double] = [:]
        func addClass(_ a: Int, _ b: Int, _ mode: Character?, _ weight: Double) throws {
            for s1 in 0..<4 { for s2 in 0..<4 {
                if a == b && s1 >= s2 { continue }
                if mode == "s" && s1 != s2 { continue }
                if mode == "o" && s1 == s2 { continue }
                let h = try HoleCards(Card(unchecked: a * 4 + s1), Card(unchecked: b * 4 + s2))
                dictionary[h] = weight
            } }
        }
        for token in tokens {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw PokerError.invalid("范围权重格式错误") }
            let weight = parts.count == 2 ? Double(parts[1]) : 1
            guard let weight, weight.isFinite, weight >= 0 else { throw PokerError.invalid("范围权重格式错误") }
            let body = String(parts[0])
            if body.count == 4, let hand = try? HoleCards(body) { dictionary[hand] = weight; continue }
            let interval = body.split(separator: "-", omittingEmptySubsequences: false)
            if interval.count == 2 {
                let a = Array(interval[0].uppercased()), b = Array(interval[1].uppercased())
                guard a.count == 2, b.count == 2, a[0] == a[1], b[0] == b[1],
                      let lo = ranks.firstIndex(of: a[0]), let hi = ranks.firstIndex(of: b[0]) else {
                    throw PokerError.invalid("区间写法目前仅支持对子，例如 99-66")
                }
                for r in min(lo, hi)...max(lo, hi) { try addClass(r, r, nil, weight) }
                continue
            }
            let plus = body.hasSuffix("+")
            let chars = Array(plus ? String(body.dropLast()) : body)
            guard (2...3).contains(chars.count),
                  let a = ranks.firstIndex(of: Character(String(chars[0]).uppercased())),
                  let b = ranks.firstIndex(of: Character(String(chars[1]).uppercased())), a >= b else {
                throw PokerError.invalid("不支持的范围表达式：\(body)")
            }
            let mode: Character? = chars.count == 3 ? Character(String(chars[2]).lowercased()) : nil
            guard mode == nil || (a != b && (mode == "s" || mode == "o")) else { throw PokerError.invalid("同花/杂色范围格式错误") }
            if plus && a == b { for r in a...12 { try addClass(r, r, nil, weight) } }
            else if plus { for r in b..<a { try addClass(a, r, mode, weight) } }
            else { try addClass(a, b, mode, weight) }
        }
        return try HandRange(dictionary.map { WeightedCombo($0.key, weight: $0.value) })
    }
    public func excluding(_ cards: [Card]) throws -> HandRange {
        let mask = cards.reduce(UInt64(0)) { $0 | $1.mask }
        return try HandRange(combos.filter { $0.hand.mask & mask == 0 })
    }
    /// Bayesian update P(hand | action) ∝ P(hand) × P(action | hand).
    /// The caller supplies a calibrated likelihood; this API does not invent hidden cards.
    public func observing(likelihood: (HoleCards) -> Double) throws -> HandRange {
        try HandRange(combos.map {
            let p = likelihood($0.hand)
            guard p.isFinite && (0...1).contains(p) else { throw PokerError.invalid("行为似然必须在 0…1 之间") }
            return WeightedCombo($0.hand, weight: $0.weight * p)
        })
    }
}

public struct FrequencyEstimate: Sendable, Codable {
    public private(set) var successes: Int = 0
    public private(set) var opportunities: Int = 0
    public let priorMean: Double
    public let priorStrength: Double
    public init(priorMean: Double = 0.5, priorStrength: Double = 20) throws {
        guard priorMean > 0 && priorMean < 1 && priorStrength.isFinite && priorStrength > 0 else {
            throw PokerError.invalid("统计先验无效")
        }
        self.priorMean = priorMean; self.priorStrength = priorStrength
    }
    public mutating func record(opportunitySucceeded: Bool) {
        opportunities += 1; if opportunitySucceeded { successes += 1 }
    }
    public var mean: Double { (priorMean * priorStrength + Double(successes)) / (priorStrength + Double(opportunities)) }
    public var standardDeviation: Double { sqrt(mean * (1 - mean) / (priorStrength + Double(opportunities) + 1)) }
}
