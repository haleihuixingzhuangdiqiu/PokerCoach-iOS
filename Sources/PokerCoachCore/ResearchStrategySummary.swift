import Foundation

public extension ResearchDecisionResult {
    /// Explains the selected model action. Never diagnoses an opponent's real intent.
    var strategySummary: String {
        switch suggested {
        case .fold: return "跟注不增加模型收益"
        case .call: return "跟注的模型收益更高"
        case .check: return betComparisons.isEmpty ? "可免费过牌 · 下注条件待确认" : "过牌的模型收益更高"
        case .bet, .raiseTo:
            let rows = betComparisons.filter { $0.additionalChips == additionalChips }
            let continuation = rows.reduce(0) { $0 + 1 - $1.assumedFoldProbability }
            let calledShare = rows.reduce(0) { $0 + (1 - $1.assumedFoldProbability) * $1.calledEquity.equity }
            return continuation > 0 && calledShare / continuation > 0.5
                ? "价值下注 · 比较过实际金额" : "施压策略 · 依赖对手弃牌"
        case nil: return withheldActionReason ?? "信息不足，暂不作行动判断"
        }
    }

    var guidanceSubtitle: String {
        guard let count = mainOpponentCount else { return strategySummary }
        let countLabel = opponentCountUncertain ? "按最多\(count)对手" : "\(count)名对手"
        return winLabel + " · " + countLabel + "\n" + strategySummary
    }
}
