import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("error.txt").path) else {
    FileHandle.standardError.write(Data("Probe reported an error; old results are not valid.\n".utf8)); exit(1)
}
let analysis = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("analysis.json"))) as! [String: Any]
let referenceURL = root.deletingLastPathComponent().appendingPathComponent("strategy-compact-reference.json")
let references = try JSONSerialization.jsonObject(with: Data(contentsOf: referenceURL)) as! [[String: Any]]
func matchesReference(_ name: String, _ title: String) -> Bool {
    let row = references.first { $0["case"] as? String == name && $0["mode"] as? String == "reference" }
    return row?["action"] as? String == title
}
var checks: [String: Bool] = [:]
let requiredFields = ["recognizedCards", "winAvailable", "recommendationAvailable", "legalObservedAction", "heroTurnConfirmed", "completeBetComparison", "potCorrect", "callCorrect", "foldedSeats", "cardsFresh"]
guard let cases = analysis["cases"] as? [[String: Any]], cases.count == 2,
      Set(cases.compactMap { $0["case"] as? String }) == Set(["two-pair", "call-amount"]) else {
    FileHandle.standardError.write(Data("Missing required probe cases.\n".utf8)); exit(1)
}
for item in cases {
    let name = item["case"] as! String, values = item["checks"] as? [String: Bool] ?? [:]
    for key in requiredFields { checks[name + "." + key] = values[key] == true }
}
checks["staleEstimateWithdrawn"] = analysis["staleEstimateWithdrawn"] as? Bool == true
checks["transportReceivedFrames"] = (analysis["receivedFrames"] as? Int ?? 0) > 10
checks["sessionAdmittedFrames"] = (analysis["admittedFrames"] as? Int ?? 0) > 10
checks["recognitionConsumedFrames"] = (analysis["consumedFrames"] as? Int ?? 0) > 10
checks["senderHealthReceived"] = analysis["receivedHealth"] as? Bool == true
let aceCases = analysis["aceCases"] as? [[String: Any]] ?? []
for name in ["ace-hero.png", "ace-board.png"] {
    checks[name + ".cardsCorrect"] = aceCases.first(where: { $0["file"] as? String == name })?["cardsCorrect"] as? Bool == true
}
for key in ["issueStayedVisible", "blockedEstimateWithdrawn", "recognitionRecovered", "preselectionWithdrawn", "dealingWithdrawn"] {
    checks[key] = analysis[key] as? Bool == true
}
checks["settlementWithdrawn"] = analysis["settlementWithdrawn"] as? Bool == true
let screenshotCases = analysis["screenshotCases"] as? [[String: Any]] ?? []
for filename in ["five-preflop.jpg", "ten-flop.jpg"] {
    let item = screenshotCases.first { $0["file"] as? String == filename } ?? [:]
    checks[filename + ".cardsCorrect"] = item["cardsCorrect"] as? Bool == true
    checks[filename + ".noValidationIssue"] = item["validationIssue"] as? String == ""
    checks[filename + ".amountsCorrect"] = item["amountsCorrect"] as? Bool == true
    checks[filename + ".decisionAppropriate"] = item["decisionAvailable"] as? Bool == true
    for key in ["legalObservedAction", "observedCallCorrect", "heroTurnConfirmed"] {
        checks[filename + "." + key] = item[key] as? Bool == true
    }
    let range = item["winRange"] as? [Double] ?? []
    checks[filename + ".winRangeValid"] = range.count == 2 && range.allSatisfy { $0.isFinite && (0...1).contains($0) } && range[0] <= range[1]
    if filename == "five-preflop.jpg" { checks[filename + ".emptyBoardConfirmed"] = item["emptyBoardConfirmed"] as? Bool == true }
}
var expected = ["obscured": ("第1张底牌未读清", "移开遮挡 · 自动重新识别"),
                "settlement": ("本手已结束", "等待下一手 · 已撤回概率和建议"),
                "dealing": ("等待发牌完成", "发牌动画结束后自动更新"),
                "preselection": ("", "操作待确认 · 暂无动作建议"),
                "stale": ("等待新画面", "确认牌面后更新")]
for item in screenshotCases {
    let name = item["file"] as? String == "five-preflop.jpg" ? "preflop-action" : "ten-flop-action"
    let title = item["expectedTitle"] as? String ?? "", subtitle = item["expectedSubtitle"] as? String ?? ""
    checks[name + ".hasActionAndWinText"] = title.hasPrefix("建议：") && subtitle.hasPrefix("独赢估计") && subtitle.contains("\n")
    checks[name + ".matchesHighSampleAction"] = matchesReference(name, title)
    expected[name] = (title, subtitle)
}
for item in cases {
    let name = item["case"] as! String
    let title = item["expectedTitle"] as? String ?? "", subtitle = item["expectedSubtitle"] as? String ?? ""
    checks[name + ".hasActionAndWinText"] = title.hasPrefix("建议：") && subtitle.hasPrefix("独赢估计") && subtitle.contains("\n")
    // The separate high-sample fixture uses independently supplied image amounts.
    checks[name + ".matchesHighSampleAction"] = matchesReference(name, title)
    checks[name + ".strategyCoexists"] = subtitle.split(separator: "\n").count == 2
    expected[name] = (title, subtitle)
}
for (name, text) in expected {
    let directory = root.appendingPathComponent(name)
    let report = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("render.json"))) as! [String: Any]
    let generated = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("generated.png")))!
    let displayed = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("displayed.png")))!
    let sameSize = generated.pixelsWide == displayed.pixelsWide && generated.pixelsHigh == displayed.pixelsHigh
    var difference = 0.0, visiblePixels = 0
    if sameSize {
        for y in 0..<displayed.pixelsHigh { for x in 0..<displayed.pixelsWide {
            let a = generated.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            let b = displayed.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            difference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            if b.greenComponent > 0.6 { visiblePixels += 1 }
        } }
    }
    checks[name + ".iosurface"] = report["inputHasIOSurface"] as? Bool == true
    checks[name + ".readyForDisplay"] = report["readyForDisplay"] as? Bool == true
    checks[name + ".displayedFrame"] = report["copiedDisplayedFrame"] as? Bool == true
    checks[name + ".textVisible"] = sameSize && visiblePixels > 600
    checks[name + ".compactLayout"] = generated.pixelsWide == 360 && generated.pixelsHigh == 104
    checks[name + ".matchesGenerated"] = sameSize && difference / Double(generated.pixelsWide * generated.pixelsHigh * 3) < 0.01
    checks[name + ".pipActive"] = report["pipActive"] as? Bool == true
    let title = report["renderedTitle"] as? String ?? ""
    checks[name + ".expectedReadout"] = (name == "preselection" ? title.hasPrefix("随机独赢估计") : title == text.0)
        && (name == "preselection" ? (report["renderedSubtitle"] as? String ?? "").hasSuffix(text.1) : report["renderedSubtitle"] as? String == text.1)
}
let passed = checks.values.allSatisfy { $0 }
print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": passed, "count": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(passed ? 0 : 1)
