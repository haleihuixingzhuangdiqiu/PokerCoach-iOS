import SwiftUI
import PokerCoachUI
import PokerCoachCapture

@main
struct PokerCoachApp: App {
    @StateObject private var model = CoachModel()
    var body: some Scene {
        WindowGroup { HomeScreen(model: model).preferredColorScheme(.light) }
    }
}

struct HomeScreen: View {
    @ObservedObject var model: CoachModel
    @ObservedObject private var pip: PiPGuidanceController
    @State private var showHelp = ProcessInfo.processInfo.arguments.contains("--show-help-glossary") || ProcessInfo.processInfo.arguments.contains("--show-rank-learning")
    @State private var helpPage = ProcessInfo.processInfo.arguments.contains("--show-rank-learning") ? 3 : (ProcessInfo.processInfo.arguments.contains("--show-help-glossary") ? 1 : 0)
    private let ink = Color(red: 0.13, green: 0.17, blue: 0.15)
    private let green = Color(red: 0.10, green: 0.32, blue: 0.25)

    init(model: CoachModel) { self.model = model; self.pip = model.pip }
    private var title: String {
        if !model.isScreenCaptured { return "从这里开始" }
        if !model.captureConnection.canResumeGuidance { return "等待录屏接入" }
        if pip.active { return "录屏已接入" }
        return pip.error == nil ? "正在准备悬浮" : "点继续连接重试"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("牌研").font(.headline).foregroundStyle(ink).accessibilityIdentifier("home.title")
                Spacer()
                Button("使用帮助") { showHelp = true }.font(.subheadline).foregroundStyle(green)
                    .buttonStyle(.plain).frame(minHeight: 44).accessibilityIdentifier("help.open")
            }.padding(.horizontal, 24).padding(.top, 8)
            GeometryReader { geometry in
                let width = min(max(geometry.size.width - 48, 1), 394)
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    Rectangle().fill(green).frame(width: 28, height: 2).padding(.bottom, 16)
                    Text(title).font(.title2.weight(.semibold)).foregroundStyle(ink)
                    Text(pip.error ?? model.connectionStatus)
                        .font(.subheadline).foregroundStyle(pip.error == nil ? Color.secondary : .red)
                        .multilineTextAlignment(.center).lineLimit(2).frame(minHeight: 40)
                        .padding(.horizontal, 24).padding(.top, 10).accessibilityIdentifier("connection.status")
                    Spacer(minLength: 20)
                    // Keep the real video source mounted at a stable, visible size across state changes.
                    ZStack {
                        GuidancePreview(controller: pip).frame(width: width, height: width * PiPGuidanceController.contentSize.height / PiPGuidanceController.contentSize.width)
                            .allowsHitTesting(false).accessibilityLabel("悬浮指导预览")
                            .accessibilityIdentifier("guidance.preview")
                        if !model.captureConnection.canResumeGuidance {
                            BroadcastPickerView(title: model.isScreenCaptured ? "重新接入" : "开始", onTap: model.prepareToStart)
                                .frame(width: 220, height: 68)
                        }
                    }.frame(width: width, height: max(68, width * PiPGuidanceController.contentSize.height / PiPGuidanceController.contentSize.width))
                    ZStack {
                        if model.captureConnection.canResumeGuidance {
                            Button(action: model.resumeGuidance) {
                                Text("继续连接").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 220, height: 68).background(green)
                            }.buttonStyle(.plain).accessibilityIdentifier("capture.resume")
                        }
                    }.frame(height: 68).padding(.top, 16)
                    Spacer(minLength: 20)
                    Text(model.captureConnection.canResumeGuidance ? "切回牌桌，保持底牌和下注区域无遮挡" : "在系统录屏面板选择「牌研录屏」")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineLimit(2).padding(.horizontal, 24).padding(.bottom, 28)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.white.ignoresSafeArea()).onAppear { model.start() }
            .sheet(isPresented: $showHelp) { help }
    }
    private var help: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("帮助分类", selection: $helpPage) {
                    Text("怎么用").tag(0)
                    Text("怎么看").tag(1)
                    Text("当前状态").tag(2)
                    Text("补牌").tag(3)
                }.pickerStyle(.segmented)
                if helpPage == 0 {
                    Text("开始 → 确认录屏 → 切回牌桌").font(.headline).foregroundStyle(green)
                    Text("点击「开始」，在系统面板选择「牌研录屏」，确认后切回牌桌。")
                    Text("悬浮窗只显示动作、金额和独赢估计。拖到上方空位，避开公共牌；双指收拢可缩小窗口，底牌和底部按钮都要露出。")
                    Text("关闭悬浮后点「继续连接」。没有画面时，先停止已有录屏，再点「重新接入」。")
                    Divider()
                    Text("读不清时会自动重试").font(.headline)
                    Text("悬浮窗显示「读取中」时会自动重试。详细失败原因可在「当前状态」查看；牌很清楚却持续失败时，到「补牌」确认实际点数。保持所给视频的海洋主题。")
                    Text("「下一手」表示上一手结束；「等画面」表示画面过期，旧动作和百分数已撤回。")
                } else if helpPage == 1 {
                    Text("牌型：从小到大").font(.headline).foregroundStyle(green)
                    VStack(spacing: 7) {
                        meaning("未成对／高牌", "没对子，也没组成下面的牌型")
                        meaning("一对", "两张点数相同，如两张 Q")
                        meaning("两对", "两组对子，如两张 K 加两张 Q")
                        meaning("三条", "三张点数相同")
                        meaning("顺子", "五张点数连续，如 5、6、7、8、9")
                        meaning("同花", "五张同一花色，不要求连续")
                        meaning("葫芦", "三条加一对")
                        meaning("四条", "四张点数相同")
                        meaning("同花顺", "五张既连续、又同一花色")
                    }
                    Text("取底牌和公共牌中最好的五张；两张底牌同花色，还不叫五张「同花」。未成对也可能再发一张就变强。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("独赢≈41%：假设当前对手都留到摊牌，本人独自获胜的模型估计，平局另算；「随机≤7对手」表示最多七名对手、随机持牌假设。它不是执行推荐动作后赢池的概率，超过 50% 也不自动表示值得下注。人数、范围和具体原因见「当前状态」。")
                    Text("跟 3.20＝再补 3.20；加至 8.20＝本轮总投入达到 8.20；下注 1.80＝新投 1.80；过牌＝不加钱；弃牌＝放弃这手。金额沿用牌桌单位。策略根据模型的预计筹码收益比较动作，仍未证明长期优势。")
                } else if helpPage == 2 {
                    Text("当前读取结果").font(.headline).foregroundStyle(green)
                    Text("底牌：\(model.heroCards)\n公共牌：\(model.boardCards)")
                    Text(model.analysisLabel)
                    Text(model.bettingLabel).font(.footnote)
                    Text(model.decisionExplanation).font(.caption).lineLimit(5)
                    Divider()
                    Text("\(model.transportLabel)\n\(model.frameLabel) · \(model.timingLabel)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("跟注门槛＝需补跟金额 ÷（当前底池＋需补跟金额）。只表示直接摊牌、无后续下注、无抽水且所有底池均有资格竞争时的盈亏平衡权益。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("完整记录下，模型比较多人各街行动、再次加注和主池／边池收益；只有局部截图时会限制或撤回付费建议。金额必须来自确认可用的按钮。未包含抽水，也未验证能战胜真人。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    RankLearningPanel(model: model)
                }
                Spacer(minLength: 0)
            }.font(.callout).padding(20).navigationTitle("使用帮助").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showHelp = false }.foregroundStyle(green).accessibilityIdentifier("help.done")
                } }
        }.preferredColorScheme(.light)
    }
    private func meaning(_ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name).fontWeight(.medium).frame(width: 92, alignment: .leading)
            Text(description).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.footnote)
    }
}

private struct RankLearningPanel: View {
    @ObservedObject var model: CoachModel
    // Freeze the chosen pixels while the user labels them, even if new recording frames arrive.
    @State private var selected: RankLearningSample?
    @State private var frozenSamples: [RankLearningSample] = []
    @State private var rank: String?
    private let green = Color(red: 0.10, green: 0.32, blue: 0.25)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把看清的点数教给牌研").font(.headline).foregroundStyle(green)
            Text(model.rankCoverageLabel).font(.footnote).accessibilityIdentifier("rank.coverage")
            Text("小图已固定。选牌位，再点实际点数；若已换牌，请重新打开本页。只保存字形。")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(frozenSamples) { sample in
                    Button {
                        selected = sample; rank = nil
                    } label: {
                        VStack(spacing: 3) {
                            if let preview = UIImage(data: sample.previewPNG) {
                                Image(uiImage: preview).interpolation(.none).resizable().scaledToFit().frame(width: 26, height: 35)
                            }
                            Text(sample.label).font(.caption2)
                        }.frame(width: 35, height: 58)
                            .background(selected?.id == sample.id ? green.opacity(0.12) : Color.gray.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).foregroundStyle(green).accessibilityIdentifier("rank.sample." + sample.id)
                }
            }.frame(height: 58)
            HStack(spacing: 20) {
                if let selected, let image = UIImage(data: selected.previewPNG) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 72, height: 96)
                    Text("已选 \(selected.label)\n请按原牌面确认点数").font(.footnote)
                } else {
                    Text("暂无牌样\n先接入录屏并回到牌桌，再来这里补录。")
                        .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("rank.empty")
                }
            }.frame(height: 96)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                ForEach(RankLearningLibrary.ranks, id: \.self) { value in
                    Button(value == "T" ? "10" : value) { rank = value }
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 42)
                        .background(rank == value ? green : Color.gray.opacity(0.10))
                        .foregroundStyle(rank == value ? Color.white : green)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).disabled(selected == nil)
                        .accessibilityIdentifier("rank.value." + value)
                }
            }
            Button {
                if let selected, let rank, model.saveRankSample(selected, rank: rank) { self.rank = nil }
            } label: {
                Text("保存这个字形").fontWeight(.semibold).frame(maxWidth: .infinity).frame(height: 46)
            }.buttonStyle(.borderedProminent).tint(green).disabled(selected == nil || rank == nil)
                .accessibilityIdentifier("rank.save")
            Text(model.rankLearningStatus).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                .accessibilityIdentifier("rank.status")
            Button("撤销上次补录", action: model.undoRankSample).font(.footnote).foregroundStyle(green)
                .disabled(!model.canUndoRankLearning).frame(minHeight: 30).accessibilityIdentifier("rank.undo")
            Text("同一主题的点数可用于四种花色。只补清晰正立字形；模糊、遮挡和新主题仍可能识别失败。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            freezeSamplesIfNeeded()
        }.onChange(of: model.rankSamples.map(\.id)) { _, _ in
            freezeSamplesIfNeeded()
        }
    }
    private func freezeSamplesIfNeeded() {
        guard frozenSamples.isEmpty, !model.rankSamples.isEmpty else { return }
        frozenSamples = model.rankSamples
        selected = frozenSamples.first(where: \.unresolved) ?? frozenSamples.first
    }
}
