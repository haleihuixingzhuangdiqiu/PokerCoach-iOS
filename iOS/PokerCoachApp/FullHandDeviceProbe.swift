import Foundation
import ImageIO
import PokerCoachCore
import PokerCoachCapture

/// Explicit local-only component probe. It does not claim live ReplayKit/PiP coverage.
enum FullHandDeviceProbe {
    private struct Group {
        let id: String
        let frames: [String]
        let expectedCards: String
        let requiresHeroStraddle: Bool
    }
    private static let groups = [
        Group(id: "legacyActualAction", frames: ["0017", "0018", "0019"], expectedCards: "4c9h", requiresHeroStraddle: false),
        Group(id: "heroStraddleT7", frames: ["0102", "0103", "0104", "0105", "0106"], expectedCards: "Td7c", requiresHeroStraddle: true),
        Group(id: "heroStraddleQQ", frames: ["0161", "0162", "0163", "0164"], expectedCards: "QsQc", requiresHeroStraddle: true)
    ]

    static func run() {
        DispatchQueue.global(qos: .userInitiated).async {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let output = documents.appendingPathComponent("FullHandProbe-\(version).json")
            let fixtureDirectory = documents.appendingPathComponent("FullHandFixtures", isDirectory: true)
            var report: [String: Any] = ["version": version, "mode": "native-component-replay",
                "beganAt": ISO8601DateFormatter().string(from: Date()), "livePiPVerified": false,
                "fixtureSource": "Documents/FullHandFixtures", "automaticFixtureFallback": false,
                "timestampMode": "ordered-fixture-capture-interval-0.5s"]
            var groupReports: [String: Any] = [:], groupPassed: [String: Bool] = [:], allRows: [[String: Any]] = []
            for group in groups {
                // Isolate both bookkeeping and recognition caches between unrelated hands.
                var ledger = PublicHandLedger(), rows: [[String: Any]] = []
                let reader = WPKTableSnapshotReader(), publicReader = WPKPublicStateReader()
                var previousForced: PublicTableSnapshot?, forcedFrameCount = 0
                var forcedBetLedgerEstablished = false, heroStraddleRead = false
                var firstEstablishedFrame: String?, missingFiles: [String] = []
                do {
                    let cardReader = try FourColorCardReader.wpkVideoProfile()
                    let expectedCards = try HoleCards(group.expectedCards)
                    for (index, name) in group.frames.enumerated() {
                        let timestamp = 1 + Double(index) / 2
                        let row: [String: Any] = autoreleasepool {
                            var row: [String: Any] = ["group": group.id, "file": name, "timestamp": timestamp,
                                "read": false, "verified": false, "actionableVerified": false,
                                "heroStraddleRead": false, "forcedBetSnapshotMatched": false]
                            let began = ProcessInfo.processInfo.systemUptime
                            do {
                                let file = fixtureDirectory.appendingPathComponent("\(name).jpg")
                                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                                    missingFiles.append(name)
                                    throw PokerError.invalid("缺少或无法打开明确指定的私有录像帧 \(name)")
                                }
                                row["imageWidth"] = image.width; row["imageHeight"] = image.height
                                // Retain table diagnostics even if card parsing later rejects this frame.
                                let full = try reader.read(image)
                                row["sourceStraddleSeat"] = full.straddleSeat ?? -1
                                if let rawData = try? JSONEncoder().encode(full),
                                   let rawObject = try? JSONSerialization.jsonObject(with: rawData) { row["rawSnapshot"] = rawObject }
                                let cards = try cardReader.read(image, regions: WPKVideoLayout.cardRegions)
                                guard !cards.contains(where: \.hasUnresolvedCard) else { throw PokerError.invalid("录像帧牌张未读全") }
                                let position = try LiveCardPosition(slots: cards.map(\.card))
                                row["cards"] = position.hero.cards.map(\.description)
                                guard position.hero == expectedCards else { throw PokerError.invalid("录像帧底牌与明确指定的验收组不符") }
                                let observed = try publicReader.read(image)
                                let heroTurn = observed.actionControls.heroTurnConfirmed
                                let snapshot = try WPKFullTableAdapter.snapshot(full, position: position, heroTurn: heroTurn)
                                row["read"] = true
                                row["ocrMilliseconds"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
                                row["unknownStacks"] = snapshot.seats.filter { $0.stack == nil }.map(\.id)
                                row["unknownWagers"] = snapshot.seats.filter { $0.streetWager == nil }.map(\.id)
                                row["unknownFoldStatus"] = snapshot.seats.filter { $0.folded == nil }.map(\.id)
                                row["button"] = snapshot.button ?? -1; row["straddle"] = snapshot.straddleSeat ?? -1
                                row["rulesRead"] = snapshot.rules != nil; row["potRead"] = snapshot.pot ?? -1
                                row["heroTurn"] = heroTurn; row["actorRead"] = snapshot.actor ?? -1
                                let heroLabel = full.seats.first { $0.index == 7 }?.straddle
                                let heroLabelText = heroLabel?.rawText.lowercased().filter { $0.isLetter }
                                let hasHeroStraddle = full.straddleSeat == 7 && heroLabelText == "straddle"
                                    && (heroLabel?.confidence ?? 0) >= 0.9 && snapshot.optionalStraddle == true
                                    && snapshot.straddleSeat == snapshot.hero
                                row["heroStraddleRead"] = hasHeroStraddle
                                heroStraddleRead = heroStraddleRead || hasHeroStraddle

                                let forced = group.requiresHeroStraddle && hasHeroStraddle && matchesForcedBets(snapshot)
                                row["forcedBetSnapshotMatched"] = forced
                                if forced {
                                    forcedFrameCount = previousForced == snapshot ? forcedFrameCount + 1 : 1
                                    previousForced = snapshot
                                } else { previousForced = nil; forcedFrameCount = 0 }
                                ledger.ingest(snapshot, timestamp: timestamp, now: timestamp)
                                // With no observed actor, successful bootstrap remains private.
                                // This independent ledger is never reset: generation > 0 can
                                // only follow successful bootstrap. Require a matching pair of
                                // complete, explicitly labelled forced-bet observations as well.
                                if forcedFrameCount >= 2 && ledger.generation > 0 {
                                    forcedBetLedgerEstablished = true
                                    if firstEstablishedFrame == nil { firstEstablishedFrame = name }
                                }
                                let hand = ledger.current(now: timestamp)
                                row["verified"] = hand != nil
                                if !heroTurn { row["decisionSkipped"] = "not-hero-turn" }
                                else if let hand {
                                    do {
                                        let facts = PublicBettingFacts(raw: observed.raw, scores: observed.scores,
                                            callControlVisible: observed.callControlVisible)
                                        let request = try FullHandDecisionRequest(hand: hand,
                                            controls: WPKFullTableAdapter.controls(observed.actionControls), observedPot: facts.pot)
                                        row["requestConstructed"] = true; row["actionableVerified"] = true
                                        let model = try PublicActionRangeModel.analyze(hand: hand)
                                        let decision = try FullHandDecisionEngine.analyze(state: hand.state, hero: hand.hero,
                                            cards: hand.cards, ranges: model.ranges, allowedActions: request.allowedActions,
                                            budget: .init(samples: 256, milliseconds: 600))
                                        row["action"] = request.actionLabel(decision)
                                        row["subtitle"] = request.subtitle(decision,
                                            conditionedRanges: model.observationCounts.values.reduce(0, +) > 0)
                                        row["rangeMilliseconds"] = model.elapsedMilliseconds
                                        row["decisionMilliseconds"] = decision.elapsedMilliseconds
                                        row["samples"] = decision.samplesPerScenario
                                        row["pot"] = hand.state.pot; row["toCall"] = hand.state.amountToCall(hand.hero)
                                        row["traditionalBigBlind"] = hand.state.bigBlind; row["preflopMinimum"] = hand.state.minimumBet
                                        row["seatCount"] = hand.state.seats.count; row["liveOpponents"] = hand.state.live.count - 1
                                    } catch { row["decisionError"] = String(describing: error) }
                                } else { row["decisionSkipped"] = "ledger-not-actionable" }
                            } catch {
                                row["error"] = String(describing: error)
                                row["ocrMilliseconds"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
                                previousForced = nil; forcedFrameCount = 0
                                ledger.ingestUnreadable(timestamp: timestamp, now: timestamp)
                            }
                            row["status"] = ledger.status; row["ledgerGeneration"] = ledger.generation
                            row["consecutiveForcedFrames"] = forcedFrameCount
                            row["forcedBetLedgerEstablished"] = forcedBetLedgerEstablished
                            return row
                        }
                        rows.append(row)
                    }
                } catch {
                    // An initialization failure is contained to its group; other groups still run.
                    rows.append(["group": group.id, "error": String(describing: error), "read": false])
                }
                let actualActionPassed = rows.contains {
                    ($0["heroTurn"] as? Bool == true) && ($0["requestConstructed"] as? Bool == true)
                        && ($0["samples"] as? Int ?? 0) >= 64 && $0["pot"] as? Int == 170 && $0["toCall"] as? Int == 80
                }
                let completeFixtureSet = missingFiles.isEmpty && rows.count == group.frames.count
                let passed = completeFixtureSet && (group.requiresHeroStraddle
                    ? heroStraddleRead && forcedBetLedgerEstablished : actualActionPassed)
                var result: [String: Any] = ["passed": passed, "expectedFiles": group.frames,
                    "missingOrUnreadableFiles": missingFiles, "completeFixtureSet": completeFixtureSet,
                    "heroStraddleRead": heroStraddleRead, "forcedBetLedgerEstablished": forcedBetLedgerEstablished,
                    "actualActionPassed": actualActionPassed,
                    "actionableFrames": rows.filter { $0["actionableVerified"] as? Bool == true }.count,
                    "readErrorFrames": rows.filter { $0["error"] != nil }.count, "frames": rows]
                if let firstEstablishedFrame { result["firstEstablishedFrame"] = firstEstablishedFrame }
                groupReports[group.id] = result; groupPassed[group.id] = passed; allRows.append(contentsOf: rows)
            }
            report["groups"] = groupReports; report["groupPassed"] = groupPassed; report["frames"] = allRows
            report["passed"] = groupPassed.count == groups.count && groupPassed.values.allSatisfy { $0 }
            report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
    }

    /// Check the labelled pre-action opening directly against the rules engine.
    /// Never supplies an actor or substitutes unknown money/fold values.
    private static func matchesForcedBets(_ snapshot: PublicTableSnapshot) -> Bool {
        guard snapshot.board.isEmpty, snapshot.optionalStraddle == true,
              snapshot.straddleSeat == snapshot.hero, let rules = snapshot.rules,
              let button = snapshot.button, let pot = snapshot.pot,
              snapshot.seats.count == 8, snapshot.seats.allSatisfy({
                  $0.stack != nil && $0.streetWager != nil && $0.folded == false
              }) else { return false }
        let initialSeats = snapshot.seats.map { Seat(id: $0.id, stack: $0.stack! + $0.streetWager!) }
        guard let start = try? rules.startHand(seats: initialSeats, button: button, optionalStraddle: true),
              start.positions.straddle == snapshot.straddleSeat, start.state.pot == pot else { return false }
        return start.state.seats.indices.allSatisfy { index in
            start.state.seats[index].stack == snapshot.seats[index].stack
                && start.state.seats[index].streetCommitted == snapshot.seats[index].streetWager
        }
    }
}
