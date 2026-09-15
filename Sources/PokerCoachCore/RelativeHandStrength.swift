import Foundation

/// Exact current made-hand share against ONE uniform opponent, with both hole-card blockers removed.
/// Before the river this excludes future cards and is only a rollout feature, never showdown equity.
public struct RelativeHandStrength: Sendable {
    private let board: [Card]
    private let allScores: [Int]
    private let scoresByCard: [[Int]]
    public init(board: [Card]) throws {
        guard (3...5).contains(board.count), Set(board).count == board.count else { throw PokerError.invalid("当前牌力特征需要 3–5 张公共牌") }
        self.board = board
        let available = Card.deck.filter { !board.contains($0) }
        var scores: [Int] = [], byCard = [[Int]](repeating: [], count: 52)
        for a in 0..<(available.count - 1) { for b in (a + 1)..<available.count {
            let score = HandEvaluator.value([available[a], available[b]] + board).score
            scores.append(score); byCard[available[a].id].append(score); byCard[available[b].id].append(score)
        } }
        allScores = scores.sorted(); scoresByCard = byCard.map { $0.sorted() }
    }
    public func share(for hand: HoleCards) throws -> Double {
        guard !board.contains(hand.first), !board.contains(hand.second) else { throw PokerError.invalid("底牌与公共牌冲突") }
        let score = HandEvaluator.value(hand.cards + board).score
        func bound(_ array: [Int], inclusive: Bool) -> Int {
            var low = 0, high = array.count
            while low < high {
                let middle = (low + high) / 2
                if array[middle] < score || (inclusive && array[middle] == score) { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let globalLow = bound(allScores, inclusive: false), globalHigh = bound(allScores, inclusive: true)
        let a = scoresByCard[hand.first.id], b = scoresByCard[hand.second.id]
        let aLow = bound(a, inclusive: false), bLow = bound(b, inclusive: false)
        let lower = globalLow - aLow - bLow
        // The hero's own two-card combination was subtracted twice from the tie group.
        let tied = globalHigh - globalLow - (bound(a, inclusive: true) - aLow) - (bound(b, inclusive: true) - bLow) + 1
        let n = 50 - board.count
        return (Double(lower) + Double(tied) / 2) / Double(n * (n - 1) / 2)
    }
}
