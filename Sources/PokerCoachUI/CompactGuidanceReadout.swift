import Foundation

/// Presentation only. Original explanations remain in the host's help/diagnostics.
/// Amounts retain their meaning: calls add chips; raises reach a street total.
public struct CompactGuidanceReadout: Sendable, Equatable {
    public let primary: String
    public let probability: String?
    public let isAction: Bool

    public init(title: String, subtitle: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = title.replacingOccurrences(of: "^建议[：:]\\s*", with: "", options: .regularExpression)
        let win = Self.match("(?:摊牌独赢|独赢估计|条件独赢|独赢)\\s*([0-9]{1,3}(?:\\.[0-9]+)?)%", in: title + "\n" + subtitle)
        if let win, let value = Double(win), (0...100).contains(value) {
            probability = "独赢≈" + win + "%"
        } else { probability = nil }

        if action == "弃牌" || action == "过牌" {
            primary = action; isAction = true; return
        }
        for (prefix, compact) in [("跟注", "跟"), ("加注到", "加至"), ("下注", "下注")] {
            if let amount = Self.match("^" + prefix + "\\s*([0-9]+(?:\\.[0-9]{1,2})?)$", in: action) {
                primary = compact + " " + amount; isAction = true; return
            }
        }
        isAction = false
        if title.contains("结束") || title.contains("下一手") { primary = "下一手" }
        else if title.contains("遮挡") { primary = "移开遮挡" }
        else if title.contains("中断") || title.contains("未接通") || title.contains("未收到牌研录屏")
                    || title.contains("录屏已停止") || title.contains("连接已断") || title.contains("录屏已断") { primary = "重连录屏" }
        else if title.contains("新画面") || title.contains("过期") || title.contains("同步录屏") { primary = "等画面" }
        else if title.contains("正在连接录屏") { primary = "连接中" }
        else if title.contains("牌桌") { primary = "等牌桌" }
        else if title.hasPrefix("随机") {
            if let count = Self.match("按最多([0-9]+)名对手", in: subtitle) { primary = "随机≤" + count + "对手" }
            else { primary = "随机估算" }
        }
        else if title.contains("等待我方行动") { primary = "等行动" }
        else if probability != nil || title.contains("下注状态") || title.contains("可用动作") || title.contains("冲突") { primary = "待确认" }
        else if title.contains("未读清") { primary = "未读清" }
        else if title.contains("无法识别") { primary = "未识别" }
        else { primary = "读取中" }
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
