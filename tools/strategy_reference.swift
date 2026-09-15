import Foundation
import PokerCoachCore

func facts(_ values: [String: String], folds: Int) -> PublicBettingFacts {
    var raw = values
    for seat in 0..<folds { raw["seat.\(seat)"] = "弃牌" }
    return PublicBettingFacts(raw: raw, scores: raw.mapValues { _ in Float(1) }, callControlVisible: values["call"] != nil)
}
let cases: [(String, ResearchDecisionRequest)] = [
    ("two-pair", .init(position: try .init(slots: ["Kh", "Qs", "7h", "Qd", "Ks", nil, nil]),
        facts: facts(["pot": "3.5", "settled": "3.5", "stack": "48.8"], folds: 6),
        actions: .init(heroTurnConfirmed: true, foldAvailable: true, checkAvailable: true,
            visibleBetAmounts: [120, 180, 230, 350, 420], heroStreetCommitted: 0), knownHeadsUpOpponentStack: 20273)),
    ("call-amount", .init(position: try .init(slots: ["Td", "7c", "8h", "Qh", "Jc", nil, nil]),
        facts: facts(["pot": "9.5", "settled": "6.3", "call": "3.2", "stack": "52.83"], folds: 6),
        actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 320, heroStreetCommitted: 0,
            visibleRaiseToAmounts: [740, 960, 1200, 1600, 1800]), knownHeadsUpOpponentStack: 3756)),
    ("preflop-action", .init(position: try .init(slots: ["5h", "4h", nil, nil, nil, nil, nil]),
        facts: facts(["pot": "9.2", "call": "2.5", "stack": "41.1"], folds: 5),
        actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 250))),
    ("ten-flop-action", .init(position: try .init(slots: ["As", "2c", "4s", "Ts", "9d", nil, nil]),
        facts: facts(["pot": "13.7", "settled": "9.1", "call": "4.6", "stack": "42.1"], folds: 5),
        actions: .init(heroTurnConfirmed: true, foldAvailable: true, callAmount: 460)))
]
var records: [[String: Any]] = []
for (name, request) in cases {
    for (mode, samples) in [("default", 1000), ("reference", 20000)] {
        let result = try ResearchDecisionEngine.analyze(request, budget: .init(samplesPerScenario: samples, milliseconds: 10000))
        records.append(["case": name, "mode": mode, "action": result.actionLabel,
            "additionalChips": result.additionalChips, "mainWin": result.mainOutrightWinProbability ?? -1,
            "mainEquity": result.mainEquity ?? -1, "mainTie": result.mainTieProbability ?? -1,
            "subtitle": result.guidanceSubtitle, "reason": result.reason,
            "samplesPerScenario": result.scenarios.map { $0.equity.samples },
            "milliseconds": result.elapsedMilliseconds,
            "betComparisons": result.betComparisons.map { ["amount": $0.additionalChips, "EV": $0.value,
                "calledEquity": $0.calledEquity.equity, "fold": $0.assumedFoldProbability] as [String: Any] }])
    }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
