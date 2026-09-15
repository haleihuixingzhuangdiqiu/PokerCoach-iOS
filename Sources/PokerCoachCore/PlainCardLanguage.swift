import Foundation

public extension LiveCardPosition {
    /// Short table-facing wording. The evaluated category and equity are unchanged.
    var plainHandName: String {
        if !board.isEmpty {
            let category = HandEvaluator.value(hero.cards + board).category
            return category.name == "高牌" ? "未成对" : category.name
        }
        func rank(_ card: Card) -> String {
            let value = String(card.description.dropLast())
            return value == "T" ? "10" : value
        }
        if hero.first.rank == hero.second.rank { return "底牌一对" + rank(hero.first) }
        return hero.cards.sorted { $0.rank > $1.rank }.map(rank).joined(separator: "/") +
            (hero.first.suit == hero.second.suit ? "同花色" : "不同花色")
    }
}
