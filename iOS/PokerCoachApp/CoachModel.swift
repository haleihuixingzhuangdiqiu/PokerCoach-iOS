import Foundation
import UIKit
import PokerCoachCore
import PokerCoachCapture
import PokerCoachUI

/// One start intent per capture session. Snapshot research decisions stay separate from the full action ledger.
@MainActor
final class CoachModel: ObservableObject {
    @Published private(set) var isScreenCaptured = false
    @Published private(set) var heroCards = "—  —"
    @Published private(set) var boardCards = "—"
    @Published private(set) var frameLabel = "未收到画面"
    @Published private(set) var timingLabel = "等待录屏"
    @Published private(set) var connectionStatus = "准备就绪"
    @Published private(set) var analysisLabel = "确认底牌和公共牌后显示牌面估算"
    @Published private(set) var bettingLabel = "底池 — · 跟注 —"
    @Published private(set) var decisionExplanation = "确认本人回合后比较可用动作"
    @Published private(set) var rankSamples: [RankLearningSample] = []
    @Published private(set) var rankCoverageLabel = "正在读取字形覆盖"
    @Published private(set) var rankLearningStatus = "只保存你亲自确认的点数字形"
    @Published private(set) var canUndoRankLearning = false
    @Published private(set) var captureConnection = CaptureConnectionPhase.stopped
    @Published private(set) var transportLabel = "录屏尚未接入"
    let pip = PiPGuidanceController()
    private let receiver = ScreenFrameReceiver(localProbe:
        ProcessInfo.processInfo.arguments.contains("--transport-probe") ||
        ProcessInfo.processInfo.arguments.contains("--live-readout-probe"))
    private let worker = CardScanWorker()
    private let publicWorker = PublicReadWorker()
    private let fullTableWorker = FullTableReadWorker()
    private var handLedger = PublicHandLedger()
    private var openingGate = OpeningSnapshotGate()
    private var lastFullSnapshot: PublicTableSnapshot?
    private var lastFullAcceptedAt = 0.0
    private var fullDecisionTask: Task<Void, Never>?
    private var fullDecisionToken: UInt64 = 0
    private var fullDecisionKey: FullStrategyRequest?
    private var fullDecisionResult: DecisionResult?
    private var fullRangeLabel = "随机范围"
    private var fullDecisionError: String?
    private var fullRetryAfter = 0.0
    private var lastFullTableMilliseconds = 0.0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastFrameAt = 0.0
    private var cardGate = LiveCardGate()
    private var emptyBoardGate = EmptyBoardGate()
    private var factsGate = PublicFactsGate()
    private var decisionGate = LiveDecisionGate()
    private var decisionTask: Task<Void, Never>?
    private var decisionTaskToken: UInt64 = 0
    private var decisionKey: ResearchDecisionRequest?
    private var decisionResult: ResearchDecisionResult?
    private var decisionError: String?
    private var decisionRetryAfter = 0.0
    private var lastControlReason = "操作按钮待确认"
    private var sessionClock = CaptureSessionClock()
    private var captureActivity = CaptureActivityMonitor()
    private var captureBeganAt = 0.0
    private var lastTransportAt: Double?
    private var receivedFrames = 0, admittedFrames = 0, consumedFrames = 0, rejectedFrames = 0
    private var transportHealth: BroadcastHealth?
    private var healthAt = 0.0
    private var lastDiagnosticAt = 0.0
    private var diagnosticEvents: [String] = []
    private var criticalEvents: [String] = []
    private let diagnosticQueue = DispatchQueue(label: "com.lgj.pokercoach.diagnostics", qos: .utility)
    private var diagnosticCaptureActive = false
    private var lastPublicAt = 0.0
    private var lastPublicMilliseconds = 0.0
    private var lastPublicEvidence: PublicStateEvidence?
    private var analysisTask: Task<Void, Never>?
    private var analysisKey: EstimateKey?
    private var estimates: [EstimateKey: CardEquityEstimate] = [:]
    private var failedKey: EstimateKey?
    private var scanIssue: ScanIssue?
    private var settledAt: Double?
    private var unresolvedFrames = 0
    private var lastScanEvidence: [[String: Any]] = []
    private var started = false
    private var guidanceRequested = false
    private var didRequestPiP = false

    func start() {
        guard !started else { return }; started = true
        if ProcessInfo.processInfo.arguments.contains("--full-hand-probe") { FullHandDeviceProbe.run(); return }
        pip.onDiagnosticEvent = { [weak self] event in
            self?.recordCriticalEvent("PiP " + event)
            self?.writeDiagnostics(force: true)
        }
        recordCriticalEvent("App start")
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RankLearning", isDirectory: true)
            try RankLearningLibrary.shared.configure(storageURL: directory.appendingPathComponent("ocean-upright-v1.json"))
        } catch { rankLearningStatus = "补牌资料未加载：" + error.localizedDescription }
        updateRankCoverage()
        if ProcessInfo.processInfo.arguments.contains("--show-rank-learning") {
            let fixture = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RankLearningFixture.png")
            if let image = UIImage(contentsOfFile: fixture.path)?.cgImage,
               let reader = try? FourColorCardReader.wpkVideoProfile(),
               let evidence = try? reader.read(image, regions: WPKVideoLayout.cardRegions) {
                rankSamples = RankLearningSample.capture(image, evidence: evidence)
            }
        }
        worker.onResult = { [weak self] packet in Task { @MainActor in self?.consume(packet) } }
        publicWorker.onResult = { [weak self] packet in Task { @MainActor in self?.consumePublic(packet) } }
        fullTableWorker.onResult = { [weak self] packet in Task { @MainActor in self?.consumeFullTable(packet) } }
        receiver.onFrame = { [weak self] image, timestamp in
            Task { @MainActor in self?.receive(image, at: timestamp) }
        }
        receiver.onStatus = { [weak self] status in Task { @MainActor in
            self?.transportLabel = status; self?.recordEvent(status)
        } }
        receiver.onHealth = { [weak self] health in Task { @MainActor in
            self?.transportHealth = health; self?.healthAt = ProcessInfo.processInfo.systemUptime
        } }
        receiver.start()
        updateCaptureState(UIScreen.main.isCaptured)
        observers.append(NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: UIScreen.main, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCaptureState(UIScreen.main.isCaptured) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.receiver.start()
                self?.recordCriticalEvent("App 回到前台")
                self?.updateCaptureState(UIScreen.main.isCaptured)
                self?.requestPiPIfNeeded()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recordCriticalEvent("App 进入后台"); self?.writeDiagnostics(force: true) }
        })
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        if ProcessInfo.processInfo.arguments.contains("--transport-probe") { runLiveReadoutProbe() }
        else if ProcessInfo.processInfo.arguments.contains("--live-readout-probe") { runLiveReadoutProbe() }
        else if ProcessInfo.processInfo.arguments.contains("--pip-render-probe") { runRenderProbe() }
    }

    func prepareToStart() {
        updateCaptureState(UIScreen.main.isCaptured)
        guidanceRequested = true
        receiver.start()
        requestPiPIfNeeded()
    }
    func resumeGuidance() { didRequestPiP = false; prepareToStart() }
    private func requestPiPIfNeeded() {
        guard captureConnection.canResumeGuidance, guidanceRequested, !didRequestPiP else { return }
        didRequestPiP = true; pip.setIdleScreen(false); pip.start()
    }
    private func updateCaptureState(_ captured: Bool) {
        let event = captureActivity.system(diagnosticCaptureActive || captured, now: ProcessInfo.processInfo.systemUptime)
        applyCaptureEvent(event)
    }
    private func applyCaptureEvent(_ event: CaptureActivityMonitor.Event) {
        guard event != .none else { return }
        recordCriticalEvent("录屏状态核对：\(event)")
        if event == .suspended {
            sessionClock.invalidatePendingFrames(at: ProcessInfo.processInfo.systemUptime)
            cardGate.reset(); emptyBoardGate.reset(); resetAnalysis(); scanIssue = nil; settledAt = nil
            clearCards(); worker.setActive(false); publicWorker.setActive(false); fullTableWorker.setActive(false)
            handLedger.reset(); openingGate.reset(); lastFullSnapshot = nil; lastFullAcceptedAt = 0
            pip.updateReadout(title: "正在同步录屏状态", subtitle: "暂停建议 · 核对新的画面", validThrough: ProcessInfo.processInfo.systemUptime + 0.8)
            return
        }
        if event == .resumed {
            worker.setActive(true); publicWorker.setActive(true); fullTableWorker.setActive(true)
            lastFrameAt = 0; lastPublicAt = 0
            return
        }
        setConfirmedCaptureState(event == .started)
    }
    private func setConfirmedCaptureState(_ captured: Bool) {
        guard sessionClock.setActive(captured, now: ProcessInfo.processInfo.systemUptime) else { return }
        isScreenCaptured = captured; lastFrameAt = 0; lastTransportAt = nil; captureBeganAt = ProcessInfo.processInfo.systemUptime
        recordCriticalEvent(captured ? "录屏会话已开启" : "录屏会话已停止")
        cardGate.reset(); emptyBoardGate.reset(); resetAnalysis(); scanIssue = nil; settledAt = nil
        clearCards(); worker.setActive(captured); publicWorker.setActive(captured); fullTableWorker.setActive(captured)
        handLedger.reset(); openingGate.reset(); lastFullSnapshot = nil; lastFullAcceptedAt = 0
        pip.update(status: .waiting, action: nil, validThrough: 0)
        updateConnection()
        if captured {
            connectionStatus = "正在连接录屏画面"; requestPiPIfNeeded()
        } else {
            guidanceRequested = false; didRequestPiP = false; pip.stop(reason: "capture-stop-confirmed")
            connectionStatus = "准备就绪"; frameLabel = "录屏已停止"; timingLabel = "等待录屏"
        }
    }
    private func receive(_ image: CGImage, at timestamp: Double) {
        receivedFrames += 1
        updateCaptureState(UIScreen.main.isCaptured)
        applyCaptureEvent(captureActivity.frame(capturedAt: timestamp, now: ProcessInfo.processInfo.systemUptime))
        guard !captureActivity.isReconciling else { rejectedFrames += 1; return }
        guard sessionClock.accepts(capturedAt: timestamp, now: ProcessInfo.processInfo.systemUptime, generation: sessionClock.generation),
              timestamp > (lastTransportAt ?? 0) else { rejectedFrames += 1; return }
        admittedFrames += 1; lastTransportAt = timestamp; updateConnection()
        // A frame on this App's dedicated transport confirms that our extension is running.
        guidanceRequested = true; requestPiPIfNeeded()
        worker.offer(image, at: timestamp, sessionGeneration: sessionClock.generation)
        publicWorker.offer(image, at: timestamp, sessionGeneration: sessionClock.generation)
    }
    private func clearCards() { heroCards = "—  —"; boardCards = "—" }
    private func updateConnection() {
        if ProcessInfo.processInfo.arguments.contains("--pip-render-probe") { return }
        let now = ProcessInfo.processInfo.systemUptime
        let phase = CaptureConnectionPhase.evaluate(isCaptured: isScreenCaptured, lastFrameAt: lastTransportAt, now: now)
        if captureConnection != phase { captureConnection = phase; recordEvent("录屏连接状态：" + phase.rawValue) }
        switch phase {
        case .stopped:
            if !pip.active { pip.setIdleScreen(true) }
        case .receiving:
            pip.setIdleScreen(false)
        case .waitingForFrames, .interrupted:
            if pip.cancelPendingStart() { didRequestPiP = false }
            let connecting = phase == .waitingForFrames && now - captureBeganAt < 3
            let healthIsFresh = healthAt > 0 && now - healthAt < 3
            let title = connecting ? "正在连接录屏" : (phase == .interrupted ? "录屏画面已中断" : (healthIsFresh ? "图像传输未接通" : "未收到牌研录屏"))
            connectionStatus = connecting ? "等待牌研录屏的第一帧" : "点重新接入，在系统面板选择牌研录屏"
            pip.updateReadout(title: title, subtitle: "回首页重新选择牌研录屏", validThrough: now + 1)
            pip.setIdleScreen(!pip.active)
        }
    }
    private func recordEvent(_ event: String) {
        diagnosticEvents.append(String(format: "%.3f %@", ProcessInfo.processInfo.systemUptime, event))
        if diagnosticEvents.count > 32 { diagnosticEvents.removeFirst(diagnosticEvents.count - 32) }
    }
    private func recordCriticalEvent(_ event: String) {
        criticalEvents.append(ISO8601DateFormatter().string(from: Date()) + " " + event)
        if criticalEvents.count > 64 { criticalEvents.removeFirst(criticalEvents.count - 64) }
        recordEvent(event)
    }
    private func writeDiagnostics(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDiagnosticAt >= 1 else { return }
        lastDiagnosticAt = now
        var report: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "writtenAt": ISO8601DateFormatter().string(from: Date()), "uptime": now,
            "systemCaptured": UIScreen.main.isCaptured, "sessionCaptured": isScreenCaptured,
            "sessionGeneration": sessionClock.generation, "phase": captureConnection.rawValue,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "pipActive": pip.active, "pipPossible": pip.possible, "pipError": pip.error ?? "",
            "receivedFrames": receivedFrames, "admittedFrames": admittedFrames, "consumedFrames": consumedFrames,
            "rejectedFrames": rejectedFrames, "lastTransportAge": lastTransportAt.map { now - $0 } ?? -1,
            "lastRecognitionAge": lastFrameAt > 0 ? now - lastFrameAt : -1,
            "lastHealthAge": healthAt > 0 ? now - healthAt : -1,
            "transportStatus": transportLabel, "events": diagnosticEvents, "criticalEvents": criticalEvents,
            "pip": pip.debugSnapshot, "captureReconciling": captureActivity.isReconciling,
            "captureUsingFrameEvidence": captureActivity.usingFrameEvidence,
            "diagnosticMode": diagnosticCaptureActive
        ]
        var fullDiagnostics: [String: Any] = ["status": handLedger.status,
            "generation": handLedger.generation, "ocrMilliseconds": lastFullTableMilliseconds,
            "recordedActions": handLedger.hand?.actions.count ?? 0,
            "uniqueHistory": handLedger.hand?.actionSequenceUnique ?? false,
            "openingStatus": openingGate.status, "strategySource": fullDecisionKey?.sourceID ?? "none",
            "rangeModel": fullRangeLabel, "error": fullDecisionError ?? ""]
        fullDiagnostics["verifiedAge"] = handLedger.lastVerifiedAt > 0 ? now - handLedger.lastVerifiedAt : -1
        fullDiagnostics["unknownStacks"] = lastFullSnapshot?.seats.filter { $0.stack == nil }.map(\.id) ?? []
        fullDiagnostics["unknownWagers"] = lastFullSnapshot?.seats.filter { $0.streetWager == nil }.map(\.id) ?? []
        fullDiagnostics["unknownFoldStatus"] = lastFullSnapshot?.seats.filter { $0.folded == nil }.map(\.id) ?? []
        fullDiagnostics["samples"] = fullDecisionResult?.samplesPerScenario ?? 0
        fullDiagnostics["decisionMilliseconds"] = fullDecisionResult?.elapsedMilliseconds ?? -1
        report["fullHand"] = fullDiagnostics
        report["recognition"] = ["unresolvedFrames": unresolvedFrames,
                                  "blockedSeconds": scanIssue.map { max(0, now - $0.beganAt) } ?? 0,
                                  "blockedTitle": scanIssue?.title ?? "",
                                  "validationIssue": cardGate.validationIssue ?? "",
                                  "settlementVisible": settledAt != nil,
                                  "emptyBoardConfirmed": emptyBoardGate.confirmed(now: now),
                                  "slots": lastScanEvidence]
        report["decision"] = ["controls": lastControlReason, "hasRecommendation": decisionResult?.suggested != nil,
                              "failure": decisionError ?? "", "milliseconds": decisionResult?.elapsedMilliseconds ?? -1]
        if let transportHealth, let encoded = try? JSONEncoder().encode(transportHealth),
           let health = try? JSONSerialization.jsonObject(with: encoded) { report["extension"] = health }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureDiagnostics.json")
        diagnosticQueue.async { try? data.write(to: url, options: .atomic) }
    }
    private func expire() {
        updateCaptureState(UIScreen.main.isCaptured)
        applyCaptureEvent(captureActivity.tick(now: ProcessInfo.processInfo.systemUptime))
        updateConnection(); writeDiagnostics()
        guard isScreenCaptured, !captureActivity.isReconciling else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastFrameAt > 0, now - lastFrameAt > 0.8 {
            if cardGate.slots != nil { cardGate.expire(now: now); resetAnalysis() }
            clearCards()
            if captureConnection == .receiving { connectionStatus = "等待新的录屏画面" }
            frameLabel = "画面已过期"
        } else { refreshReadout() }
    }
    private func consume(_ packet: ScanPacket) {
        guard !captureActivity.isReconciling, sessionClock.accepts(capturedAt: packet.timestamp, now: ProcessInfo.processInfo.systemUptime, generation: packet.sessionGeneration),
              packet.timestamp > lastFrameAt else { return }
        consumedFrames += 1
        if let samples = packet.learningSamples, !samples.isEmpty { rankSamples = samples }
        lastFrameAt = packet.timestamp
        connectionStatus = "已就绪，切回牌桌即可"
        frameLabel = "已收到 \(packet.width)×\(packet.height)"; timingLabel = String(format: "牌面 %.0f ms", packet.milliseconds)
        if packet.settled {
            if settledAt == nil { recordEvent("识别到本手结算，撤回概率和动作") }
            settledAt = packet.timestamp; scanIssue = nil; lastScanEvidence = []
            cardGate.reset(); emptyBoardGate.reset(); resetAnalysis(); clearCards(); refreshReadout(); return
        }
        settledAt = nil
        let cards = packet.evidence.map(\.card)
        lastScanEvidence = packet.evidence.map {
            ["region": $0.region, "read": $0.card != nil,
             "unresolved": $0.hasUnresolvedCard, "reason": $0.reason]
        }
        guard packet.error == nil, !packet.evidence.contains(where: \.hasUnresolvedCard) else {
            unresolvedFrames += 1
            let regions = packet.evidence.filter(\.hasUnresolvedCard).map(\.region)
            let signature = packet.error ?? regions.joined(separator: ",")
            let canTeach = packet.learningSamples?.contains(where: { $0.unresolved && regions.contains($0.region) }) ?? false
            if scanIssue?.signature != signature {
                scanIssue = ScanIssue(signature: signature, regions: regions,
                                      error: packet.error, beganAt: packet.timestamp,
                                      canTeach: canTeach)
                recordEvent("识牌待确认：" + signature)
            } else { scanIssue?.canTeach = canTeach }
            cardGate.reset(); emptyBoardGate.reset(); resetAnalysis()
            clearCards(); frameLabel = packet.error ?? "有牌张未读清"
            refreshReadout(); return
        }
        if scanIssue != nil { recordEvent("未读清牌张已恢复") }
        scanIssue = nil
        let previousGeneration = cardGate.generation
        let wasEmpty = emptyBoardGate.confirmed(now: packet.timestamp)
        cardGate.ingest(slots: cards, timestamp: packet.timestamp, now: ProcessInfo.processInfo.systemUptime)
        if previousGeneration != cardGate.generation { emptyBoardGate.reset(); resetAnalysis(); clearCards() }
        emptyBoardGate.ingest(verifiedEmpty: packet.verifiedEmptyBoard && cards.count == 7 &&
            cards.prefix(2).allSatisfy { $0 != nil } && cards.dropFirst(2).allSatisfy { $0 == nil },
            timestamp: packet.timestamp, now: ProcessInfo.processInfo.systemUptime)
        if wasEmpty && !emptyBoardGate.confirmed(now: packet.timestamp) { resetAnalysis() }
        if let position = cardGate.position {
            heroCards = position.hero.cards.map { Self.cardLabel($0.description) }.joined(separator: " ")
            boardCards = position.board.map { Self.cardLabel($0.description) }.joined(separator: " ")
        }
        refreshReadout()
    }
    private func resetAnalysis() {
        analysisTask?.cancel(); analysisTask = nil; analysisKey = nil; failedKey = nil; estimates.removeAll()
        factsGate.reset(); lastPublicAt = 0; lastPublicEvidence = nil
        decisionGate.reset(); resetDecision(); resetFullDecision()
        analysisLabel = "确认底牌和公共牌后显示牌面估算"; bettingLabel = "底池 — · 跟注 —"
    }
    private func resetDecision() {
        decisionTaskToken &+= 1
        decisionTask?.cancel(); decisionTask = nil; decisionKey = nil; decisionResult = nil
        decisionError = nil; decisionRetryAfter = 0
    }
    private func consumePublic(_ packet: PublicReadPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !captureActivity.isReconciling, sessionClock.accepts(capturedAt: packet.timestamp, now: now, generation: packet.sessionGeneration), packet.timestamp >= cardGate.changedAt,
              packet.timestamp > lastPublicAt, now - packet.timestamp <= 0.8,
              cardGate.position != nil else { return }
        lastPublicAt = packet.timestamp
        lastPublicMilliseconds = packet.milliseconds
        lastPublicEvidence = packet.evidence
        if let evidence = packet.evidence, packet.cards == cardGate.slots {
            let facts = PublicBettingFacts(raw: evidence.raw, scores: evidence.scores, callControlVisible: evidence.callControlVisible)
            factsGate.ingest(facts, at: packet.timestamp, now: now)
            let controls = evidence.actionControls
            lastControlReason = controls.reason
            let call = controls.callConfidence >= 0.9 ? controls.callAmountText.flatMap { try? ChipAmountParser.parse($0) } : nil
            // The capture reader admits .bet only when the real wager area is clear and check is active.
            let amounts = controls.heroWagerAreaClear ? controls.raiseCandidates.compactMap { candidate -> Int? in
                guard candidate.meaning == .bet, candidate.confidence >= 0.9 else { return nil }
                return try? ChipAmountParser.parse(candidate.amountText)
            } : []
            let raises = controls.raiseCandidates.compactMap { candidate -> Int? in
                guard candidate.meaning == .raiseTo, candidate.confidence >= 0.9 else { return nil }
                return try? ChipAmountParser.parse(candidate.amountText)
            }
            let heroWager = controls.heroWager.flatMap { $0.confidence >= 0.9 ? try? ChipAmountParser.parse($0.amountText) : nil }
            let actions = VisiblePassiveActions(heroTurnConfirmed: controls.heroTurnConfirmed,
                foldAvailable: controls.canFold, checkAvailable: controls.canCheck, callAmount: call,
                visibleBetAmounts: Array(Set(amounts.filter { $0 > 0 })).sorted(),
                heroStreetCommitted: controls.heroWagerAreaClear ? 0 : heroWager,
                visibleRaiseToAmounts: Array(Set(raises.filter { $0 > 0 })).sorted())
            let remaining = Set(0..<7).subtracting(facts.foldedSeats)
            var opponentStack: Int?
            if remaining.count == 1, let seat = evidence.raw["opponent.seat"].flatMap(Int.init),
               remaining.contains(seat), (evidence.scores["opponent.stack"] ?? 0) >= 0.9 {
                opponentStack = evidence.raw["opponent.stack"].flatMap { try? ChipAmountParser.parse($0) }
            }
            let observation = LiveDecisionObservation(facts: facts, actions: actions, headsUpOpponentStack: opponentStack)
            decisionGate.ingest(observation, timestamp: packet.timestamp, now: now)
            if let image = packet.image, let position = cardGate.position {
                fullTableWorker.offer(image, at: packet.timestamp, sessionGeneration: packet.sessionGeneration,
                                      position: position, observation: observation)
            }
        } else {
            lastControlReason = "本帧金额或操作尚未确认"
            factsGate.reset(); decisionGate.reset(); resetDecision()
        }
        refreshReadout()
    }
    private func refreshReadout() {
        let now = ProcessInfo.processInfo.systemUptime
        guard isScreenCaptured, !captureActivity.isReconciling, lastFrameAt > 0, now - lastFrameAt <= 0.8 else { return }
        if let settledAt {
            handLedger.reset(); openingGate.reset(); lastFullSnapshot = nil; lastFullAcceptedAt = 0; resetFullDecision()
            analysisLabel = "本手已结束，等待下一手"
            pip.updateReadout(title: "本手已结束", subtitle: "等待下一手 · 已撤回概率和建议", validThrough: settledAt + 0.8)
            return
        }
        if let issue = scanIssue {
            analysisLabel = issue.title + "；" + issue.subtitle(now: now)
            let briefRetry = issue.error == nil && now - issue.beganAt < 0.35
            pip.updateReadout(title: briefRetry ? "正在读取牌局" : issue.title,
                              subtitle: briefRetry ? "确认牌面和金额后更新" : issue.subtitle(now: now), validThrough: lastFrameAt + 0.8)
            return
        }
        let validity = cardGate.lastTimestamp + 0.8
        guard let position = cardGate.position else {
            let hasHero = (cardGate.slots?.prefix(2).compactMap { $0 }.count ?? 0) == 2
            let issue = hasHero ? cardGate.validationIssue : nil
            let title = issue ?? (hasHero ? "正在读取牌局" : "等待自己的底牌")
            let subtitle = issue == nil ? "确认牌面和金额后更新" : "自动重新核对 · 暂停概率和建议"
            analysisLabel = title + "；" + subtitle
            pip.updateReadout(title: title, subtitle: subtitle, validThrough: lastFrameAt + 0.8)
            return
        }
        let facts = factsGate.current(now: now)
        func amount(_ chips: Int?) -> String { chips.map { String(format: "%.2f", Double($0) / 100) } ?? "—" }
        bettingLabel = "底池 \(amount(facts?.pot)) · 跟注 \(amount(facts?.call))"
        // An unreadable board must never be silently treated as a verified preflop board.
        if position.board.isEmpty && !emptyBoardGate.confirmed(now: now) {
            resetDecision()
            analysisLabel = "底牌已读，正在核对公共牌区域是否为空"
            pip.updateReadout(title: "正在读取牌局", subtitle: "确认牌面和金额后更新", validThrough: validity)
            return
        }
        if refreshFullDecision(position: position, validity: validity, now: now) { return }
        if refreshDecision(position: position, validity: validity, now: now) { return }
        let maximum = facts?.maximumOpponents ?? 7
        guard maximum > 0 else {
            analysisTask?.cancel(); analysisTask = nil; analysisKey = nil
            pip.updateReadout(title: "等待下一手", subtitle: "可见对手均已弃牌", validThrough: min(validity, lastPublicAt + 0.8))
            return
        }
        let key = EstimateKey(position: position, opponents: maximum)
        if let estimate = estimates[key] {
            if analysisKey != nil { analysisTask?.cancel(); analysisTask = nil; analysisKey = nil }
            let support = BettingAmountSupport.summarize(facts: facts, estimate: estimate)
            let detail = estimate.assumptionLabel + "\n操作待确认 · 暂无动作建议"
            analysisLabel = "\(position.plainHandName) · \(estimate.winPercentLabel) · \(estimate.assumptionLabel)"
            bettingLabel = support.amountDetails + "\n" + support.limitation
            let validThrough = facts == nil ? validity : min(validity, lastPublicAt + 0.8)
            pip.updateReadout(title: "随机\(estimate.winPercentLabel)", subtitle: detail, validThrough: validThrough)
            return
        }
        pip.updateReadout(title: "正在读取牌局", subtitle: failedKey == key ? "估算暂未完成 · 牌面已读" : "确认牌面和金额后更新", validThrough: validity)
        guard analysisKey != key, failedKey != key else { return }
        analysisTask?.cancel(); analysisKey = key
        let generation = cardGate.generation
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let estimate = try? LiveCardAnalyzer.analyze(position, maximumOpponents: maximum)
            guard !Task.isCancelled else { return }
            await self?.completeEstimate(estimate, key: key, generation: generation)
        }
    }
    private func resetFullDecision() {
        fullDecisionToken &+= 1; fullDecisionTask?.cancel(); fullDecisionTask = nil
        fullDecisionKey = nil; fullDecisionResult = nil; fullDecisionError = nil; fullRetryAfter = 0
    }
    private func consumeFullTable(_ packet: FullTablePacket) {
        lastFullTableMilliseconds = packet.milliseconds
        let now = ProcessInfo.processInfo.systemUptime
        guard !captureActivity.isReconciling,
              sessionClock.accepts(capturedAt: packet.timestamp, now: now, generation: packet.sessionGeneration),
              packet.timestamp >= cardGate.changedAt, packet.timestamp > lastFullAcceptedAt,
              cardGate.position == packet.position else { return }
        lastFullAcceptedAt = packet.timestamp
        guard let snapshot = packet.snapshot else {
            handLedger.ingestUnreadable(timestamp: packet.timestamp, now: now)
            openingGate.ingestUnreadable(timestamp: packet.timestamp, now: now)
            lastFullSnapshot = nil; resetFullDecision(); refreshReadout(); return
        }
        lastFullSnapshot = snapshot
        handLedger.ingest(snapshot, timestamp: packet.timestamp, now: now)
        openingGate.ingest(snapshot, timestamp: packet.timestamp, now: now)
        refreshReadout()
    }
    private func currentFullRequest(position: LiveCardPosition, now: Double) -> FullStrategyRequest? {
        guard let observation = decisionGate.current(now: now) else { return nil }
        if let hand = handLedger.current(now: now), hand.cards == position.hero, hand.state.board == position.board,
           let request = try? FullHandDecisionRequest(hand: hand, controls: observation.actions, observedPot: observation.facts.pot) {
            return .continuous(request)
        }
        if let opening = openingGate.current(now: now), opening.cards == position.hero, position.board.isEmpty {
            return try? FullStrategyRequest(opening: opening, controls: observation.actions, observedPot: observation.facts.pot)
        }
        return nil
    }
    private func refreshFullDecision(position: LiveCardPosition, validity: Double, now: Double) -> Bool {
        guard let request = currentFullRequest(position: position, now: now) else { resetFullDecision(); return false }
        if fullDecisionKey != request { resetFullDecision(); fullDecisionKey = request }
        let sourceTimestamp: Double
        switch request { case .continuous: sourceTimestamp = handLedger.lastVerifiedAt; case .opening: sourceTimestamp = openingGate.lastVerifiedAt }
        let validThrough = min(validity, sourceTimestamp + 0.8, decisionGate.lastTimestamp + 0.8)
        if let result = fullDecisionResult {
            analysisTask?.cancel(); analysisTask = nil; analysisKey = nil
            decisionTask?.cancel(); decisionTask = nil
            let subtitle = request.subtitle(result)
            pip.updateReadout(title: request.actionLabel(result), subtitle: subtitle, validThrough: validThrough)
            analysisLabel = "\(request.sourceLabel) · 独赢估计 \(Int((result.equity.outrightWinProbability * 100).rounded()))%"
            decisionExplanation = fullRangeLabel + "\n" + result.reasons.joined(separator: " · ")
                + "\n未训练的行为模型；比较后续各街并分别结算主池与边池"
            return true
        }
        if fullDecisionError != nil && now >= fullRetryAfter { fullDecisionError = nil }
        if fullDecisionTask == nil && fullDecisionError == nil {
            fullDecisionToken &+= 1; let token = fullDecisionToken
            fullDecisionTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let began = ProcessInfo.processInfo.systemUptime
                    let cancelled = { Task.isCancelled || ProcessInfo.processInfo.systemUptime - began > 0.5 }
                    let model: PublicActionRangeResult
                    switch request {
                    case .continuous(let continuous): model = try PublicActionRangeModel.analyze(hand: continuous.hand, isCancelled: cancelled)
                    case .opening(let opening, _): model = try PublicActionRangeModel.analyze(opening: opening, isCancelled: cancelled)
                    }
                    let remaining = max(1, min(600, Int((1 - (ProcessInfo.processInfo.systemUptime - began)) * 1000)))
                    let result = try FullHandDecisionEngine.analyze(state: request.state, hero: request.hero,
                        cards: request.cards, ranges: model.ranges, allowedActions: request.allowedActions,
                        budget: .init(samples: 256, milliseconds: remaining), isCancelled: { Task.isCancelled })
                    guard !Task.isCancelled else { return }
                    await self?.completeFullDecision(result, rangeLabel: model.label, error: nil, request: request, token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.completeFullDecision(nil, rangeLabel: "", error: String(describing: error), request: request, token: token)
                }
            }
        }
        // A confirmed complete state takes priority. Never show a cheaper snapshot model's
        // incompatible action while a full-hand calculation for this state is in flight.
        pip.updateReadout(title: fullDecisionError == nil ? "正在比较多人策略" : "策略计算暂未完成",
                          subtitle: request.sourceLabel + " · 计算具体动作", validThrough: validThrough)
        return true
    }
    private func completeFullDecision(_ result: DecisionResult?, rangeLabel: String, error: String?,
                                      request: FullStrategyRequest, token: UInt64) {
        guard token == fullDecisionToken else { return }
        fullDecisionTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard let position = cardGate.position, fullDecisionKey == request,
              currentFullRequest(position: position, now: now) == request else { return }
        fullDecisionResult = result; fullRangeLabel = rangeLabel
        fullDecisionError = error; fullRetryAfter = now + 1
        if let result { recordFullDecision(result, request: request, rangeLabel: rangeLabel) }
        refreshReadout()
    }
    private func recordFullDecision(_ result: DecisionResult, request: FullStrategyRequest, rangeLabel: String) {
        let encoder = JSONEncoder()
        guard let resultData = try? encoder.encode(result), let stateData = try? encoder.encode(request.state),
              let resultObject = try? JSONSerialization.jsonObject(with: resultData),
              let stateObject = try? JSONSerialization.jsonObject(with: stateData) else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        var record: [String: Any] = ["schemaVersion": 3, "kind": "full-state-suggestion", "recordedAt": iso,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "captureGeneration": sessionClock.generation, "source": request.sourceID,
            "serverHandIdentityVerified": false, "state": stateObject,
            "hero": request.hero, "heroCards": request.cards.cards.map(\.description),
            "rangeModel": rangeLabel, "decision": resultObject]
        switch request {
        case .continuous(let continuous):
            record["localHandID"] = continuous.hand.id
            record["historyAnchoredToForcedBets"] = true
            record["uniqueActionSequence"] = continuous.hand.actionSequenceUnique
            if let data = try? encoder.encode(continuous.hand.actions) {
                record["observedActions"] = try? JSONSerialization.jsonObject(with: data)
            }
        case .opening(let opening, _):
            record["historyAnchoredToForcedBets"] = false
            record["historyComplete"] = false
            record["assumptions"] = opening.assumptions.map(\.rawValue)
            record["inferredActions"] = opening.inferredActions.map {
                ["seatID": $0.seatID, "action": $0.action.description] as [String: Any]
            }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a); let payload = data
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(diagnosticCaptureActive ? "DecisionProbeTraces" : "DecisionResearchTraces", isDirectory: true)
        let file = folder.appendingPathComponent(String(iso.prefix(10)) + ".jsonl")
        diagnosticQueue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: payload)
            } catch {
                Task { @MainActor [weak self] in self?.recordCriticalEvent("完整建议记录写入失败：" + error.localizedDescription) }
            }
        }
    }
    private func refreshDecision(position: LiveCardPosition, validity: Double, now: Double) -> Bool {
        guard let observation = decisionGate.current(now: now), observation.actions.heroTurnConfirmed else {
            resetDecision(); decisionExplanation = lastControlReason
            return false
        }
        let request = ResearchDecisionRequest(position: position, facts: observation.facts,
            actions: observation.actions, knownHeadsUpOpponentStack: observation.headsUpOpponentStack)
        analysisTask?.cancel(); analysisTask = nil; analysisKey = nil
        if decisionKey != request { resetDecision(); decisionKey = request }
        let validThrough = min(validity, decisionGate.lastTimestamp + 0.8)
        if let result = decisionResult {
            guard result.suggested != nil else {
                decisionExplanation = result.withheldActionReason ?? result.reason
                analysisLabel = result.mainAssumptionLabel + " · " + result.winLabel
                pip.updateReadout(title: result.actionLabel, subtitle: result.guidanceSubtitle, validThrough: validThrough)
                return true
            }
            let subtitle = Self.decisionSubtitle(result)
            analysisLabel = "\(position.plainHandName) · \(result.winLabel)"
            decisionExplanation = result.mainAssumptionLabel + "\n" + result.reason
            let support = BettingAmountSupport.summarize(facts: observation.facts)
            bettingLabel = support.amountDetails
            pip.updateReadout(title: result.actionLabel,
                              subtitle: subtitle, validThrough: validThrough)
            return true
        }
        if decisionError != nil, now >= decisionRetryAfter { decisionError = nil }
        pip.updateReadout(title: decisionError == nil ? "正在读取牌局" : "暂时无法给出建议",
                          subtitle: decisionError == nil ? "确认牌面和金额后更新" : "正在重试 · 信息不全时暂停建议",
                          validThrough: validThrough)
        decisionExplanation = decisionError ?? "正在比较不同对手范围下的可用动作"
        guard decisionTask == nil, decisionError == nil else { return true }
        let cardGeneration = cardGate.generation, controlsGeneration = decisionGate.generation
        decisionTaskToken &+= 1
        let taskToken = decisionTaskToken
        decisionTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try ResearchDecisionEngine.analyze(request, isCancelled: { Task.isCancelled })
                guard !Task.isCancelled else { return }
                await self?.completeDecision(result, error: nil, request: request, observation: observation,
                                             cardGeneration: cardGeneration, controlsGeneration: controlsGeneration, taskToken: taskToken)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.completeDecision(nil, error: String(describing: error), request: request, observation: observation,
                                             cardGeneration: cardGeneration, controlsGeneration: controlsGeneration, taskToken: taskToken)
            }
        }
        return true
    }
    private func completeDecision(_ result: ResearchDecisionResult?, error: String?, request: ResearchDecisionRequest,
                                  observation: LiveDecisionObservation, cardGeneration: UInt64, controlsGeneration: UInt64, taskToken: UInt64) {
        // A completed job must release its slot even if its frame just expired. A prior job cannot clear a replacement.
        guard taskToken == decisionTaskToken else { return }
        decisionTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard decisionKey == request, cardGate.accepts(generation: cardGeneration, position: request.position, now: now),
              decisionGate.accepts(observation, generation: controlsGeneration, now: now) else { return }
        decisionResult = result; decisionError = error; decisionRetryAfter = now + 1
        if let result { recordDecision(result, request: request, capturedAt: decisionGate.lastTimestamp) }
        refreshReadout()
    }
    /// Local research evidence. A snapshot is not a verified hand history or an outcome label.
    private func recordDecision(_ result: ResearchDecisionResult, request: ResearchDecisionRequest, capturedAt: Double) {
        func encoded<T: Encodable>(_ value: T) -> Any? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        let date = Date(), iso = ISO8601DateFormatter().string(from: date)
        var record: [String: Any] = [
            "schemaVersion": 1, "kind": "suggestion", "recordedAt": iso,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "captureTimestamp": capturedAt, "captureGeneration": sessionClock.generation,
            "cardGeneration": cardGate.generation, "handIdentityVerified": false,
            "hero": request.position.hero.cards.map(\.description), "board": request.position.board.map(\.description),
            "additionalChips": result.additionalChips, "actionLabel": result.actionLabel,
            "reason": result.reason, "strategy": result.strategySummary,
            "modelAssumption": result.mainAssumptionLabel, "modelSensitive": result.modelSensitive,
            "samplingUncertain": result.samplingUncertain,
            "computeMilliseconds": result.elapsedMilliseconds,
            "observedBetAmounts": request.actions.visibleBetAmounts,
            "observedRaiseToAmounts": request.actions.visibleRaiseToAmounts,
            "heroTurnConfirmed": request.actions.heroTurnConfirmed,
            "winScenarioRange": result.outrightWinProbabilityRange,
            "limitations": result.limitations
        ]
        record["withheldActionReason"] = result.withheldActionReason
        record["fullStateStatus"] = handLedger.status
        record["openingStateStatus"] = openingGate.status
        record["latestFullSeats"] = encoded(lastFullSnapshot?.seats)
        record["facts"] = encoded(request.facts); record["selectedAction"] = encoded(result.suggested)
        record["scenarios"] = encoded(result.scenarios); record["betComparisons"] = encoded(result.betComparisons)
        record["mainWinProbability"] = result.mainOutrightWinProbability
        record["mainTieProbability"] = result.mainTieProbability; record["mainEquity"] = result.mainEquity
        record["heroStreetCommitted"] = request.actions.heroStreetCommitted
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(diagnosticCaptureActive ? "DecisionProbeTraces" : "DecisionResearchTraces", isDirectory: true)
        let file = folder.appendingPathComponent(String(iso.prefix(10)) + ".jsonl")
        let payload = data
        diagnosticQueue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: payload)
            } catch {
                Task { @MainActor [weak self] in self?.recordCriticalEvent("建议记录写入失败：" + error.localizedDescription) }
            }
        }
    }
    private static func decisionSubtitle(_ result: ResearchDecisionResult) -> String {
        result.guidanceSubtitle
    }
    private func completeEstimate(_ estimate: CardEquityEstimate?, key: EstimateKey, generation: UInt64) {
        guard isScreenCaptured, analysisKey == key,
              cardGate.accepts(generation: generation, position: key.position, now: ProcessInfo.processInfo.systemUptime) else { return }
        analysisTask = nil; analysisKey = nil
        if let estimate { estimates[key] = estimate } else { failedKey = key }
        refreshReadout()
    }
    private static func cardLabel(_ card: String?) -> String {
        guard let card, let suit = card.last else { return "—" }
        return card.dropLast().replacingOccurrences(of: "T", with: "10") + (["c": "♣", "d": "♦", "h": "♥", "s": "♠"][String(suit)] ?? "?")
    }
    @discardableResult
    func saveRankSample(_ sample: RankLearningSample, rank: String) -> Bool {
        do {
            try RankLearningLibrary.shared.save(rank: rank, pixels: sample.pixels, region: sample.region,
                                               builtInTemplates: FourColorCardReader.bundledTemplates())
            rankLearningStatus = "已记住 " + (rank == "T" ? "10" : rank) + " 的字形，切回牌桌自动重试"
            updateRankCoverage(); cardGate.reset(); resetAnalysis(); clearCards()
            return true
        } catch { rankLearningStatus = error.localizedDescription; return false }
    }
    func undoRankSample() {
        do {
            try RankLearningLibrary.shared.removeLast()
            rankLearningStatus = "已撤销上次补录"; updateRankCoverage()
            cardGate.reset(); resetAnalysis(); clearCards()
        } catch { rankLearningStatus = error.localizedDescription }
    }
    private func updateRankCoverage() {
        let known = Set(((try? FourColorCardReader.bundledTemplates()) ?? []).map(\.rank))
            .union(RankLearningLibrary.shared.coverage)
        let missing = RankLearningLibrary.ranks.filter { !known.contains($0) }.map { $0 == "T" ? "10" : $0 }
        rankCoverageLabel = "已收录 \(known.count)/13 种点数" + (missing.isEmpty ? " · 仍需识别校验" : " · 待补 " + missing.joined(separator: "、"))
        canUndoRankLearning = RankLearningLibrary.shared.hasSavedSamples
    }
    /// Local, explicit test only. Supplies recorded frames to the same workers and model callbacks.
    /// It tests the recognition→analysis→PiP path, not system ReplayKit authorization or live capture.
    private func runLiveReadoutProbe() {
        Task {
            let transport = ScreenFrameTransportProbe()
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let directory = documents.appendingPathComponent("TransportProbe-" + version + "-isolated")
            let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                transport.setActive(false); diagnosticCaptureActive = false
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
                pip.stop(); updateCaptureState(UIScreen.main.isCaptured)
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Task.sleep(for: .seconds(2))
                if ProcessInfo.processInfo.arguments.contains("--show-help-glossary"),
                   let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                   let window = scene.windows.first(where: \.isKeyWindow) {
                    let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try snapshot.pngData()?.write(to: directory.appendingPathComponent("help-glossary.png"))
                }
                // Dedicated launch mode only; this does not toggle system recording.
                diagnosticCaptureActive = true; updateCaptureState(true); guidanceRequested = true
                transport.setActive(true)
                var cases: [[String: Any]] = []
                var preselectionWithdrawn = false
                for (name, filename, expectedPot, expectedCall) in [("two-pair", "t022.png", 350, 0), ("call-amount", "t065.png", 950, 320)] {
                    let path = documents.appendingPathComponent("LiveReadoutFixtures/" + filename).path
                    guard let image = UIImage(contentsOfFile: path)?.cgImage else { throw PokerError.invalid("缺少本地录屏测试帧：" + filename) }
                    let began = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<50 {
                        transport.offer(image)
                        try await Task.sleep(for: .milliseconds(100))
                        let facts = factsGate.current(now: ProcessInfo.processInfo.systemUptime)
                        if cardGate.position != nil, decisionResult?.suggested != nil,
                           facts?.pot == expectedPot, (facts?.call ?? 0) == expectedCall,
                           ProcessInfo.processInfo.systemUptime - began >= 1 { break }
                    }
                    let now = ProcessInfo.processInfo.systemUptime, facts = factsGate.current(now: now)
                    let decision = decisionResult
                    let observation = decisionGate.current(now: now)
                    let actionLegal: Bool
                    switch decision?.suggested {
                    case .bet(let chips): actionLegal = name == "two-pair" && [120, 180, 230, 350, 420].contains(chips)
                    case .check: actionLegal = name == "two-pair"
                    case .fold: actionLegal = name == "call-amount"
                    case .call(let chips): actionLegal = name == "call-amount" && chips == 320
                    case .raiseTo(let total, let added):
                        actionLegal = name == "call-amount" && [740, 960, 1200, 1600, 1800].contains(total)
                            && observation?.actions.visibleRaiseToAmounts.contains(total) == true
                            && added == total - (observation?.actions.heroStreetCommitted ?? -1)
                    case nil: actionLegal = false
                    }
                    let expectedCards: [String?] = name == "two-pair" ? ["Kh", "Qs", "7h", "Qd", "Ks", nil, nil] : ["Td", "7c", "8h", "Qh", "Jc", nil, nil]
                    let winRange = decision?.outrightWinProbabilityRange ?? []
                    let checks = ["recognizedCards": cardGate.slots == expectedCards,
                                  "winAvailable": winRange.count == 2 && winRange.allSatisfy { (0...1).contains($0) },
                                  "recommendationAvailable": decision?.suggested != nil, "legalObservedAction": actionLegal,
                                  "heroTurnConfirmed": observation?.actions.heroTurnConfirmed == true,
                                  "completeBetComparison": name != "two-pair" || decision?.betComparisons.count == 45,
                                  "potCorrect": facts?.pot == expectedPot, "callCorrect": (facts?.call ?? 0) == expectedCall,
                                  "foldedSeats": facts?.foldedSeats.count == 6, "cardsFresh": now - cardGate.lastTimestamp <= 0.8]
                    cases.append(["case": name, "checks": checks, "hero": heroCards, "board": boardCards,
                                  "analysis": analysisLabel, "betting": bettingLabel, "cardScan": timingLabel,
                                  "ocrMilliseconds": lastPublicMilliseconds,
                                  "decisionMilliseconds": decision?.elapsedMilliseconds ?? -1,
                                  "expectedTitle": decision?.actionLabel ?? "", "expectedSubtitle": decision.map(Self.decisionSubtitle) ?? "",
                                  "winRange": winRange, "tieRange": decision?.tieProbabilityRange ?? [],
                                  "mainWinProbability": decision?.mainOutrightWinProbability ?? -1,
                                  "mainTieProbability": decision?.mainTieProbability ?? -1,
                                  "equityRange": decision?.equityRange ?? [], "reason": decision?.reason ?? "",
                                  "candidateBetAmounts": observation?.actions.visibleBetAmounts ?? [],
                                  "candidateRaiseToAmounts": observation?.actions.visibleRaiseToAmounts ?? [],
                                  "firstStableReadoutMilliseconds": (now - began) * 1000])
                    for _ in 0..<30 {
                        transport.offer(image)
                        try await Task.sleep(for: .milliseconds(100))
                        if pip.active { break }
                    }
                    try await pip.exportRenderProbe(to: directory.appendingPathComponent(name))
                    if name == "two-pair" {
                        guard let waiting = UIImage(contentsOfFile: documents.appendingPathComponent("LiveReadoutFixtures/t020.png").path)?.cgImage else {
                            throw PokerError.invalid("缺少相同牌面预选按钮回归帧")
                        }
                        // Same cards/pot, but another player is acting: the previous bet must disappear.
                        for _ in 0..<18 { transport.offer(waiting); try await Task.sleep(for: .milliseconds(100)) }
                        preselectionWithdrawn = cardGate.slots == expectedCards && cardGate.position != nil && decisionResult == nil
                            && decisionGate.current(now: ProcessInfo.processInfo.systemUptime)?.actions.heroTurnConfirmed == false
                        try await pip.exportRenderProbe(to: directory.appendingPathComponent("preselection"))
                    }
                }
                guard let dealing = UIImage(contentsOfFile: documents.appendingPathComponent("LiveReadoutFixtures/dealing.jpg").path)?.cgImage else {
                    throw PokerError.invalid("缺少转牌飞入回归帧")
                }
                for _ in 0..<12 { transport.offer(dealing); try await Task.sleep(for: .milliseconds(100)) }
                let dealingWithdrawn = cardGate.position == nil && decisionResult == nil && scanIssue?.title == "等待发牌完成"
                try await pip.exportRenderProbe(to: directory.appendingPathComponent("dealing"))
                var aceCases: [[String: Any]] = []
                let aceFixtures: [(String, [String?])] = [
                    ("ace-hero.png", ["Ac", "Jc", nil, nil, nil, nil, nil]),
                    ("ace-board.png", ["Jd", "4d", "As", "Jh", "9d", nil, nil])
                ]
                for (filename, expected) in aceFixtures {
                    guard let image = UIImage(contentsOfFile: documents.appendingPathComponent("LiveReadoutFixtures/" + filename).path)?.cgImage else {
                        throw PokerError.invalid("缺少真实 A 回归帧")
                    }
                    for _ in 0..<35 {
                        transport.offer(image); try await Task.sleep(for: .milliseconds(100))
                        if cardGate.slots == expected, cardGate.position != nil, scanIssue == nil { break }
                    }
                    aceCases.append(["file": filename, "cardsCorrect": cardGate.slots == expected && cardGate.position != nil && scanIssue == nil,
                                     "cardScan": timingLabel])
                }
                var screenshotCases: [[String: Any]] = []
                for (filename, expected): (String, [String?]) in [
                    ("five-preflop.jpg", ["5h", "4h", nil, nil, nil, nil, nil]),
                    ("ten-flop.jpg", ["As", "2c", "4s", "Ts", "9d", nil, nil])
                ] {
                    guard let image = UIImage(contentsOfFile: documents.appendingPathComponent("LiveReadoutFixtures/" + filename).path)?.cgImage else {
                        throw PokerError.invalid("缺少用户新截图：" + filename)
                    }
                    let began = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<50 {
                        transport.offer(image); try await Task.sleep(for: .milliseconds(100))
                        if cardGate.slots == expected, cardGate.position != nil, scanIssue == nil,
                           decisionResult?.suggested != nil { break }
                    }
                    let facts = factsGate.current(now: ProcessInfo.processInfo.systemUptime)
                    let expectedCall = filename == "five-preflop.jpg" ? 250 : 460
                    let observation = decisionGate.current(now: ProcessInfo.processInfo.systemUptime)
                    let legalObservedAction: Bool
                    switch decisionResult?.suggested {
                    case .fold: legalObservedAction = observation?.actions.foldAvailable == true
                    case .call(let amount): legalObservedAction = amount == expectedCall && observation?.actions.callAmount == expectedCall
                    default: legalObservedAction = false
                    }
                    screenshotCases.append(["file": filename,
                        "cardsCorrect": cardGate.slots == expected && cardGate.position != nil && scanIssue == nil,
                        "validationIssue": cardGate.validationIssue ?? "", "cardScan": timingLabel,
                        "decisionAvailable": decisionResult?.suggested != nil,
                        "legalObservedAction": legalObservedAction,
                        "observedCallCorrect": observation?.actions.callAmount == expectedCall,
                        "heroTurnConfirmed": observation?.actions.heroTurnConfirmed == true,
                        "amountsCorrect": filename == "five-preflop.jpg" ? (facts?.pot == 920 && facts?.call == 250) : (facts?.pot == 1370 && facts?.call == 460),
                        "emptyBoardConfirmed": emptyBoardGate.confirmed(now: ProcessInfo.processInfo.systemUptime),
                        "expectedTitle": decisionResult?.actionLabel ?? "", "expectedSubtitle": decisionResult.map(Self.decisionSubtitle) ?? "",
                        "winRange": decisionResult?.outrightWinProbabilityRange ?? [],
                        "publicReason": lastPublicEvidence?.actionControls.reason ?? "公开字段未交付",
                        "rawCall": lastPublicEvidence?.raw["call"] ?? "", "callScore": lastPublicEvidence?.scores["call"] ?? 0,
                        "pot": facts?.pot ?? -1, "call": facts?.call ?? -1,
                        "ocrMilliseconds": lastPublicMilliseconds, "decisionMilliseconds": decisionResult?.elapsedMilliseconds ?? -1,
                        "firstStableReadoutMilliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1000])
                    try await pip.exportRenderProbe(to: directory.appendingPathComponent(filename == "five-preflop.jpg" ? "preflop-action" : "ten-flop-action"))
                }
                guard let settlement = UIImage(contentsOfFile: documents.appendingPathComponent("LiveReadoutFixtures/settlement.jpg").path)?.cgImage else {
                    throw PokerError.invalid("缺少用户结算截图")
                }
                for _ in 0..<18 { transport.offer(settlement); try await Task.sleep(for: .milliseconds(100)) }
                let settlementWithdrawn = settledAt != nil && scanIssue == nil && cardGate.position == nil && decisionResult == nil && estimates.isEmpty
                try await pip.exportRenderProbe(to: directory.appendingPathComponent("settlement"))
                // Clear only one printed rank in the recorded fixture. Keep the white card and suit visible.
                // This must withdraw the old equity, retain the precise reason across timer ticks, then recover.
                guard let source = UIImage(contentsOfFile: documents.appendingPathComponent("LiveReadoutFixtures/t065.png").path),
                      let original = source.cgImage else { throw PokerError.invalid("缺少遮挡回归测试帧") }
                let size = CGSize(width: original.width, height: original.height)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let obscured = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    source.draw(in: CGRect(origin: .zero, size: size))
                    UIColor.white.setFill()
                    context.fill(CGRect(x: size.width * 86 / 220, y: size.height * 397 / 480,
                                        width: size.width * 24 / 220, height: size.height * 36 / 480 * 0.49))
                }.cgImage!
                for _ in 0..<22 { transport.offer(obscured); try await Task.sleep(for: .milliseconds(100)) }
                let issueStayedVisible = scanIssue?.title == "第1张底牌未读清"
                let blockedEstimateWithdrawn = cardGate.position == nil && estimates.isEmpty && decisionResult == nil
                try await pip.exportRenderProbe(to: directory.appendingPathComponent("obscured"))
                for _ in 0..<40 {
                    transport.offer(original); try await Task.sleep(for: .milliseconds(100))
                    if scanIssue == nil, cardGate.position != nil, decisionResult?.suggested != nil,
                       factsGate.current(now: ProcessInfo.processInfo.systemUptime)?.call == 320 { break }
                }
                let recovered = scanIssue == nil && cardGate.position != nil && decisionResult?.suggested != nil
                try await Task.sleep(for: .seconds(1.1))
                try await pip.exportRenderProbe(to: directory.appendingPathComponent("stale"))
                let report: [String: Any] = ["mode": "production CMSampleBuffer encoder → isolated test-port TCP → receiver → session gate → recognition → PiP; no ReplayKit capture", "cases": cases,
                                           "receivedFrames": receivedFrames, "admittedFrames": admittedFrames,
                                           "consumedFrames": consumedFrames, "receivedHealth": transportHealth != nil,
                                           "issueStayedVisible": issueStayedVisible, "blockedEstimateWithdrawn": blockedEstimateWithdrawn,
                                           "recognitionRecovered": recovered,
                                           "preselectionWithdrawn": preselectionWithdrawn,
                                           "dealingWithdrawn": dealingWithdrawn,
                                           "aceCases": aceCases,
                                           "screenshotCases": screenshotCases, "settlementWithdrawn": settlementWithdrawn,
                                           "staleEstimateWithdrawn": cardGate.position == nil && estimates.isEmpty && decisionResult == nil, "pipActive": pip.active]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("analysis.json"))
            } catch {
                try? Data(String(describing: error).utf8).write(to: directory.appendingPathComponent("error.txt"))
            }
        }
    }
    /// Explicit launch argument for local regression; does not begin ReplayKit screen recording.
    private func runRenderProbe() {
        Task {
            let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PiPRenderProbe-" + version)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Task.sleep(for: .seconds(2))
                // Snapshot only this App's own view hierarchy for a focused home-layout review.
                if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                   let window = scene.windows.first(where: \.isKeyWindow) {
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try image.pngData()?.write(to: directory.appendingPathComponent("home-view.png"))
                }
                self.pip.setIdleScreen(false)
                try await Task.sleep(for: .milliseconds(300))
                try await self.pip.exportRenderProbe(to: directory.appendingPathComponent("inline"))
                self.pip.start()
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(200))
                    if self.pip.active || self.pip.error != nil { break }
                }
                try await self.pip.exportRenderProbe(to: directory.appendingPathComponent("floating"))
                self.pip.stop()
                try await Task.sleep(for: .seconds(1))
                try await self.pip.exportRenderProbe(to: directory.appendingPathComponent("returned"))
                self.pip.setIdleScreen(!self.isScreenCaptured)
            } catch { try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt")) }
        }
    }
}
private struct ScanIssue {
    let signature: String
    let regions: [String]
    let error: String?
    let beganAt: Double
    var canTeach: Bool
    var title: String {
        if error == "发牌动画结束后自动更新" { return "等待发牌完成" }
        if error == "请回到无遮挡牌桌" { return "牌桌画面被遮挡" }
        if error != nil { return "当前画面无法识别" }
        guard regions.count == 1, let region = regions.first,
              let number = Int(region.split(separator: ".").last ?? "") else { return "\(regions.count)张牌未读清" }
        return "第\(number + 1)张" + (region.hasPrefix("hero") ? "底牌" : "公共牌") + "未读清"
    }
    func subtitle(now: Double) -> String {
        if let error { return error }
        if now - beganAt < 2 { return "自动重试中 · 暂停估算" }
        return canTeach ? "字形未匹配 · 帮助中补牌" : "移开遮挡 · 自动重新识别"
    }
}
private struct EstimateKey: Hashable, Sendable {
    let position: LiveCardPosition
    let opponents: Int
}

private struct PublicReadPacket {
    let timestamp: Double
    let cards: [String?]
    let evidence: PublicStateEvidence?
    let milliseconds: Double
    let sessionGeneration: UInt64
    var image: CGImage? = nil
}

/// OCR runs independently at at most 4 Hz; it never queues behind the fast card reader.
private final class PublicReadWorker {
    var onResult: ((PublicReadPacket) -> Void)?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lgj.pokercoach.public-fields", qos: .utility)
    private let reader = WPKPublicStateReader()
    private var cards: FourColorCardReader?
    private var active = false
    private var busy = false
    private var pending: (CGImage, Double, Int, UInt64)?
    private var generation = 0
    private var lastOffered = 0.0
    func setActive(_ value: Bool) {
        lock.lock(); active = value; pending = nil; generation += 1; lastOffered = 0; lock.unlock()
    }
    func offer(_ image: CGImage, at timestamp: Double, sessionGeneration: UInt64) {
        lock.lock()
        guard active, timestamp - lastOffered >= 0.25 else { lock.unlock(); return }
        lastOffered = timestamp; pending = (image, timestamp, generation, sessionGeneration)
        let schedule = !busy; busy = true; lock.unlock()
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock()
        guard active, let frame = pending else { busy = false; pending = nil; lock.unlock(); return }
        pending = nil; lock.unlock()
        let (image, timestamp, token, sessionGeneration) = frame
        let started = ProcessInfo.processInfo.systemUptime
        if started - timestamp <= 0.8 {
            let packet: PublicReadPacket = autoreleasepool {
                do {
                    guard abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035 else { throw PokerError.invalid("布局未适配") }
                    guard !WPKSceneGate.hasWhitePanelObstruction(image) else { throw PokerError.invalid("请回到无遮挡牌桌") }
                    guard !WPKSceneGate.hasBoardDealingAnimation(image) else { throw PokerError.invalid("发牌动画结束后自动更新") }
                    guard !WPKSceneGate.hasHeroWinSettlement(image) else { throw PokerError.invalid("本手已结束") }
                    if cards == nil { cards = try FourColorCardReader.wpkVideoProfile() }
                    // Re-read cards from this exact image to prevent mixing a previous street's amounts with a new board.
                    let cardEvidence = try cards!.read(image, regions: WPKVideoLayout.cardRegions)
                    guard !cardEvidence.contains(where: \.hasUnresolvedCard) else { throw PokerError.invalid("牌张未读清") }
                    let slots = cardEvidence.map(\.card)
                    if slots.dropFirst(2).allSatisfy({ $0 == nil }), !WPKBoardPresence.hasEmptyBoardArea(image) {
                        throw PokerError.invalid("公共牌区域尚未确认为空")
                    }
                    let evidence = try reader.read(image)
                    return PublicReadPacket(timestamp: timestamp, cards: slots, evidence: evidence, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, sessionGeneration: sessionGeneration, image: image)
                } catch { return PublicReadPacket(timestamp: timestamp, cards: [], evidence: nil, milliseconds: 0, sessionGeneration: sessionGeneration) }
            }
            lock.lock(); let deliver = active && token == generation; lock.unlock()
            if deliver { onResult?(packet) }
        }
        queue.async { [weak self] in self?.drain() }
    }
}

private struct ScanPacket {
    let timestamp: Double; let width: Int; let height: Int
    let evidence: [CardReadEvidence]; let milliseconds: Double; let error: String?
    let sessionGeneration: UInt64
    let learningSamples: [RankLearningSample]?
    var settled: Bool = false
    var verifiedEmptyBoard: Bool = false
}

/// A bounded latest-frame mailbox: one recognition job plus one replaceable pending frame.
private final class CardScanWorker {
    var onResult: ((ScanPacket) -> Void)?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lgj.pokercoach.cards", qos: .userInitiated)
    private var lastLearningAt = 0.0
    private var active = false
    private var busy = false
    private var pending: (CGImage, Double, Int, UInt64)?
    private var generation = 0
    private var reader: FourColorCardReader?
    func setActive(_ value: Bool) {
        lock.lock(); active = value; pending = nil; generation += 1; lock.unlock()
    }
    func offer(_ image: CGImage, at timestamp: Double, sessionGeneration: UInt64) {
        lock.lock()
        guard active else { lock.unlock(); return }
        pending = (image, timestamp, generation, sessionGeneration)
        let schedule = !busy; busy = true; lock.unlock()
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock()
        guard active, let frame = pending else { busy = false; pending = nil; lock.unlock(); return }
        pending = nil; lock.unlock()
        let (image, timestamp, token, sessionGeneration) = frame
        let started = ProcessInfo.processInfo.systemUptime
        if started - timestamp <= 0.8 {
            let packet: ScanPacket = autoreleasepool {
                do {
                    guard abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035 else { throw PokerError.invalid("使用视频同款竖屏牌桌") }
                    guard !WPKSceneGate.hasWhitePanelObstruction(image) else { throw PokerError.invalid("请回到无遮挡牌桌") }
                    guard !WPKSceneGate.hasBoardDealingAnimation(image) else { throw PokerError.invalid("发牌动画结束后自动更新") }
                    if WPKSceneGate.hasHeroWinSettlement(image) {
                        return ScanPacket(timestamp: timestamp, width: image.width, height: image.height,
                                          evidence: [], milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                          error: nil, sessionGeneration: sessionGeneration, learningSamples: nil, settled: true)
                    }
                    if reader == nil { reader = try FourColorCardReader.wpkVideoProfile() }
                    let evidence = try reader!.read(image, regions: WPKVideoLayout.cardRegions)
                    let emptyBoard = evidence.dropFirst(2).allSatisfy { $0.card == nil && !$0.hasUnresolvedCard }
                        && WPKBoardPresence.hasEmptyBoardArea(image)
                    var samples: [RankLearningSample]?
                    if timestamp - lastLearningAt >= 0.5 || evidence.contains(where: \.hasUnresolvedCard) {
                        samples = RankLearningSample.capture(image, evidence: evidence); lastLearningAt = timestamp
                    }
                    return ScanPacket(timestamp: timestamp, width: image.width, height: image.height, evidence: evidence,
                                      milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, error: nil,
                                      sessionGeneration: sessionGeneration, learningSamples: samples, verifiedEmptyBoard: emptyBoard)
                } catch {
                    return ScanPacket(timestamp: timestamp, width: image.width, height: image.height, evidence: [], milliseconds: 0,
                                      error: String(describing: error), sessionGeneration: sessionGeneration, learningSamples: nil)
                }
            }
            lock.lock(); let deliver = active && token == generation; lock.unlock()
            if deliver { onResult?(packet) }
        }
        queue.async { [weak self] in self?.drain() }
    }
}
