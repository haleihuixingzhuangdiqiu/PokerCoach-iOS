import Foundation
import PokerCoachCore
#if canImport(SwiftUI)
import SwiftUI

/// One-screen operation panel. Callbacks control analysis; the view never executes poker actions.
/// Minimum portrait content area: 320 × 540 pt at standard Dynamic Type.
public struct CoachPanel: View {
    let state: GuidanceStatus
    let result: DecisionResult?
    let heroCards: String
    let board: String
    let pot: Int
    let toCall: Int
    let isDemo: Bool
    let isCapturing: Bool
    let unitScale: Int
    let toggleCapture: () -> Void
    let showFloating: () -> Void
    let showDetails: () -> Void
    public init(state: GuidanceStatus, result: DecisionResult?, heroCards: String, board: String,
                pot: Int, toCall: Int, isDemo: Bool = false, isCapturing: Bool = false, unitScale: Int = 100,
                toggleCapture: @escaping () -> Void, showFloating: @escaping () -> Void, showDetails: @escaping () -> Void) {
        self.state = state; self.result = result; self.heroCards = heroCards; self.board = board
        self.pot = pot; self.toCall = toCall; self.unitScale = max(1, unitScale); self.isDemo = isDemo; self.isCapturing = isCapturing
        self.toggleCapture = toggleCapture; self.showFloating = showFloating; self.showDetails = showDetails
    }
    private var current: DecisionResult? { state == .ready ? result : nil }
    private func money(_ amount: Int) -> String {
        let digits = min(6, max(0, Int(log10(Double(unitScale)).rounded())))
        return String(format: "%.*f", digits, Double(amount) / Double(unitScale))
    }
    private func actionText(_ action: PokerAction) -> String {
        switch action {
        case .call: return "跟注 \(money(toCall))"
        case .raiseTo(let amount): return "加注到 \(money(amount))"
        default: return action.description
        }
    }
    public var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 650
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                HStack {
                    Text("牌研").font(.title2.bold())
                    Text("对局助手").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(isDemo ? "样例" : (isCapturing ? "录屏中" : "未录屏")).font(.caption)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text("我的底牌").font(.caption).foregroundStyle(.secondary); Text(heroCards).font(.title2.bold().monospaced()) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) { Text("公共牌").font(.caption).foregroundStyle(.secondary); Text(board.isEmpty ? "尚未翻牌" : board).font(.body.monospaced()) }
                }
                HStack { Text("底池 \(money(pot))"); Spacer(); Text("需跟 \(money(toCall))") }.font(.subheadline.monospacedDigit()).padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text(current == nil ? state.rawValue : (current!.statisticallySeparated ? "研究模型建议" : "候选动作 · 尚不确定")).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(current.map { actionText($0.suggested) } ?? (state == .ready ? "分析中…" : "等待确认"))
                        .font(.system(size: compact ? 32 : 40, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
                    Text(current.map { $0.agreementAcrossScenarios ? "所列对手假设首选一致" : "模型有分歧 · 谨慎参考" } ?? "牌面和行动记录完整后显示建议").font(.caption).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 16 : 20)
                    .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("摊牌份额").font(.caption).foregroundStyle(.secondary); Text(current.map { String(format: "%.1f%%", $0.equity.equity * 100) } ?? "—").font(.title3.bold().monospacedDigit()) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) { Text("抽样 / 耗时").font(.caption).foregroundStyle(.secondary); Text(current.map { "\($0.samplesPerScenario) / \(Int($0.elapsedMilliseconds)) ms" } ?? "—").font(.subheadline.monospacedDigit()) }
                }
                Spacer(minLength: 0)
                Text("按当前轮策略模拟；后续下注未求解").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Button(isCapturing ? "暂停分析" : "开始录屏", action: toggleCapture).buttonStyle(.borderedProminent)
                    Button("悬浮指导", action: showFloating).buttonStyle(.bordered)
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 22, height: 22) }.buttonStyle(.bordered).accessibilityLabel("范围与复盘")
                }.controlSize(.large).frame(maxWidth: .infinity)
            }.padding(compact ? 16 : 22).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.background(Color.primary.opacity(0.025))
    }
}

/// Render into the system PiP video surface. These are displayed labels, not cross-app touch controls.
public struct FloatingAdvice: View {
    let status: GuidanceStatus
    let action: String?
    let context: String
    public init(status: GuidanceStatus, action: String?, context: String) { self.status = status; self.action = action; self.context = context }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status == .ready ? "牌研 · 研究建议" : status.rawValue).font(.caption)
            Text(status == .ready ? (action ?? "分析中…") : "等待确认").font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(context).font(.caption).lineLimit(1)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(red: 0.06, green: 0.11, blue: 0.12)).foregroundStyle(.white)
    }
}
#endif
