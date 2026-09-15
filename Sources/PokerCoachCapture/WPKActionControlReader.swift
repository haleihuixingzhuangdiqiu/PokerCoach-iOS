#if canImport(Vision)
import CoreGraphics
import Foundation
import Vision

public struct WPKVisibleBetAmount: Codable, Sendable, Equatable {
    public let presetIndex: Int
    public let amountText: String
    public let confidence: Float
    public init(presetIndex: Int, amountText: String, confidence: Float) {
        self.presetIndex = presetIndex; self.amountText = amountText; self.confidence = confidence
    }
}

public struct WPKVisibleRaiseCandidate: Codable, Sendable, Equatable {
    public enum Meaning: String, Codable, Sendable { case bet, raiseTo }
    public let meaning: Meaning
    public let amountText: String
    public let confidence: Float
    public init(meaning: Meaning, amountText: String, confidence: Float) {
        self.meaning = meaning; self.amountText = amountText; self.confidence = confidence
    }
}

/// OCR of the number beside the hero's current-street green chip marker.
/// The separate timebank price beside the hole cards is outside this region.
public struct WPKHeroWagerEvidence: Codable, Sendable, Equatable {
    public let amountText: String
    public let confidence: Float
    public init(amountText: String, confidence: Float) { self.amountText = amountText; self.confidence = confidence }
}

/// Single-frame visual evidence. The caller must require fresh, repeated agreement before using it as an action set.
public struct WPKActionControlEvidence: Codable, Sendable, Equatable {
    public let heroTurnConfirmed: Bool
    public let canFold: Bool
    public let canCheck: Bool
    /// This exact theme shows the additional amount to call. A strict amount parser must still validate it.
    public let callAmountText: String?
    public let callConfidence: Float
    /// Enabled amounts printed by this calibrated theme: .bet when checking, .raiseTo when facing a call.
    /// No target is generated from pot fractions. The caller must still validate stack and side-pot eligibility.
    public let raiseCandidates: [WPKVisibleRaiseCandidate]
    /// Optional so older recorded evidence decodes as unknown, never as an invented zero.
    public let heroWager: WPKHeroWagerEvidence?
    /// Actual numbers printed below enabled blue presets, only exposed while the right action is confirmed check.
    /// The caller must additionally establish postflop, no outstanding wager and effective-stack bounds.
    public let visibleBetAmounts: [WPKVisibleBetAmount]
    /// The profile's real current-street chip-marker area has visible ocean background, not the separate timebank price.
    public let heroWagerAreaClear: Bool
    public let reason: String
    public let rightText: String
    public let rightConfidence: Float
    public var callControlVisible: Bool { heroTurnConfirmed && callAmountText != nil }
    public static let unconfirmed = Self()
    public init(heroTurnConfirmed: Bool = false, canFold: Bool = false, canCheck: Bool = false,
                callAmountText: String? = nil, callConfidence: Float = 0,
                raiseCandidates: [WPKVisibleRaiseCandidate] = [], reason: String = "本回合操作尚未确认",
                rightText: String = "", rightConfidence: Float = 0,
                visibleBetAmounts: [WPKVisibleBetAmount] = [], heroWagerAreaClear: Bool = false,
                heroWager: WPKHeroWagerEvidence? = nil) {
        self.heroTurnConfirmed = heroTurnConfirmed; self.canFold = canFold; self.canCheck = canCheck
        self.callAmountText = callAmountText; self.callConfidence = callConfidence
        self.raiseCandidates = raiseCandidates; self.reason = reason
        self.rightText = rightText; self.rightConfidence = rightConfidence
        self.visibleBetAmounts = visibleBetAmounts; self.heroWagerAreaClear = heroWagerAreaClear
        self.heroWager = heroWager
    }
}

/// Calibrated to the supplied eight-seat ocean layout. Preselection controls and historical action labels are excluded.
public final class WPKActionControlReader {
    public init() {}
    private let isolatedFieldCache = WPKExactFieldCache()
    private static func region(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ScreenRegion {
        ScreenRegion(id: id, x: x / 720, y: y / 1564, width: w / 720, height: h / 1564)
    }
    private static let strip = region("actions", 130, 1176, 458, 122)
    private static let presetStrip = region("presets", 88, 1064, 550, 102)
    private static let countdownRegions = [region("countdown.left", 145, 1170, 92, 62),
                                           region("countdown.right", 480, 1170, 104, 62)]
    private static let callRegion = region("call.amount", 496, 1242, 73, 44)
    public func read(_ image: CGImage) throws -> WPKActionControlEvidence {
        guard image.height >= 700, abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035 else {
            return WPKActionControlEvidence(reason: "操作布局未适配")
        }
        guard !WPKSceneGate.hasWhitePanelObstruction(image) else { return WPKActionControlEvidence(reason: "弹窗遮挡操作") }
        let features = visualFeatures(image)
        // Cheap shape/color rejection avoids OCR while another player is acting.
        guard features.foldRed, features.middleBlue, features.presetCount >= 3,
              features.rightBlue || features.rightGreen else { return WPKActionControlEvidence(reason: "未显示本回合完整操作组") }
        var (raw, confidence) = try readStrip(image, region: Self.strip, numeric: false)
        // The wide bilingual strip can lower the score of a perfectly legible short
        // "6s" or "4.6" after resizing. Keep the score threshold: retry only those
        // uncertain fields in their own small English-only ROI at two native scales.
        if raw["fold"] == "弃牌", raw["middle"] == "自由加注",
           (confidence["fold"] ?? 0) >= 0.90, (confidence["middle"] ?? 0) >= 0.90 {
            let oldTimer = (raw["countdown"] ?? "").filter { !$0.isWhitespace }.lowercased()
            if (confidence["countdown"] ?? 0) < 0.90 || oldTimer.range(of: "^[1-9][0-9]?s$", options: .regularExpression) == nil {
                let timers = try Self.countdownRegions.compactMap { try readIsolatedField(image, region: $0, pattern: "^[1-9][0-9]?s$") }
                if Set(timers.map(\.text)).count == 1, let timer = timers.first,
                   oldTimer.isEmpty || oldTimer == timer.text {
                    raw["countdown"] = timer.text; confidence["countdown"] = timers.map(\.confidence).min()
                }
            }
            if features.rightBlue, (confidence["right"] ?? 0) < 0.90,
               let call = try readIsolatedField(image, region: Self.callRegion, pattern: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$"),
               (raw["right"] ?? "").filter({ !$0.isWhitespace }).isEmpty || raw["right"] == call.text {
                raw["right"] = call.text; confidence["right"] = call.confidence
            }
        }
        let controls = WPKActionControlPolicy.evaluate(features: features, raw: raw, confidence: confidence)
        // Read printed targets only after the actual turn and this street's hero contribution are known.
        if controls.heroTurnConfirmed,
           (controls.canCheck && controls.heroWagerAreaClear) || (controls.callAmountText != nil && (controls.heroWager != nil || controls.heroWagerAreaClear)) {
            let (amounts, scores) = try readStrip(image, region: Self.presetStrip, numeric: true)
            raw.merge(amounts, uniquingKeysWith: { _, new in new })
            confidence.merge(scores, uniquingKeysWith: { _, new in new })
        }
        return WPKActionControlPolicy.evaluate(features: features, raw: raw, confidence: confidence)
    }

    private func readIsolatedField(_ image: CGImage, region: ScreenRegion, pattern: String) throws -> (text: String, confidence: Float)? {
        guard let crop = region.crop(image), let native = enlarge(crop, scale: 1),
              let pixels = native.dataProvider?.data else { return nil }
        var key = Data("\(native.width)x\(native.height):".utf8); key.append(pixels as Data)
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = isolatedFieldCache.lookup(region.id, pixels: key, now: now) {
            return cached.text.isEmpty ? nil : cached
        }
        var accepted: (text: String, confidence: Float)?
        for scale in [1, 2] {
            guard let input = scale == 1 ? native : enlarge(crop, scale: scale) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: input).perform([request])
            let observations = request.results ?? []
            guard observations.count == 1, let observation = observations.first,
                  let word = observation.topCandidates(1).first, word.confidence >= 0.90 else {
                isolatedFieldCache.store(region.id, pixels: key, text: "", confidence: 0, now: now); return nil
            }
            let text = word.string.filter { !$0.isWhitespace }.lowercased()
            guard text.range(of: pattern, options: .regularExpression) != nil,
                  !observation.topCandidates(3).contains(where: {
                      $0.confidence >= 0.90 && $0.string.filter { !$0.isWhitespace }.lowercased() != text
                  }), accepted == nil || accepted?.text == text else {
                isolatedFieldCache.store(region.id, pixels: key, text: "", confidence: 0, now: now); return nil
            }
            accepted = (text, min(accepted?.confidence ?? 1, word.confidence))
        }
        if let accepted { isolatedFieldCache.store(region.id, pixels: key, text: accepted.text, confidence: accepted.confidence, now: now) }
        return accepted
    }
    private func readStrip(_ image: CGImage, region: ScreenRegion, numeric: Bool) throws -> ([String: String], [String: Float]) {
        guard let crop = region.crop(image), let enlarged = enlarge(crop) else { return ([:], [:]) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = numeric ? ["en-US"] : ["zh-Hans", "en-US"]
        request.customWords = ["弃牌", "让牌", "自由加注"]
        try VNImageRequestHandler(cgImage: enlarged).perform([request])
        var fields: [String: [(String, Float, Double)]] = [:]
        for observation in request.results ?? [] {
            guard let word = observation.topCandidates(1).first else { continue }
            let x = (region.x + Double(observation.boundingBox.midX) * region.width) * 720
            let y = (region.y + (1 - Double(observation.boundingBox.midY)) * region.height) * 1564
            let key: String?
            if (140...238).contains(x), (1238...1292).contains(y) { key = "fold" }
            else if (482...580).contains(x), (1238...1292).contains(y) { key = "right" }
            else if (304...417).contains(x), (1188...1239).contains(y) { key = "middle" }
            else if (426...490).contains(x), (1195...1232).contains(y) { key = "hero.wager" }
            else if ((150...225).contains(x) || (492...571).contains(x)), (1180...1225).contains(y) { key = "countdown" }
            else if (98...164).contains(x), (1118...1155).contains(y) { key = "preset.0" }
            else if (205...274).contains(x), (1080...1114).contains(y) { key = "preset.1" }
            else if (326...399).contains(x), (1068...1104).contains(y) { key = "preset.2" }
            else if (446...519).contains(x), (1080...1116).contains(y) { key = "preset.3" }
            else if (553...636).contains(x), (1118...1156).contains(y) { key = "preset.4" }
            else if (553...636).contains(x), (1064...1117).contains(y) { key = "preset.4.label" }
            else { key = nil }
            if let key { fields[key, default: []].append((word.string, word.confidence, x)) }
        }
        var raw: [String: String] = [:], confidence: [String: Float] = [:]
        for (key, words) in fields {
            raw[key] = words.sorted { $0.2 < $1.2 }.map { $0.0 }.joined()
            confidence[key] = words.map { $0.1 }.min() ?? 0
        }
        return (raw, confidence)
    }

    private func visualFeatures(_ image: CGImage) -> WPKActionVisualFeatures {
        func color(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WPKButtonColor {
            guard let crop = Self.region(name, x, y, w, h).crop(image) else { return WPKButtonColor() }
            var rgba = [UInt8](repeating: 0, count: 20 * 20 * 4)
            let drawn = rgba.withUnsafeMutableBytes { data -> Bool in
                guard let context = CGContext(data: data.baseAddress, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 20, height: 20)); return true
            }
            guard drawn else { return WPKButtonColor() }
            var red = 0, blue = 0, green = 0, count = 0
            // Inner disk avoids the ocean background and colored outer border.
            for y in 3..<17 { for x in 3..<17 where (x - 10) * (x - 10) + (y - 10) * (y - 10) <= 49 {
                let p = (y * 20 + x) * 4
                let r = Double(rgba[p]), g = Double(rgba[p + 1]), b = Double(rgba[p + 2]); count += 1
                if r > 65, r > g * 1.55, r > b * 1.35 { red += 1 }
                if b > 125, b > g * 1.08, b > r * 1.35 { blue += 1 }
                if g > 55, g > r * 1.4, g > b * 1.08 { green += 1 }
            } }
            return WPKButtonColor(red: Double(red) / Double(max(1, count)) > 0.40,
                                  blue: Double(blue) / Double(max(1, count)) > 0.40,
                                  green: Double(green) / Double(max(1, count)) > 0.40)
        }
        let fold = color("fold", 137, 1217, 99, 98)
        let middle = color("middle", 305, 1153, 111, 111)
        let right = color("right", 483, 1217, 99, 98)
        let presets = [(94.0, 1048.0), (204.0, 1004.0), (326.0, 991.0), (447.0, 1005.0), (558.0, 1048.0)]
        let enabled = presets.map { color("preset", $0.0, $0.1, 70, 70).blue }
        return WPKActionVisualFeatures(foldRed: fold.red, middleBlue: middle.blue,
                                       rightBlue: right.blue, rightGreen: right.green, presetCount: enabled.filter { $0 }.count,
                                       presetEnabled: enabled, heroWagerAreaClear: hasClearWagerArea(image),
                                       heroWagerMarkerVisible: hasGreenWagerMarker(image))
    }
    private func hasGreenWagerMarker(_ image: CGImage) -> Bool {
        guard let crop = Self.region("hero.wager.marker", 448, 1160, 35, 36).crop(image) else { return false }
        var bytes = [UInt8](repeating: 0, count: 24 * 24 * 4)
        guard bytes.withUnsafeMutableBytes({ data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 96,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 24, height: 24)); return true
        }) else { return false }
        var green = 0, white = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            if g > 65, g * 100 > r * 130, g * 100 > b * 115 { green += 1 }
            if min(r, g, b) > 180, max(r, g, b) - min(r, g, b) < 55 { white += 1 }
        }
        return green >= 69 && white >= 28
    }
    private func hasClearWagerArea(_ image: CGImage) -> Bool {
        guard let crop = Self.region("hero.wager", 442, 1164, 43, 68).crop(image) else { return false }
        var rgba = [UInt8](repeating: 0, count: 12 * 20 * 4)
        let drawn = rgba.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: 12, height: 20, bitsPerComponent: 8, bytesPerRow: 48,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 12, height: 20)); return true
        }
        guard drawn else { return false }
        var ocean = 0, marker = 0
        for pixel in 0..<240 {
            let p = pixel * 4, r = Double(rgba[p]), g = Double(rgba[p + 1]), b = Double(rgba[p + 2])
            if r < 95, b > r * 1.20, b >= g * 0.95 { ocean += 1 }
            if (g > 100 && g > r * 1.25 && g > b * 1.12) || (min(r, min(g, b)) > 180) || (r > 150 && g > 140 && b < 130) { marker += 1 }
        }
        return ocean >= 192 && marker < 5
    }
    private func enlarge(_ image: CGImage, scale: Int = 2) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width * scale, height: image.height * scale, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
        return context.makeImage()
    }
}

private struct WPKButtonColor { var red = false; var blue = false; var green = false }
struct WPKActionVisualFeatures {
    let foldRed: Bool; let middleBlue: Bool; let rightBlue: Bool; let rightGreen: Bool; let presetCount: Int
    let presetEnabled: [Bool]
    let heroWagerAreaClear: Bool
    let heroWagerMarkerVisible: Bool
    init(foldRed: Bool, middleBlue: Bool, rightBlue: Bool, rightGreen: Bool, presetCount: Int,
         presetEnabled: [Bool] = [], heroWagerAreaClear: Bool = false, heroWagerMarkerVisible: Bool = false) {
        self.foldRed = foldRed; self.middleBlue = middleBlue; self.rightBlue = rightBlue; self.rightGreen = rightGreen
        self.presetCount = presetCount; self.presetEnabled = presetEnabled; self.heroWagerAreaClear = heroWagerAreaClear
        self.heroWagerMarkerVisible = heroWagerMarkerVisible
    }
}
enum WPKActionControlPolicy {
    static func evaluate(features: WPKActionVisualFeatures, raw: [String: String], confidence: [String: Float]) -> WPKActionControlEvidence {
        func text(_ key: String) -> String { (raw[key] ?? "").filter { !$0.isWhitespace } }
        let right = text("right"), rightScore = confidence["right"] ?? 0
        // The cheap empty-area sampler can miss a tiny printed "1". Any text in
        // the dedicated contribution region contradicts zero even if its chip marker
        // has become obscured; missing marker then means unknown, not zero.
        let wagerAreaClear = features.heroWagerAreaClear && text("hero.wager").isEmpty
        func rejected(_ reason: String) -> WPKActionControlEvidence {
            WPKActionControlEvidence(reason: reason, rightText: right, rightConfidence: rightScore)
        }
        guard features.foldRed, features.middleBlue, features.presetCount >= 3 else { return rejected("操作组颜色不完整") }
        guard text("fold") == "弃牌", text("middle") == "自由加注",
              (confidence["fold"] ?? 0) >= 0.90, (confidence["middle"] ?? 0) >= 0.90 else { return rejected("本回合操作标签未确认") }
        let countdown = text("countdown").lowercased()
        guard countdown.range(of: "^[1-9][0-9]?s$", options: .regularExpression) != nil,
              (confidence["countdown"] ?? 0) >= 0.90 else { return rejected("本人操作倒计时未确认") }
        guard rightScore >= 0.90 else { return rejected("右侧操作未读清") }
        let wager: WPKHeroWagerEvidence? = {
            let value = text("hero.wager"), score = confidence["hero.wager"] ?? 0
            guard features.heroWagerMarkerVisible, !wagerAreaClear, score >= 0.90,
                  value.range(of: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                  let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else { return nil }
            return WPKHeroWagerEvidence(amountText: value, confidence: score)
        }()
        if features.rightGreen, right == "让牌" {
            let amounts = (0..<5).compactMap { index -> WPKVisibleBetAmount? in
                let value = text("preset.\(index)"), score = confidence["preset.\(index)"] ?? 0
                guard features.presetEnabled.indices.contains(index), features.presetEnabled[index], score >= 0.90,
                      value.range(of: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                      let amount = Double(value), amount > 0 else { return nil }
                return WPKVisibleBetAmount(presetIndex: index, amountText: value, confidence: score)
            }
            return WPKActionControlEvidence(heroTurnConfirmed: true, canFold: true, canCheck: true,
                                            raiseCandidates: wagerAreaClear ? amounts.map { .init(meaning: .bet, amountText: $0.amountText, confidence: $0.confidence) } : [],
                                            reason: "本人本回合可弃牌或让牌", rightText: right, rightConfidence: rightScore,
                                            visibleBetAmounts: amounts, heroWagerAreaClear: wagerAreaClear)
        }
        if features.rightBlue, right.range(of: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
           let amount = Double(right), amount > 0 {
            // In this ocean profile the displayed raise presets are this-street totals,
            // not extra chips to pay. Read each enabled printed value; never reconstruct
            // one from the percentage label. Unknown hero contribution yields no raises.
            let contribution: Decimal?
            if let wager { contribution = Decimal(string: wager.amountText, locale: Locale(identifier: "en_US_POSIX")) }
            else { contribution = wagerAreaClear ? .zero : nil }
            let call = Decimal(string: right, locale: Locale(identifier: "en_US_POSIX"))
            let raises: [WPKVisibleRaiseCandidate] = (0..<5).compactMap { index in
                guard let contribution, let call, features.presetEnabled.indices.contains(index), features.presetEnabled[index] else { return nil }
                // The last button can change to "All-in". Its displayed-amount
                // convention with prior hero chips is not independently established;
                // expose it as a raise target only while the actual label is 1.2.
                if index == 4, text("preset.4.label") != "1.2" || (confidence["preset.4.label"] ?? 0) < 0.90 { return nil }
                let value = text("preset.\(index)"), score = confidence["preset.\(index)"] ?? 0
                guard score >= 0.90, value.range(of: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                      let target = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), target > contribution + call else { return nil }
                return WPKVisibleRaiseCandidate(meaning: .raiseTo, amountText: value, confidence: score)
            }
            return WPKActionControlEvidence(heroTurnConfirmed: true, canFold: true,
                                            callAmountText: right, callConfidence: rightScore,
                                            raiseCandidates: raises,
                                            reason: "本人本回合可弃牌或跟注", rightText: right, rightConfidence: rightScore,
                                            heroWagerAreaClear: wagerAreaClear, heroWager: wager)
        }
        return rejected("右侧操作语义不确定")
    }
}
#endif
