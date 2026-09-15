import Foundation
import ImageIO
import PokerCoachCore
import PokerCoachCapture

/// Explicit local-only component probe. It does not claim live ReplayKit/PiP coverage.
enum FullHandDeviceProbe {
    static func run() {
        DispatchQueue.global(qos: .userInitiated).async {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let output = documents.appendingPathComponent("FullHandProbe-\(version).json")
            var report: [String: Any] = ["version": version, "mode": "native-component-replay",
                "beganAt": ISO8601DateFormatter().string(from: Date()), "livePiPVerified": false]
            do {
                let reader = WPKTableSnapshotReader(), publicReader = WPKPublicStateReader()
                let cardReader = try FourColorCardReader.wpkVideoProfile()
                var ledger = PublicHandLedger(), rows: [[String: Any]] = []
                for (index, name) in ["0017", "0018", "0019"].enumerated() {
                    let row: [String: Any] = try autoreleasepool {
                        let file = documents.appendingPathComponent("FullHandFixtures/\(name).jpg")
                        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                            throw PokerError.invalid("缺少明确指定的私有录像帧 \(name)")
                        }
                        let began = ProcessInfo.processInfo.systemUptime
                        let evidence = try cardReader.read(image, regions: WPKVideoLayout.cardRegions)
                        guard !evidence.contains(where: \.hasUnresolvedCard) else { throw PokerError.invalid("录像帧牌张未读全") }
                        let position = try LiveCardPosition(slots: evidence.map(\.card))
                        let observed = try publicReader.read(image)
                        let full = try reader.read(image)
                        let snapshot = try WPKFullTableAdapter.snapshot(full, position: position, heroTurn: observed.actionControls.heroTurnConfirmed)
                        let ocrMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
                        let timestamp = 1 + Double(index) / 2
                        ledger.ingest(snapshot, timestamp: timestamp, now: timestamp)
                        var row: [String: Any] = ["file": name, "ocrMilliseconds": ocrMilliseconds,
                            "status": ledger.status, "verified": ledger.current(now: timestamp) != nil]
                        row["unknownStacks"] = snapshot.seats.filter { $0.stack == nil }.map(\.id)
                        row["unknownWagers"] = snapshot.seats.filter { $0.streetWager == nil }.map(\.id)
                        row["unknownFoldStatus"] = snapshot.seats.filter { $0.folded == nil }.map(\.id)
                        row["button"] = snapshot.button ?? -1; row["straddle"] = snapshot.straddleSeat ?? -1
                        row["rulesRead"] = snapshot.rules != nil; row["potRead"] = snapshot.pot ?? -1
                        row["heroTurn"] = observed.actionControls.heroTurnConfirmed
                        if let rawData = try? JSONEncoder().encode(full),
                           let rawObject = try? JSONSerialization.jsonObject(with: rawData) { row["rawSnapshot"] = rawObject }
                        if let hand = ledger.current(now: timestamp) {
                            let facts = PublicBettingFacts(raw: observed.raw, scores: observed.scores, callControlVisible: observed.callControlVisible)
                            let request = try FullHandDecisionRequest(hand: hand, controls: WPKFullTableAdapter.controls(observed.actionControls), observedPot: facts.pot)
                            let model = try PublicActionRangeModel.analyze(hand: hand)
                            let decision = try FullHandDecisionEngine.analyze(state: hand.state, hero: hand.hero,
                                cards: hand.cards, ranges: model.ranges, allowedActions: request.allowedActions,
                                budget: .init(samples: 256, milliseconds: 600))
                            row["action"] = request.actionLabel(decision)
                            row["subtitle"] = request.subtitle(decision, conditionedRanges: model.observationCounts.values.reduce(0, +) > 0)
                            row["rangeMilliseconds"] = model.elapsedMilliseconds
                            row["decisionMilliseconds"] = decision.elapsedMilliseconds
                            row["samples"] = decision.samplesPerScenario
                            row["pot"] = hand.state.pot; row["toCall"] = hand.state.amountToCall(hand.hero)
                            row["traditionalBigBlind"] = hand.state.bigBlind; row["preflopMinimum"] = hand.state.minimumBet
                            row["seatCount"] = hand.state.seats.count; row["liveOpponents"] = hand.state.live.count - 1
                        }
                        return row
                    }
                    rows.append(row)
                }
                report["frames"] = rows
                report["passed"] = rows.contains { ($0["samples"] as? Int ?? 0) >= 64 && $0["pot"] as? Int == 170 && $0["toCall"] as? Int == 80 }
            } catch { report["error"] = String(describing: error); report["passed"] = false }
            report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
    }
}
