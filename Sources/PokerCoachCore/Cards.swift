import Foundation

public enum PokerError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case incompatibleRanges
    case cancelled
    case budgetExceeded
    public var description: String {
        switch self {
        case .invalid(let reason): return reason
        case .incompatibleRanges: return "范围之间没有可采样的无冲突组合，或拒绝采样预算耗尽"
        case .cancelled: return "分析已取消"
        case .budgetExceeded: return "计算预算不足，未生成可靠结果"
        }
    }
}

public struct Card: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let id: Int
    public var rank: Int { id / 4 + 2 }
    public var suit: Int { id % 4 }
    public var mask: UInt64 { 1 << id }
    public init(id: Int) throws {
        guard (0..<52).contains(id) else { throw PokerError.invalid("牌编号越界") }
        self.id = id
    }
    init(unchecked id: Int) { self.id = id }
    public init(_ text: String) throws {
        let chars = Array(text)
        guard chars.count == 2,
              let rank = Array("23456789TJQKA").firstIndex(of: Character(String(chars[0]).uppercased())),
              let suit = Array("cdhs").firstIndex(of: Character(String(chars[1]).lowercased()))
        else { throw PokerError.invalid("牌格式应为 As、Td 等：\(text)") }
        id = rank * 4 + suit
    }
    public var description: String { String(Array("23456789TJQKA")[id / 4]) + String(Array("cdhs")[suit]) }
    public static func < (lhs: Card, rhs: Card) -> Bool { lhs.id < rhs.id }
    public static let deck = (0..<52).map { Card(unchecked: $0) }
    public static func parse(_ text: String) throws -> [Card] {
        let chars = Array(text.filter { !$0.isWhitespace && $0 != "," })
        guard chars.count % 2 == 0 else { throw PokerError.invalid("牌字符串长度错误") }
        let cards = try stride(from: 0, to: chars.count, by: 2).map { try Card(String(chars[$0...($0 + 1)])) }
        guard Set(cards).count == cards.count else { throw PokerError.invalid("发现重复牌") }
        return cards
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

public struct HoleCards: Hashable, Sendable, Codable, CustomStringConvertible {
    public let first: Card
    public let second: Card
    public var cards: [Card] { [first, second] }
    public var mask: UInt64 { first.mask | second.mask }
    public var description: String { "\(first)\(second)" }
    public init(_ a: Card, _ b: Card) throws {
        guard a != b else { throw PokerError.invalid("两张底牌不能相同") }
        first = min(a, b); second = max(a, b)
    }
    public init(_ text: String) throws {
        let cards = try Card.parse(text)
        guard cards.count == 2 else { throw PokerError.invalid("需要两张底牌") }
        try self.init(cards[0], cards[1])
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

public enum HandCategory: Int, Codable, Sendable, CaseIterable {
    case highCard, pair, twoPair, trips, straight, flush, fullHouse, quads, straightFlush
    public var name: String { ["高牌", "一对", "两对", "三条", "顺子", "同花", "葫芦", "四条", "同花顺"][rawValue] }
}

public struct HandValue: Comparable, Equatable, Sendable {
    public let score: Int
    public var category: HandCategory { HandCategory(rawValue: score >> 20)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.score < rhs.score }
}

/// Direct 5–7 card evaluation. Each rank occupies four bits; larger scores win.
public enum HandEvaluator {
    public static func evaluate(_ cards: [Card]) throws -> HandValue {
        guard (5...7).contains(cards.count), Set(cards).count == cards.count else {
            throw PokerError.invalid("牌型计算需要 5–7 张不重复的牌")
        }
        return value(cards)
    }
    static func value(_ cards: [Card]) -> HandValue {
        var counts = [Int](repeating: 0, count: 15)
        var suits = [Int](repeating: 0, count: 4)
        var mask = 0
        for c in cards { counts[c.rank] += 1; suits[c.suit] |= 1 << c.rank; mask |= 1 << c.rank }
        func straight(_ m: Int) -> Int {
            for high in stride(from: 14, through: 6, by: -1) {
                if (m >> (high - 4)) & 31 == 31 { return high }
            }
            return m & 0x403C == 0x403C ? 5 : 0
        }
        func highest(_ m: Int, _ n: Int) -> [Int] {
            var result: [Int] = []
            for r in stride(from: 14, through: 2, by: -1) where m & (1 << r) != 0 {
                result.append(r); if result.count == n { break }
            }
            return result
        }
        func make(_ category: HandCategory, _ ranks: [Int]) -> HandValue {
            var score = category.rawValue << 20
            for (i, rank) in ranks.prefix(5).enumerated() { score |= rank << (16 - 4 * i) }
            return HandValue(score: score)
        }
        let flushMask = suits.first { $0.nonzeroBitCount >= 5 }
        if let f = flushMask, straight(f) > 0 { return make(.straightFlush, [straight(f)]) }
        let descending = Array(stride(from: 14, through: 2, by: -1))
        let quads = descending.filter { counts[$0] == 4 }
        let trips = descending.filter { counts[$0] >= 3 }
        let pairs = descending.filter { counts[$0] >= 2 }
        if let q = quads.first { return make(.quads, [q] + highest(mask & ~(1 << q), 1)) }
        if let t = trips.first, let p = pairs.first(where: { $0 != t }) { return make(.fullHouse, [t, p]) }
        if let f = flushMask { return make(.flush, highest(f, 5)) }
        if straight(mask) > 0 { return make(.straight, [straight(mask)]) }
        if let t = trips.first { return make(.trips, [t] + highest(mask & ~(1 << t), 2)) }
        if pairs.count >= 2 {
            return make(.twoPair, [pairs[0], pairs[1]] + highest(mask & ~(1 << pairs[0]) & ~(1 << pairs[1]), 1))
        }
        if let p = pairs.first { return make(.pair, [p] + highest(mask & ~(1 << p), 3)) }
        return make(.highCard, highest(mask, 5))
    }
}
