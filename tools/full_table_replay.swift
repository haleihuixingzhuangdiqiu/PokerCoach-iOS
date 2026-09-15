import Foundation
import ImageIO
import PokerCoachCapture
import PokerCoachCore

/// Compile with iOS/PokerCoachApp/WPKFullTableAdapter.swift. Timestamp is the
/// preserved video's 2-fps media time; OCR duration is separately recorded.
/// This is an offline structural audit, not a live scheduling/latency simulation.
@main struct FullTableReplay {
    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    private static func source(_ action: PokerAction, control: WPKActionControlEvidence) throws -> [String: Any] {
        var result: [String: Any] = ["action": try json(action), "description": action.description]
        switch action {
        case .fold: result["source"] = "observedFoldButton"
        case .check: result["source"] = "observedCheckButton"
        case .call:
            result["source"] = "observedAdditionalCallButton"
            result["amountText"] = control.callAmountText ?? ""
            result["confidence"] = control.callConfidence
        case .raiseTo(let total):
            result["source"] = "observedEnabledPreset"
            result["candidates"] = try json(control.raiseCandidates.filter {
                $0.confidence >= 0.9 && (try? ChipAmountParser.parse($0.amountText)) == total
            })
        }
        return result
    }
    static func main() throws {
        let cards = try FourColorCardReader.wpkVideoProfile()
        let full = WPKTableSnapshotReader(), fields = WPKPublicStateReader()
        var ledger = PublicHandLedger(), openingGate = OpeningSnapshotGate(), rows: [[String: Any]] = []
        var lastRequest: FullStrategyRequest?
        var lastDecision: DecisionResult?
        var lastRangeLabel = ""
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path), begin = ProcessInfo.processInfo.systemUptime
            var row: [String: Any] = ["file": url.lastPathComponent, "schemaVersion": 2,
                "notRealtime": true, "replayMode": "offlineStructural2fps",
                "heroTurnObserved": NSNull(), "structurallyEligible": false,
                "fullStrategyEligible": false, "adviceAvailable": false, "decisionCacheHit": false]
            let frame = Double(url.deletingPathExtension().lastPathComponent) ?? Double(rows.count)
            let timestamp = 1 + frame / 2
            row["mediaTimestamp"] = timestamp
            var stage = "image"
            do {
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw PokerError.invalid("无法加载录像帧") }
                // Read control evidence independently of card/full-table success so
                // failed-card frames are not silently dropped from the denominator.
                stage = "publicControls"
                let publicEvidence = try fields.read(image), control = publicEvidence.actionControls
                row["heroTurnObserved"] = control.heroTurnConfirmed
                row["observedControls"] = try json(control)
                row["controlReason"] = control.reason
                row["publicFields"] = publicEvidence.raw
                row["publicFieldScores"] = publicEvidence.scores
                stage = "sceneAndCards"
                if WPKSceneGate.hasHeroWinSettlement(image) { ledger.reset(); openingGate.reset(); throw PokerError.invalid("本手已结束") }
                if WPKSceneGate.hasBoardDealingAnimation(image) { throw PokerError.invalid("发牌动画") }
                let cardEvidence = try cards.read(image, regions: WPKVideoLayout.cardRegions)
                guard !cardEvidence.contains(where: \.hasUnresolvedCard) else { throw PokerError.invalid("牌张未读全") }
                let position = try LiveCardPosition(slots: cardEvidence.map(\.card))
                if position.board.isEmpty && !WPKBoardPresence.hasEmptyBoardArea(image) { throw PokerError.invalid("不能证实公共牌区为空") }
                let facts = PublicBettingFacts(raw: publicEvidence.raw, scores: publicEvidence.scores,
                    callControlVisible: publicEvidence.callControlVisible)
                stage = "fullTable"
                let raw = try full.read(image)
                let snapshot = try WPKFullTableAdapter.snapshot(raw, position: position, heroTurn: control.heroTurnConfirmed)
                let actions = WPKFullTableAdapter.controls(control)
                row["ocrMilliseconds"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                row["heroTurn"] = control.heroTurnConfirmed; row["controlReason"] = control.reason
                row["cards"] = position.hero.cards.map(\.description) + position.board.map(\.description)
                row["unknownStacks"] = snapshot.seats.filter { $0.stack == nil }.map(\.id)
                row["unknownWagers"] = snapshot.seats.filter { $0.streetWager == nil }.map(\.id)
                row["unknownFoldStatus"] = snapshot.seats.filter { $0.folded == nil }.map(\.id)
                row["button"] = snapshot.button ?? -1; row["straddle"] = snapshot.straddleSeat ?? -1
                row["pot"] = snapshot.pot ?? -1; row["rulesRead"] = snapshot.rules != nil
                row["snapshotSeats"] = try json(snapshot.seats)
                row["snapshotActor"] = snapshot.actor.map { $0 as Any } ?? NSNull()
                stage = "stateReconciliation"
                ledger.ingest(snapshot, timestamp: timestamp, now: timestamp)
                openingGate.ingest(snapshot, timestamp: timestamp, now: timestamp)
                row["openingStatus"] = openingGate.status
                row["ledgerStatus"] = ledger.status
                row["verified"] = ledger.current(now: timestamp) != nil
                row["recordedActions"] = ledger.hand?.actions.count ?? 0
                let request: FullStrategyRequest?
                if let hand = ledger.current(now: timestamp),
                   let verified = try? FullHandDecisionRequest(hand: hand, controls: actions, observedPot: facts.pot) {
                    request = .continuous(verified)
                } else if let opening = openingGate.current(now: timestamp) {
                    request = try? .init(opening: opening, controls: actions, observedPot: facts.pot)
                } else { request = nil }
                if let request {
                    row["strategySource"] = request.sourceID
                    row["structurallyEligible"] = true
                    row["state"] = try json(request.state)
                    row["hero"] = request.hero
                    row["allowedActions"] = try json(request.allowedActions)
                    row["allowedActionSources"] = try request.allowedActions.map { try source($0, control: control) }
                    switch request {
                    case .continuous(let verified):
                        row["actionTraceSource"] = "uniqueLegalReplayFromObservedForcedBets"
                        row["actionTrace"] = try json(verified.hand.actions)
                        row["actionSequenceUnique"] = verified.hand.actionSequenceUnique
                    case .opening(let opening, _):
                        row["actionTraceSource"] = "inferredSingleOpeningSnapshot"
                        row["historyComplete"] = false
                        row["actionTrace"] = try opening.inferredActions.map {
                            ["seatID": $0.seatID, "action": try json($0.action)] as [String: Any]
                        }
                    }
                    let decision: DecisionResult
                    stage = "decision"
                    if request == lastRequest, let cached = lastDecision {
                        decision = cached
                        row["decisionCacheHit"] = true
                        row["cachedAction"] = request.actionLabel(cached)
                        row["decisionMilliseconds"] = 0
                        row["rangeMilliseconds"] = 0
                        row["cachedDecisionMilliseconds"] = cached.elapsedMilliseconds
                    } else {
                        let model: PublicActionRangeResult
                        switch request {
                        case .continuous(let verified): model = try PublicActionRangeModel.analyze(hand: verified.hand)
                        case .opening(let opening, _): model = try PublicActionRangeModel.analyze(opening: opening)
                        }
                        decision = try FullHandDecisionEngine.analyze(state: request.state, hero: request.hero,
                            cards: request.cards, ranges: model.ranges, allowedActions: request.allowedActions,
                            budget: .init(samples: 512, milliseconds: 2_000))
                        row["decisionMilliseconds"] = decision.elapsedMilliseconds
                        row["rangeMilliseconds"] = model.elapsedMilliseconds
                        lastRangeLabel = model.label
                    }
                    guard request.allowedActions.contains(decision.suggested) else {
                        throw PokerError.invalid("策略输出不在已核对屏幕动作中")
                    }
                    row["action"] = request.actionLabel(decision)
                    row["subtitle"] = request.subtitle(decision)
                    row["rangeModel"] = lastRangeLabel
                    row["decision"] = try json(decision)
                    row["samples"] = decision.samplesPerScenario
                    row["means"] = decision.actions.map { ["action": $0.action.description, "EV": $0.expectedEV] as [String: Any] }
                    row["selectedActionSource"] = try source(decision.suggested, control: control)
                    row["fullStrategyEligible"] = true
                    row["adviceAvailable"] = true
                    lastRequest = request; lastDecision = decision
                } else {
                    lastRequest = nil; lastDecision = nil; lastRangeLabel = ""
                }
            } catch {
                ledger.ingestUnreadable(timestamp: timestamp, now: timestamp)
                openingGate.ingestUnreadable(timestamp: timestamp, now: timestamp)
                lastRequest = nil; lastDecision = nil; lastRangeLabel = ""
                row["error"] = String(describing: error); row["failureStage"] = stage
                row["fullStrategyEligible"] = false; row["adviceAvailable"] = false
                row.removeValue(forKey: "action"); row.removeValue(forKey: "cachedAction")
                row["ledgerStatusAfterFailure"] = ledger.status
                row["openingStatusAfterFailure"] = openingGate.status
            }
            row["processingMilliseconds"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            rows.append(row)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
