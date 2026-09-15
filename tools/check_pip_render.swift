import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var reports: [[String: Any]] = []
var failed = false
for name in ["inline", "floating", "returned"] {
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
            if b.redComponent > 0.6 && b.greenComponent > 0.6 && b.blueComponent > 0.6 { brightPixels += 1 }
        } }
    }
    let difference = totalDifference / Double(generated.pixelsWide * generated.pixelsHigh * 3)
    let checks: [String: Bool] = [
        "iosurface": json["inputHasIOSurface"] as? Bool == true,
        "readyForDisplay": json["readyForDisplay"] as? Bool == true,
        "displayedFrame": json["copiedDisplayedFrame"] as? Bool == true,
        "textIsVisible": sameSize && brightPixels > 600,
        "matchesGeneratedFrame": sameSize && difference < 0.01,
        "pipLifecycle": json["pipActive"] as? Bool == (name == "floating")
    ]
    if checks.values.contains(false) { failed = true }
    reports.append(["checkpoint":name,"checks":checks,"brightPixels":brightPixels,"meanChannelDifference":difference])
}
let output: [String: Any] = ["passed":!failed,"checkpoints":reports]
print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
exit(failed ? 1 : 0)
