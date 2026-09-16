import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let rendererOnly = CommandLine.arguments.contains("--renderer-only")
var reports: [[String: Any]] = []
var failed = false
let required = ["inline", "floating", "returned"]
let additional = ["call", "fold", "check", "large-amount", "reading", "disconnected", "estimate", "expired"]
for name in required + additional.filter({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) {
    let directory = root.appendingPathComponent(name)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("render.json"))) as! [String: Any]
    let generated = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("generated.png")))!
    let displayed = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("displayed.png")))!
    let sameSize = generated.pixelsWide == displayed.pixelsWide && generated.pixelsHigh == displayed.pixelsHigh
    var totalDifference = 0.0, brightPixels = 0
    if sameSize {
        for y in 0..<displayed.pixelsHigh { for x in 0..<displayed.pixelsWide {
            let a = generated.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            let b = displayed.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            totalDifference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            if 0.2126 * b.redComponent + 0.7152 * b.greenComponent + 0.0722 * b.blueComponent > 0.6 { brightPixels += 1 }
        } }
    }
    let difference = totalDifference / Double(generated.pixelsWide * generated.pixelsHigh * 3)
    var checks: [String: Bool] = [
        "iosurface": json["inputHasIOSurface"] as? Bool == true,
        "readyForDisplay": json["readyForDisplay"] as? Bool == true,
        "displayedFrame": json["copiedDisplayedFrame"] as? Bool == true,
        "textIsVisible": sameSize && brightPixels > 200,
        "matchesGeneratedFrame": sameSize && difference < 0.01
    ]
    if !rendererOnly { checks["pipLifecycle"] = json["pipActive"] as? Bool == (name != "inline" && name != "returned") }
    if name == "expired" || name == "disconnected" {
        checks["oldAdviceWithdrawn"] = json["renderedSubtitle"] as? String == "" &&
            json["renderedTitle"] as? String == (name == "expired" ? "等画面" : "重连录屏")
    }
    if checks.values.contains(false) { failed = true }
    reports.append(["checkpoint":name,"checks":checks,"brightPixels":brightPixels,"meanChannelDifference":difference])
}
let output: [String: Any] = ["passed":!failed,"checkpoints":reports,
                           "scope":rendererOnly ? "renderer-only; system PiP lifecycle NOT verified" : "renderer-and-system-pip"]
print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
exit(failed ? 1 : 0)
