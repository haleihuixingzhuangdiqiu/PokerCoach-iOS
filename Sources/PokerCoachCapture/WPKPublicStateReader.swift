#if canImport(Vision)
import Foundation
import CoreGraphics
import Vision

public struct PublicStateEvidence: Codable, Sendable {
    public let raw: [String: String]
    public let scores: [String: Float]
    public let callControlVisible: Bool
    public let actionControls: WPKActionControlEvidence
    public let activeOpponentSeat: Int?
    public let activeOpponentStackText: String?
    public let activeOpponentStackConfidence: Float
    public init(raw: [String: String], scores: [String: Float], callControlVisible: Bool,
                actionControls: WPKActionControlEvidence = .unconfirmed,
                activeOpponentSeat: Int? = nil, activeOpponentStackText: String? = nil, activeOpponentStackConfidence: Float = 0) {
        self.raw = raw; self.scores = scores; self.callControlVisible = callControlVisible; self.actionControls = actionControls
        self.activeOpponentSeat = activeOpponentSeat; self.activeOpponentStackText = activeOpponentStackText
        self.activeOpponentStackConfidence = activeOpponentStackConfidence
    }
    private enum CodingKeys: String, CodingKey { case raw, scores, callControlVisible, actionControls, activeOpponentSeat, activeOpponentStackText, activeOpponentStackConfidence }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        raw = try values.decode([String: String].self, forKey: .raw)
        scores = try values.decode([String: Float].self, forKey: .scores)
        callControlVisible = try values.decode(Bool.self, forKey: .callControlVisible)
        actionControls = try values.decodeIfPresent(WPKActionControlEvidence.self, forKey: .actionControls) ?? .unconfirmed
        activeOpponentSeat = try values.decodeIfPresent(Int.self, forKey: .activeOpponentSeat)
        activeOpponentStackText = try values.decodeIfPresent(String.self, forKey: .activeOpponentStackText)
        activeOpponentStackConfidence = try values.decodeIfPresent(Float.self, forKey: .activeOpponentStackConfidence) ?? 0
    }
}

/// Reads only visible public fields from the eight-seat ocean theme. No inferred action history.
public final class WPKPublicStateReader {
    public init() {}
    private let actionReader = WPKActionControlReader()
    private let fieldCache = WPKExactFieldCache()
    private static func region(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ScreenRegion {
        ScreenRegion(id: id, x: x / 720, y: y / 1564, width: w / 720, height: h / 1564)
    }
    private static let regions: [ScreenRegion] = [
        region("pot", 301, 394, 116, 42), region("settled", 329, 440, 88, 38),
        region("stack", 302, 1454, 122, 38),
        region("seat.0", 310, 202, 90, 53), region("seat.1", 604, 349, 89, 53),
        region("seat.2", 605, 609, 89, 56), region("seat.3", 605, 898, 89, 53),
        region("seat.4", 29, 898, 91, 53), region("seat.5", 30, 609, 91, 56),
        region("seat.6", 29, 349, 91, 53)
    ]
    private static let opponentStacks: [ScreenRegion] = [
        region("opponent.stack", 302, 290, 118, 35), region("opponent.stack", 590, 435, 122, 36),
        region("opponent.stack", 590, 697, 122, 35), region("opponent.stack", 590, 982, 122, 35),
        region("opponent.stack", 6, 982, 120, 35), region("opponent.stack", 5, 697, 120, 35),
        region("opponent.stack", 6, 435, 120, 36)
    ]
    public func read(_ image: CGImage) throws -> PublicStateEvidence {
        var raw: [String: String] = [:], scores: [String: Float] = [:]
        for region in Self.regions {
            guard let crop = region.crop(image), let enlarged = enlarge(crop) else { continue }
            let result = try recognize(enlarged, id: region.id, languages: region.id.hasPrefix("seat.") ? ["zh-Hans", "en-US"] : ["en-US"])
            raw[region.id] = result.text; scores[region.id] = result.confidence
            // This English avatar badge loses confidence in the bilingual recognizer.
            // Require the same actual word at >=0.90 in an English-only reread; keep
            // its cache identity separate from the bilingual seat/fold recognition.
            let normalized = result.text.filter { !$0.isWhitespace && $0 != "-" }.lowercased()
            if region.id.hasPrefix("seat."), normalized == "allin", result.confidence < 0.90 {
                let english = try recognize(enlarged, id: region.id + ".allin.en", languages: ["en-US"])
                if english.confidence >= 0.90,
                   english.text.filter({ !$0.isWhitespace && $0 != "-" }).lowercased() == "allin" {
                    raw[region.id] = english.text; scores[region.id] = english.confidence
                }
            }
        }
        // One action strip replaces the old call OCR; confirmed actions may add the printed preset strip.
        let controls = try actionReader.read(image)
        raw["call"] = controls.rightText; scores["call"] = controls.rightConfidence
        if let wager = controls.heroWager {
            raw["hero.wager"] = wager.amountText; scores["hero.wager"] = wager.confidence
        }
        // A label on a player's avatar means chips already committed all-in. The
        // available "All-in" preset at the bottom is deliberately outside these ROIs.
        let allInSeats = (0..<7).filter { seat in
            let value = (raw["seat.\(seat)"] ?? "").filter { !$0.isWhitespace && $0 != "-" }.lowercased()
            return (scores["seat.\(seat)"] ?? 0) >= 0.90 && ["allin", "全下", "全押"].contains(value)
        }
        if !allInSeats.isEmpty {
            raw["allin.visible"] = "true"; raw["allin.seats"] = allInSeats.map(String.init).joined(separator: ",")
            scores["allin.visible"] = allInSeats.compactMap { scores["seat.\($0)"] }.min()
        }
        let folded = (0..<7).filter { raw["seat.\($0)"] == "弃牌" && (scores["seat.\($0)"] ?? 0) >= 0.90 }
        var opponentSeat: Int?, opponentStack: String?, opponentScore: Float = 0
        if folded.count == 6, !WPKSceneGate.hasWhitePanelObstruction(image),
           let seat = (0..<7).first(where: { !folded.contains($0) }),
           let crop = Self.opponentStacks[seat].crop(image), let enlarged = enlarge(crop) {
            let result = try recognize(enlarged, id: "opponent.stack.\(seat)", languages: ["en-US"])
            let value = result.text, score = result.confidence
            if score >= 0.90, value.range(of: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil {
                opponentSeat = seat; opponentStack = value; opponentScore = score
                raw["opponent.stack"] = value; scores["opponent.stack"] = score
                raw["opponent.seat"] = String(seat)
            }
        }
        return PublicStateEvidence(raw: raw, scores: scores, callControlVisible: controls.callControlVisible, actionControls: controls,
                                    activeOpponentSeat: opponentSeat, activeOpponentStackText: opponentStack, activeOpponentStackConfidence: opponentScore)
    }
    private func recognize(_ image: CGImage, id: String, languages: [String]) throws -> (text: String, confidence: Float) {
        var pixels = Data("\(image.width)x\(image.height):\(image.bytesPerRow):".utf8)
        let hasPixels: Bool
        if let data = image.dataProvider?.data { pixels.append(data as Data); hasPixels = true } else { hasPixels = false }
        let now = ProcessInfo.processInfo.systemUptime
        if hasPixels, let cached = fieldCache.lookup(id, pixels: pixels, now: now) { return cached }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false; request.recognitionLanguages = languages
        request.customWords = ["弃牌", "让牌"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let words = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first }
        let text = words.map(\.string).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = words.map(\.confidence).min() ?? 0
        if hasPixels { fieldCache.store(id, pixels: pixels, text: text, confidence: confidence, now: now) }
        return (text, confidence)
    }
    private func enlarge(_ image: CGImage) -> CGImage? {
        guard let c = CGContext(data: nil, width: image.width * 2, height: image.height * 2, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        return c.makeImage()
    }
}

/// One current entry per fixed field, exact rendered pixels and dimensions, and a short hard TTL.
/// A cache hit does not extend the TTL, and OCR never borrows a different field or changed amount.
final class WPKExactFieldCache {
    private struct Entry { let pixels: Data; let text: String; let confidence: Float; let at: TimeInterval }
    private var entries: [String: Entry] = [:]
    func lookup(_ id: String, pixels: Data, now: TimeInterval) -> (text: String, confidence: Float)? {
        guard let entry = entries[id], now >= entry.at, now - entry.at < 0.75, entry.pixels == pixels else { return nil }
        return (entry.text, entry.confidence)
    }
    func store(_ id: String, pixels: Data, text: String, confidence: Float, now: TimeInterval) {
        if entries.count >= 24, entries[id] == nil, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries.removeValue(forKey: oldest) }
        entries[id] = Entry(pixels: pixels, text: text, confidence: confidence, at: now)
    }
}
#endif
