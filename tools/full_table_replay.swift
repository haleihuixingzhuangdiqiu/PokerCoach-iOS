import Foundation
import ImageIO
import PokerCoachCapture
import PokerCoachCore

/// Compile with iOS/PokerCoachApp/WPKFullTableAdapter.swift. Timestamp is the
/// preserved video's 2-fps media time; OCR duration is separately recorded.
@main struct FullTableReplay {
    static func main() throws {
        let cards = try FourColorCardReader.wpkVideoProfile()
        let full = WPKTableSnapshotReader(), fields = WPKPublicStateReader()
        var ledger = PublicHandLedger(), openingGate = OpeningSnapshotGate(), rows: [[String: Any]] = []
        var lastRequest: FullStrategyRequest?
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path), begin = ProcessInfo.processInfo.systemUptime
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PokerError.invalid("无法加载录像帧") }
            var row: [String: Any] = ["file": url.lastPathComponent]
            let frame = Double(url.deletingPathExtension().lastPathComponent) ?? Double(rows.count)
            let timestamp = 1 + frame / 2
            do {
                if WPKSceneGate.hasHeroWinSettlement(image) { ledger.reset(); openingGate.reset(); throw PokerError.invalid("本手已结束") }
                if WPKSceneGate.hasBoardDealingAnimation(image) { throw PokerError.invalid("发牌动画") }
                let cardEvidence = try cards.read(image, regions: WPKVideoLayout.cardRegions)
                guard !cardEvidence.contains(where: \.hasUnresolvedCard) else { throw PokerError.invalid("牌张未读全") }
                let position = try LiveCardPosition(slots: cardEvidence.map(\.card))
                if position.board.isEmpty && !WPKBoardPresence.hasEmptyBoardArea(image) { throw PokerError.invalid("不能证实公共牌区为空") }
                let publicEvidence = try fields.read(image), control = publicEvidence.actionControls
                let facts = PublicBettingFacts(raw: publicEvidence.raw, scores: publicEvidence.scores,
                    callControlVisible: publicEvidence.callControlVisible)
                let raw = try full.read(image)
                let snapshot = try WPKFullTableAdapter.snapshot(raw, position: position, heroTurn: control.heroTurnConfirmed)
                let amounts = control.raiseCandidates.filter { $0.confidence >= 0.9 }
                let actions = VisiblePassiveActions(heroTurnConfirmed: control.heroTurnConfirmed,
                    foldAvailable: control.canFold, checkAvailable: control.canCheck,
                    callAmount: control.callConfidence >= 0.9 ? control.callAmountText.flatMap { try? ChipAmountParser.parse($0) } : nil,
                    visibleBetAmounts: amounts.filter { $0.meaning == .bet }.compactMap { try? ChipAmountParser.parse($0.amountText) },
                    heroStreetCommitted: control.heroWagerAreaClear ? 0 : control.heroWager.flatMap { $0.confidence >= 0.9 ? try? ChipAmountParser.parse($0.amountText) : nil },
                    visibleRaiseToAmounts: amounts.filter { $0.meaning == .raiseTo }.compactMap { try? ChipAmountParser.parse($0.amountText) })
                row["ocrMilliseconds"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                row["heroTurn"] = control.heroTurnConfirmed; row["controlReason"] = control.reason
                row["cards"] = position.hero.cards.map(\.description) + position.board.map(\.description)
                row["unknownStacks"] = snapshot.seats.filter { $0.stack == nil }.map(\.id)
                row["unknownWagers"] = snapshot.seats.filter { $0.streetWager == nil }.map(\.id)
                row["unknownFoldStatus"] = snapshot.seats.filter { $0.folded == nil }.map(\.id)
                row["button"] = snapshot.button ?? -1; row["straddle"] = snapshot.straddleSeat ?? -1
                row["pot"] = snapshot.pot ?? -1; row["rulesRead"] = snapshot.rules != nil
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
                    row["fullStrategyEligible"] = true
                    if request != lastRequest {
                        let model: PublicActionRangeResult
                        switch request {
                        case .continuous(let verified): model = try PublicActionRangeModel.analyze(hand: verified.hand)
                        case .opening(let opening, _): model = try PublicActionRangeModel.analyze(opening: opening)
                        }
                        let decision = try FullHandDecisionEngine.analyze(state: request.state, hero: request.hero,
                            cards: request.cards, ranges: model.ranges, allowedActions: request.allowedActions,
                            budget: .init(samples: 512, milliseconds: 2_000))
                        row["action"] = request.actionLabel(decision)
                        row["subtitle"] = request.subtitle(decision)
                        row["rangeModel"] = model.label
                        row["decisionMilliseconds"] = decision.elapsedMilliseconds
                        row["rangeMilliseconds"] = model.elapsedMilliseconds
                        row["samples"] = decision.samplesPerScenario
                        row["means"] = decision.actions.map { ["action": $0.action.description, "EV": $0.expectedEV] as [String: Any] }
                        lastRequest = request
                    }
                } else { row["fullStrategyEligible"] = false }
            } catch { row["error"] = String(describing: error) }
            rows.append(row)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
