#if canImport(Vision)
import Foundation
import CoreGraphics
import Vision

public struct CardReadEvidence: Codable {
    public let region: String
    public let card: String?
    public let rawRank: String
    public let rankConfidence: Float
    public let reason: String
    /// A visible white card failed rank/suit reading; it must not become an empty board slot.
    public let hasUnresolvedCard: Bool
}

/// Four-color WPK deck: red hearts, green clubs, blue diamonds, black spades.
/// Other themes must use another calibrated reader. Color is only read within a verified white card.
public final class FourColorCardReader {
    private let templates: [RankTemplate]
    private let additionalTemplates: @Sendable () -> [RankTemplate]
    private static let fallbackCache = RankOCRCache()
    public init(templates: [RankTemplate] = [], additionalTemplates: @escaping @Sendable () -> [RankTemplate] = { [] }) {
        self.templates = templates; self.additionalTemplates = additionalTemplates
    }
    #if SWIFT_PACKAGE
    public static func wpkVideoProfile() throws -> FourColorCardReader {
        FourColorCardReader(templates: try bundledTemplates(), additionalTemplates: { RankLearningLibrary.shared.templates })
    }
    public static func bundledTemplates() throws -> [RankTemplate] {
        guard let url = Bundle.module.url(forResource: "wpk-rank-templates", withExtension: "json") else {
            throw NSError(domain: "PokerCoachCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "牌面模板未打包"])
        }
        return try JSONDecoder().decode([RankTemplate].self, from: Data(contentsOf: url))
    }
    #endif
    public func read(_ image: CGImage, regions: [ScreenRegion]) throws -> [CardReadEvidence] {
        let templates = self.templates + additionalTemplates()
        return regions.map { region in
            var cardSurfaceDetected = false
            func rejected(_ why: String, raw: String = "", confidence: Float = 0) -> CardReadEvidence {
                CardReadEvidence(region: region.id, card: nil, rawRank: raw, rankConfidence: confidence, reason: why, hasUnresolvedCard: cardSurfaceDetected)
            }
            guard let crop = region.crop(image), crop.height >= 70 else { return rejected("原始牌张像素不足") }
            let width = crop.width, height = crop.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let c = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                c.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard drawn else { return rejected("图像解码失败") }
            var white = 0, background = 0
            // Keep the surface probe to the right of both digits of "10". The former
            // 60–80% strip crossed the black zero and silently classified a visible Ts as empty.
            // Leave the outer 10% unused so a rounded edge or the next slot cannot qualify.
            for y in (height / 10)..<(height * 4 / 10) { for x in (width * 8 / 10)..<(width * 9 / 10) {
                let p = (y * width + x) * 4
                if rgba[p] > 185 && rgba[p + 1] > 185 && rgba[p + 2] > 185 { white += 1 }
                background += 1
            } }
            guard background > 0, Double(white) / Double(background) > 0.75 else { return rejected("未确认完整白色牌面") }
            cardSurfaceDetected = true
            var counts = [Int](repeating: 0, count: 4)
            for y in (height / 2)..<(height * 9 / 10) { for x in (width / 6)..<(width * 9 / 10) {
                let p = (y * width + x) * 4
                let r = Double(rgba[p]), g = Double(rgba[p + 1]), b = Double(rgba[p + 2])
                if r > 70 && r > g * 1.35 && r > b * 1.3 { counts[2] += 1 }
                else if g > 70 && g > r * 1.25 && g > b * 1.15 { counts[0] += 1 }
                else if b > 70 && b > r * 1.25 && b > g * 1.05 { counts[1] += 1 }
                else if max(r, max(g, b)) < 100 { counts[3] += 1 }
            } }
            let sorted = counts.indices.sorted { counts[$0] > counts[$1] }
            guard counts[sorted[0]] > width * height / 40, counts[sorted[0]] > counts[sorted[1]] * 2 else { return rejected("花色不确定") }
            let rankRect = CGRect(x: Double(width) * 0.04, y: Double(height) * 0.04, width: Double(width) * 0.72, height: Double(height) * 0.44).integral
            guard let rankImage = crop.cropping(to: rankRect) else { return rejected("点数区域无效") }
            var templateReason = "未提供字形模板"
            if !templates.isEmpty {
                if let shape = RankShape.extract(crop) {
                    if let match = RankShape.match(shape, templates: templates) {
                        let code = match.rank + String(Array("cdhs")[sorted[0]])
                        return CardReadEvidence(region: region.id, card: code, rawRank: match.rank, rankConfidence: Float(1 - match.distance), reason: "字形候选，仍需跨帧确认", hasUnresolvedCard: false)
                    }
                    if let nearest = RankShape.nearest(shape, templates: templates) {
                        templateReason = String(format: "字形距离%.3f/间隔%.3f未过门限", nearest.distance, nearest.margin)
                    } else { templateReason = "字形模板候选不足" }
                } else {
                    templateReason = "字形提取不完整"
                }
            }
            // Exact source ROI bytes, not perceptual similarity: a changed glyph must never reuse another rank.
            var key = Data("\(Int(rankRect.width))x\(Int(rankRect.height)):".utf8)
            for y in Int(rankRect.minY)..<Int(rankRect.maxY) {
                let start = (y * width + Int(rankRect.minX)) * 4
                key.append(contentsOf: rgba[start..<(start + Int(rankRect.width) * 4)])
            }
            let result: RankOCRResult
            switch Self.fallbackCache.begin(key, now: ProcessInfo.processInfo.systemUptime) {
            case let .cached(cached): result = cached
            case .pending: return rejected("点数复核进行中：" + templateReason)
            case .start:
                result = Self.verifyRank(RankShape.isolatedGlyph(crop) ?? rankImage)
                Self.fallbackCache.finish(key, result: result, now: ProcessInfo.processInfo.systemUptime)
            }
            guard let rank = result.rank else {
                return rejected("点数复核未通过：\(result.reason)；\(templateReason)", raw: result.raw, confidence: result.confidence)
            }
            let code = rank + String(Array("cdhs")[sorted[0]])
            return CardReadEvidence(region: region.id, card: code, rawRank: result.raw, rankConfidence: result.confidence,
                                    reason: "OCR双图一致，仍需跨帧确认", hasUnresolvedCard: false)
        }
    }

    private static func verifyRank(_ rank: CGImage) -> RankOCRResult {
        do {
            guard let color = padded(rank, grayscale: false), let gray = padded(rank, grayscale: true) else {
                return .rejected("预处理失败")
            }
            let original = try recognize(color)
            // The two views share a source image and are not independent probability estimates.
            guard original.acceptedRank != nil else { return .rejected(original.reason, raw: original.raw, confidence: original.confidence) }
            let processed = try recognize(gray)
            return RankOCRPolicy.agree(original, processed)
        } catch {
            // OCR engine errors must leave this card unresolved, rather than aborting every slot in the frame.
            return .rejected("Vision引擎失败")
        }
    }
    private static func recognize(_ image: CGImage) throws -> RankOCRReading {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
        request.customWords = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        guard observations.count == 1, let observation = observations.first else {
            return RankOCRReading(raw: "", confidence: 0, alternate: nil, alternateConfidence: 0, observationCount: observations.count)
        }
        let candidates = observation.topCandidates(2)
        return RankOCRReading(raw: candidates.first?.string ?? "", confidence: candidates.first?.confidence ?? 0,
                              alternate: candidates.count > 1 ? candidates[1].string : nil,
                              alternateConfidence: candidates.count > 1 ? candidates[1].confidence : 0, observationCount: 1)
    }
    private static func padded(_ rank: CGImage, grayscale: Bool) -> CGImage? {
        let scale = grayscale ? 4 : 3, border = 20
        let width = rank.width * scale + border * 2, height = rank.height * scale + border * 2
        let space = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(rank, in: CGRect(x: border, y: border, width: rank.width * scale, height: rank.height * scale))
        return context.makeImage()
    }
}

struct RankOCRReading {
    let raw: String
    let confidence: Float
    let alternate: String?
    let alternateConfidence: Float
    let observationCount: Int
    var acceptedRank: String? {
        guard observationCount == 1, confidence >= 0.90, let rank = RankOCRPolicy.normalize(raw) else { return nil }
        if let alternate, RankOCRPolicy.normalize(alternate) != rank, alternateConfidence >= 0.80 { return nil }
        return rank
    }
    var reason: String {
        if observationCount != 1 { return "非单一点数字符" }
        if confidence < 0.90 { return "OCR置信不足" }
        if RankOCRPolicy.normalize(raw) == nil { return "非合法点数" }
        return "OCR候选冲突"
    }
}
struct RankOCRResult {
    let rank: String?
    let raw: String
    let confidence: Float
    let reason: String
    static func rejected(_ reason: String, raw: String = "", confidence: Float = 0) -> Self {
        Self(rank: nil, raw: raw, confidence: confidence, reason: reason)
    }
}
enum RankOCRPolicy {
    static func normalize(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["A", "K", "Q", "J", "10", "T", "9", "8", "7", "6", "5", "4", "3", "2"].contains(raw) else { return nil }
        return raw == "10" ? "T" : raw
    }
    static func agree(_ first: RankOCRReading, _ second: RankOCRReading) -> RankOCRResult {
        guard let rank = first.acceptedRank, let other = second.acceptedRank else {
            let rejected = first.acceptedRank == nil ? first : second
            return .rejected(rejected.reason, raw: rejected.raw, confidence: rejected.confidence)
        }
        guard rank == other else { return .rejected("双图点数不一致", raw: first.raw + "/" + second.raw, confidence: min(first.confidence, second.confidence)) }
        // Local counterexample: Vision read an upright synthetic 6 as 9 at score 1 in both processed views.
        // The calibrated template path may still accept a 9; OCR alone cannot resolve this orientation ambiguity.
        guard rank != "6", rank != "9" else { return .rejected("6/9需字形模板确认", raw: first.raw, confidence: min(first.confidence, second.confidence)) }
        return RankOCRResult(rank: rank, raw: first.raw, confidence: min(first.confidence, second.confidence), reason: "双图一致")
    }
}
/// Exact-pixel cache shared by the fast reader and the public-amount reader. It never learns new templates.
final class RankOCRCache {
    enum Admission { case start, pending, cached(RankOCRResult) }
    private let lock = NSLock()
    private var inFlight = Set<Data>()
    private var entries: [Data: (result: RankOCRResult, at: TimeInterval)] = [:]
    func begin(_ key: Data, now: TimeInterval) -> Admission {
        lock.lock(); defer { lock.unlock() }
        if let item = entries[key], now - item.at < (item.result.rank == nil ? 0.35 : 3) { return .cached(item.result) }
        if inFlight.contains(key) { return .pending }
        inFlight.insert(key)
        return .start
    }
    func finish(_ key: Data, result: RankOCRResult, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(key)
        if entries.count >= 64, entries[key] == nil, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries.removeValue(forKey: oldest) }
        entries[key] = (result, now)
    }
}

public extension WPKVideoLayout {
    static let cardRegions: [ScreenRegion] = makeCardRegions()
    private static func makeCardRegions() -> [ScreenRegion] {
        var regions: [ScreenRegion] = [
        .init(id: "hero.0", x: 86.0/220, y: 397.0/480, width: 24.0/220, height: 36.0/480),
        .init(id: "hero.1", x: 110.0/220, y: 397.0/480, width: 24.0/220, height: 36.0/480)
        ]
        for i in 0..<5 {
            let x: Double = Double(48 + i * 24) / 220.0
            regions.append(ScreenRegion(id: "board.\(i)", x: x, y: 219.0 / 480.0, width: 24.0 / 220.0, height: 40.0 / 480.0))
        }
        return regions
    }
}
#endif
