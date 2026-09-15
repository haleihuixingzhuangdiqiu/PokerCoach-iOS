import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let analysis = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("analysis.json"))) as! [String: Any]
var checks: [String: Bool] = [:]
for item in analysis["cases"] as! [[String: Any]] {
    let name = item["case"] as! String
    for (key, value) in item["checks"] as! [String: Bool] { checks[name + "." + key] = value }
}
checks["staleEstimateWithdrawn"] = analysis["staleEstimateWithdrawn"] as? Bool == true
let expected = ["two-pair": ("两对 · 约94%", "随机单挑 · 仅牌面估算"),
                "call-amount": ("高牌 · 约41%", "随机单挑 · 底池比25%"), "stale": ("等待新画面", "确认牌面后更新")]
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
    checks[name + ".matchesGenerated"] = sameSize && difference / Double(generated.pixelsWide * generated.pixelsHigh * 3) < 0.01
    checks[name + ".pipActive"] = report["pipActive"] as? Bool == true
    checks[name + ".expectedReadout"] = report["renderedTitle"] as? String == text.0 && report["renderedSubtitle"] as? String == text.1
}
let passed = checks.values.allSatisfy { $0 }
print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": passed, "count": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(passed ? 0 : 1)
