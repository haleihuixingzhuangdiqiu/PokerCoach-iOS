#if canImport(Vision)
import CoreGraphics
import Foundation
import Vision

public struct WPKSnapshotTextEvidence: Codable, Sendable, Equatable {
    public let rawText: String
    /// Recognizer score, not a calibrated probability. See recognitionMethod.
    public let confidence: Float
    public let regionID: String
    public let recognitionMethod: String
    public init(rawText: String, confidence: Float, regionID: String, recognitionMethod: String = "vision") {
        self.rawText = rawText; self.confidence = confidence; self.regionID = regionID; self.recognitionMethod = recognitionMethod
    }
}

public struct WPKSnapshotVisualEvidence: Codable, Sendable, Equatable {
    public let source: String
    /// Geometric/template similarity, not a probability of correctness.
    public let matchScore: Float
}

public struct WPKTableSeatEvidence: Codable, Sendable {
    /// 0 top, 1 right upper, 2 right middle, 3 right lower,
    /// 4 left lower, 5 left middle, 6 left upper, 7 hero.
    public let index: Int
    public let stack: WPKSnapshotTextEvidence?
    /// Only populated when a real green chip marker AND a numeric reading agree.
    public let currentStreetWager: WPKSnapshotTextEvidence?
    /// Positive match to an observed empty theme region. Missing is UNKNOWN, never zero.
    public let streetWagerAreaClear: WPKSnapshotVisualEvidence?
    public let folded: WPKSnapshotTextEvidence?
    public let allIn: WPKSnapshotTextEvidence?
    public let positiveCards: WPKSnapshotVisualEvidence?
    /// Display text only; truncated/changed names do not establish persistent identity.
    public let playerName: WPKSnapshotTextEvidence?
    public let actionLabel: WPKSnapshotTextEvidence?
    public let straddle: WPKSnapshotTextEvidence?
}

public struct WPKTableSnapshotEvidence: Codable, Sendable {
    public let seats: [WPKTableSeatEvidence]
    public let dealerSeat: Int?
    public let dealer: WPKSnapshotTextEvidence?
    /// Literal display only; its three numbers do not assign positions or imply an ante.
    public let blindText: WPKSnapshotTextEvidence?
    public let straddleSeat: Int?
    /// Includes uncertain reads for diagnosis. These are not confirmed state facts.
    public let raw: [String: WPKSnapshotTextEvidence]
}

/// Optional full-table snapshot for the calibrated eight-seat ocean layout.
/// Kept separate from the low-latency action reader. It neither reconstructs history
/// nor assumes that absence of cards, text, or a chip means a player folded/paid zero.
public final class WPKTableSnapshotReader {
    public init() {}
    private let lock = NSLock()
    private var cache: [String: CachedText] = [:]
    private(set) var recognitionRequestCount = 0
    private struct CachedText { let pixels: Data; let value: WPKSnapshotTextEvidence; let at: TimeInterval }
    private struct EmptyTemplate: Decodable { let seat: Int; let rgba: [UInt8]; let kind: String? }
    private lazy var templates: [EmptyTemplate] = {
        guard let url = Bundle.module.url(forResource: "wpk-clear-wager-templates", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([EmptyTemplate].self, from: data) else { return [] }
        return values
    }()
    private lazy var emptyTemplates: [Int: [[UInt8]]] = {
        Dictionary(grouping: templates.filter { $0.kind == nil || $0.kind == "empty" }, by: \.seat).mapValues { $0.map(\.rgba) }
    }()

    private static let stacks: [CGRect] = [
        CGRect(x: 302, y: 290, width: 118, height: 35), CGRect(x: 590, y: 435, width: 122, height: 36),
        CGRect(x: 590, y: 697, width: 122, height: 35), CGRect(x: 590, y: 982, width: 122, height: 35),
        CGRect(x: 6, y: 982, width: 120, height: 35), CGRect(x: 5, y: 697, width: 120, height: 35),
        CGRect(x: 6, y: 435, width: 120, height: 36), CGRect(x: 302, y: 1454, width: 122, height: 38)
    ]
    private static let badges: [CGRect] = [
        CGRect(x: 310, y: 202, width: 90, height: 53), CGRect(x: 604, y: 349, width: 89, height: 53),
        CGRect(x: 605, y: 609, width: 89, height: 56), CGRect(x: 605, y: 898, width: 89, height: 53),
        CGRect(x: 29, y: 898, width: 91, height: 53), CGRect(x: 30, y: 609, width: 91, height: 56),
        CGRect(x: 29, y: 349, width: 91, height: 53), CGRect(x: 316, y: 1175, width: 88, height: 63)
    ]
    private static let names: [CGRect] = [
        CGRect(x: 275, y: 144, width: 180, height: 29), CGRect(x: 572, y: 290, width: 145, height: 32),
        CGRect(x: 566, y: 552, width: 151, height: 33), CGRect(x: 566, y: 836, width: 151, height: 33),
        CGRect(x: 3, y: 836, width: 153, height: 33), CGRect(x: 3, y: 552, width: 153, height: 33),
        CGRect(x: 3, y: 290, width: 153, height: 32), CGRect.zero
    ]
    private static let labels: [CGRect] = [
        CGRect(x: 409, y: 178, width: 105, height: 42), CGRect(x: 508, y: 318, width: 104, height: 43),
        CGRect(x: 508, y: 580, width: 104, height: 43), CGRect(x: 508, y: 865, width: 104, height: 43),
        CGRect(x: 117, y: 865, width: 104, height: 43), CGRect(x: 117, y: 580, width: 104, height: 43),
        CGRect(x: 117, y: 318, width: 104, height: 43), CGRect.zero
    ]
    private static let markers: [CGRect] = [
        CGRect(x: 345, y: 328, width: 37, height: 36), CGRect(x: 535, y: 358, width: 36, height: 36),
        CGRect(x: 535, y: 620, width: 36, height: 36), CGRect(x: 535, y: 906, width: 36, height: 36),
        CGRect(x: 152, y: 906, width: 36, height: 36), CGRect(x: 152, y: 620, width: 36, height: 36),
        CGRect(x: 152, y: 358, width: 36, height: 36), CGRect(x: 448, y: 1160, width: 35, height: 36)
    ]
    private static let wagers: [CGRect] = [
        CGRect(x: 314, y: 362, width: 100, height: 30), CGRect(x: 502, y: 394, width: 100, height: 33),
        CGRect(x: 502, y: 656, width: 100, height: 33), CGRect(x: 502, y: 942, width: 100, height: 33),
        CGRect(x: 120, y: 942, width: 100, height: 33), CGRect(x: 120, y: 656, width: 100, height: 33),
        CGRect(x: 120, y: 394, width: 100, height: 33), CGRect(x: 421, y: 1197, width: 90, height: 35)
    ]
    private static let backs: [CGRect] = [
        CGRect(x: 297, y: 239, width: 48, height: 46), CGRect(x: 668, y: 385, width: 48, height: 49),
        CGRect(x: 668, y: 647, width: 48, height: 49), CGRect(x: 668, y: 932, width: 48, height: 49),
        CGRect(x: 12, y: 932, width: 48, height: 49), CGRect(x: 12, y: 647, width: 48, height: 49),
        CGRect(x: 12, y: 385, width: 48, height: 49), CGRect.zero
    ]
    private static let dealerRects: [[CGRect]] = [
        [CGRect(x: 271, y: 286, width: 32, height: 39), CGRect(x: 421, y: 286, width: 32, height: 39)],
        [CGRect(x: 557, y: 430, width: 33, height: 41)], [CGRect(x: 557, y: 692, width: 33, height: 41)],
        [CGRect(x: 557, y: 977, width: 33, height: 41)], [CGRect(x: 133, y: 977, width: 33, height: 41)],
        [CGRect(x: 133, y: 692, width: 33, height: 41)], [CGRect(x: 133, y: 430, width: 33, height: 41)],
        [CGRect(x: 271, y: 1448, width: 32, height: 41), CGRect(x: 425, y: 1448, width: 32, height: 41)]
    ]

    public func read(_ image: CGImage, includePlayerNames: Bool = false) throws -> WPKTableSnapshotEvidence {
        lock.lock(); defer { lock.unlock() }
        var raw: [String: WPKSnapshotTextEvidence] = [:]
        guard image.height >= 700, abs(Double(image.width) / Double(image.height) - 720.0 / 1564) < 0.02 else {
            return WPKTableSnapshotEvidence(seats: [], dealerSeat: nil, dealer: nil, blindText: nil, straddleSeat: nil, raw: [:])
        }
        func readField(_ id: String, _ rect: CGRect, chinese: Bool = false, scale: Int = 3, invert: Bool = false, threshold: Int? = nil) throws -> WPKSnapshotTextEvidence? {
            guard !rect.isEmpty, let crop = Self.crop(image, rect) else { return nil }
            let value = try recognize(crop, id: id, chinese: chinese, scale: scale, invert: invert, threshold: threshold)
            if !value.rawText.isEmpty { raw[id] = value; return value }
            return nil
        }
        func readNumber(_ id: String, _ rect: CGRect) throws -> WPKSnapshotTextEvidence? {
            let value = try readField(id, rect)
            if Self.numeric(value) { return value }
            // The actual decimal dot is retained by this crop preprocessing. Never
            // rewrite commas, concatenate disconnected digits, or infer from a pot.
            if let value, value.rawText.range(of: "^[0-9]{1,6},[0-9]{1,2}$", options: .regularExpression) != nil {
                for scale in [3, 4] {
                    if let retry = try readField(id + ".inverted\(scale)", rect, scale: scale, invert: true), Self.numeric(retry),
                       retry.rawText.filter({ $0 != "." }) == value.rawText.filter({ $0 != "," }) { return retry }
                }
                // Ocean lines under a bright decimal dot can look like a comma.
                // Keep only the actual bright strokes at two thresholds. Both
                // independently recognized decimals must agree; never rewrite text.
                if let first = try readField(id + ".binary140", rect, scale: 2, threshold: 140), Self.numeric(first),
                   first.rawText.contains("."), first.rawText.filter({ $0 != "." }) == value.rawText.filter({ $0 != "," }),
                   let second = try readField(id + ".binary160", rect, scale: 2, threshold: 160), Self.numeric(second),
                   second.rawText == first.rawText { return first }
            }
            return value
        }
        var seats: [WPKTableSeatEvidence] = [], dealers: [(Int, WPKSnapshotTextEvidence)] = []
        for index in 0..<8 {
            let prefix = "table.seat.\(index)."
            var stack = try readNumber(prefix + "stack", Self.stacks[index])
            if stack == nil, let reference = templates.first(where: { $0.kind == "stackZero" && $0.seat == index }),
               let pixels = Self.pixels(image, rect: Self.stacks[index], width: 24, height: 24) {
                let match = Self.backgroundMatch(pixels, reference.rgba)
                if match >= 0.995 {
                    stack = WPKSnapshotTextEvidence(rawText: "0", confidence: match, regionID: prefix + "stack.zeroGlyph",
                        recognitionMethod: "visible-stack-zero-template-v1")
                    raw[prefix + "stack.zeroGlyph"] = stack
                }
            }
            var wager = try readNumber(prefix + "wager", Self.wagers[index])
            let marker = Self.markerVisible(image, rect: Self.markers[index])
            if marker, wager == nil, let reference = templates.first(where: { $0.kind == "wagerOne" && $0.seat == index }),
               let pixels = Self.pixels(image, rect: Self.wagers[index], width: 24, height: 24) {
                let match = Self.backgroundMatch(pixels, reference.rgba)
                if match >= 0.995 {
                    wager = WPKSnapshotTextEvidence(rawText: "1", confidence: match, regionID: prefix + "wager.oneGlyph",
                        recognitionMethod: "visible-wager-one-template-v1")
                    raw[prefix + "wager.oneGlyph"] = wager
                }
            }
            let verifiedWager = marker && Self.numeric(wager) ? wager : nil
            let clear: WPKSnapshotVisualEvidence?
            if !marker, wager == nil, let reference = emptyTemplates[index],
               let pixels = Self.pixels(image, rect: Self.markers[index].union(Self.wagers[index]), width: 24, height: 24) {
                let score = reference.map { Self.backgroundMatch(pixels, $0) }.max() ?? 0
                clear = score >= 0.97 ? WPKSnapshotVisualEvidence(source: "wpk-ocean-empty-street-wager-v1/seat\(index)", matchScore: score) : nil
            } else { clear = nil }
            let topCovered = index == 0 && Self.topOverlayVisible(image)
            let name = !includePlayerNames || topCovered || Self.darkOverlay(image, rect: Self.names[index]) ? nil : try readField(prefix + "name", Self.names[index], chinese: true)
            var badge = index == 7 || topCovered ? nil : try readField(prefix + "badge", Self.badges[index], chinese: true)
            if let broad = badge, broad.confidence < 0.9, broad.rawText.contains("弃牌") {
                let rect = Self.badges[index]
                let narrow = CGRect(x: rect.minX + 20, y: rect.minY + 11, width: 55, height: 30)
                if let reread = try readField(prefix + "badge.fold", narrow, chinese: true), reread.rawText == "弃牌", reread.confidence >= 0.9 { badge = reread }
            }
            if Self.normalized(badge?.rawText ?? "") == "allin", (badge?.confidence ?? 0) < 0.9,
               let english = try readField(prefix + "badge.en", Self.badges[index]), Self.normalized(english.rawText) == "allin" {
                badge = english
            }
            let label = Self.coloredLabelVisible(image, rect: Self.labels[index]) ? try readField(prefix + "label", Self.labels[index], chinese: true) : nil
            var straddle: WPKSnapshotTextEvidence?
            if Self.purpleVisible(image, rect: Self.labels[index]),
               let english = try readField(prefix + "straddle", Self.labels[index]), english.confidence >= 0.9,
               Self.normalized(english.rawText) == "straddle" { straddle = english }
            let strongBadge = (badge?.confidence ?? 0) >= 0.9
            let folded = strongBadge && badge?.rawText == "弃牌" ? badge : nil
            let allIn = strongBadge && ["allin", "全下", "全押"].contains(Self.normalized(badge?.rawText ?? "")) ? badge : nil
            let cards = Self.positiveCards(image, index: index)
            seats.append(WPKTableSeatEvidence(index: index, stack: Self.numeric(stack) ? stack : nil,
                currentStreetWager: verifiedWager, streetWagerAreaClear: clear, folded: folded, allIn: allIn,
                positiveCards: cards, playerName: name, actionLabel: label, straddle: straddle))
            for (candidate, rect) in Self.dealerCandidates(image, seat: index).enumerated() {
                let id = prefix + "dealer.\(candidate)"
                var text = try readField(id, rect, scale: 1)
                if text?.rawText != "D" || (text?.confidence ?? 0) < 0.9 {
                    text = try readField(id + ".inner", rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.11), scale: 1)
                }
                if text?.rawText != "D" || (text?.confidence ?? 0) < 0.9 {
                    text = try readField(id + ".inverted1", rect, scale: 1, invert: true)
                }
                if text?.rawText != "D" || (text?.confidence ?? 0) < 0.9 {
                    text = try readField(id + ".inverted2", rect, scale: 2, invert: true)
                }
                if let text, text.confidence >= 0.9, text.rawText == "D" { dealers.append((index, text)) }
            }
        }
        if includePlayerNames { _ = try readField("table.blinds.label", CGRect(x: 292, y: 869, width: 159, height: 35), chinese: true) }
        let blind = try readField("table.blinds", CGRect(x: 348, y: 874, width: 96, height: 26), scale: 2)
        _ = try readField("table.pot", CGRect(x: 301, y: 394, width: 116, height: 42))
        _ = try readField("table.settledPot", CGRect(x: 329, y: 440, width: 88, height: 38))
        let straddles = seats.filter { $0.straddle != nil }
        return WPKTableSnapshotEvidence(seats: seats, dealerSeat: dealers.count == 1 ? dealers[0].0 : nil,
            dealer: dealers.count == 1 ? dealers[0].1 : nil, blindText: blind,
            straddleSeat: straddles.count == 1 ? straddles[0].index : nil, raw: raw)
    }

    private func recognize(_ crop: CGImage, id: String, chinese: Bool, scale: Int, invert: Bool, threshold: Int?) throws -> WPKSnapshotTextEvidence {
        // A cropped CGImage can still expose its full parent's data provider.
        // Canonicalize ONLY this ROI so unrelated table/timer changes do not miss.
        var pixels = Data("\(crop.width)x\(crop.height):".utf8)
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let hasPixels = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)); return true
        }
        pixels.append(contentsOf: bytes)
        let now = ProcessInfo.processInfo.systemUptime
        // This caches character recognition, not table state. Each current image
        // must match every byte again; changed/occluded fields never inherit text.
        if hasPixels, let entry = cache[id], now >= entry.at, now - entry.at < 10, entry.pixels == pixels {
            cache[id] = CachedText(pixels: pixels, value: entry.value, at: now)
            return entry.value
        }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = chinese ? ["zh-Hans", "en-US"] : ["en-US"]
        request.customWords = ["Straddle", "All in", "弃牌", "盲注"]
        var input = crop
        let padding = threshold == nil ? 0 : 20
        if let threshold, hasPixels {
            for p in stride(from: 0, to: bytes.count, by: 4) {
                let ink = Int(bytes[p]) > threshold && Int(bytes[p + 1]) > threshold
                bytes[p] = ink ? 0 : 255; bytes[p + 1] = bytes[p]; bytes[p + 2] = bytes[p]
            }
            if let provider = CGDataProvider(data: Data(bytes) as CFData),
               let binary = CGImage(width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) { input = binary }
        }
        guard let context = CGContext(data: nil, width: crop.width * scale + padding * 2, height: crop.height * scale + padding * 2, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return WPKSnapshotTextEvidence(rawText: "", confidence: 0, regionID: id)
        }
        context.interpolationQuality = threshold == nil ? .high : .none
        if padding > 0 { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height)) }
        context.draw(input, in: CGRect(x: padding, y: padding, width: crop.width * scale, height: crop.height * scale))
        if invert {
            context.setBlendMode(.difference); context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        guard let enlarged = context.makeImage() else { return WPKSnapshotTextEvidence(rawText: "", confidence: 0, regionID: id) }
        recognitionRequestCount += 1
        try VNImageRequestHandler(cgImage: enlarged).perform([request])
        let words = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first }
        let value = WPKSnapshotTextEvidence(rawText: words.map(\.string).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: words.map(\.confidence).min() ?? 0, regionID: id)
        if hasPixels { cache[id] = CachedText(pixels: pixels, value: value, at: now) }
        return value
    }

    private static func numeric(_ value: WPKSnapshotTextEvidence?) -> Bool {
        guard let value, value.confidence >= 0.9 else { return false }
        return value.rawText.range(of: "^[0-9]{1,6}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil
    }
    private static func normalized(_ value: String) -> String { value.filter { !$0.isWhitespace && $0 != "-" }.lowercased() }
    private static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        ScreenRegion(id: "snapshot", x: rect.minX / 720, y: rect.minY / 1564, width: rect.width / 720, height: rect.height / 1564).crop(image)
    }
    static func pixels(_ image: CGImage, rect: CGRect, width: Int, height: Int) -> [UInt8]? {
        guard !rect.isEmpty, let crop = crop(image, rect) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard bytes.withUnsafeMutableBytes({ data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }) else { return nil }
        return bytes
    }
    private static func markerVisible(_ image: CGImage, rect: CGRect) -> Bool {
        guard let bytes = pixels(image, rect: rect, width: 24, height: 24) else { return false }
        var green = 0, white = 0
        for p in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
            if g > 65, g * 100 > r * 130, g * 100 > b * 115 { green += 1 }
            if min(r, g, b) > 180, max(r, g, b) - min(r, g, b) < 55 { white += 1 }
        }
        return green >= 69 && white >= 28
    }
    private static func purpleVisible(_ image: CGImage, rect: CGRect) -> Bool {
        guard let bytes = pixels(image, rect: rect, width: 24, height: 12) else { return false }
        return stride(from: 0, to: bytes.count, by: 4).filter { p in
            let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
            return b > 100 && r > g * 2 && b > g * 2
        }.count >= 35
    }
    private static func darkOverlay(_ image: CGImage, rect: CGRect) -> Bool {
        guard let b = pixels(image, rect: rect, width: 24, height: 12) else { return true }
        return stride(from: 0, to: b.count, by: 4).filter { max(b[$0], b[$0 + 1], b[$0 + 2]) < 65 }.count > 190
    }
    private static func topOverlayVisible(_ image: CGImage) -> Bool {
        // The app's large dark PiP panel extends far beyond the top avatar. Never
        // let its previous advice become that player's name, fold or all-in badge.
        darkOverlay(image, rect: CGRect(x: 455, y: 115, width: 220, height: 120))
            && darkOverlay(image, rect: CGRect(x: 318, y: 112, width: 70, height: 48))
    }
    private static func coloredLabelVisible(_ image: CGImage, rect: CGRect) -> Bool {
        guard let b = pixels(image, rect: rect, width: 24, height: 12) else { return false }
        return stride(from: 0, to: b.count, by: 4).filter { p in
            let r = Int(b[p]), g = Int(b[p + 1]), blue = Int(b[p + 2])
            return (blue > 130 && blue > g * 13 / 10 && blue > r * 15 / 10)
                || (g > 90 && g > r * 14 / 10 && g > blue * 11 / 10)
                || (r > 170 && r > g * 13 / 10 && g > blue * 13 / 10)
        }.count >= 75
    }
    private static func whiteDiskVisible(_ image: CGImage, rect: CGRect) -> Bool {
        guard let bytes = pixels(image, rect: rect, width: 20, height: 20) else { return false }
        let white = stride(from: 0, to: bytes.count, by: 4).filter { min(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) > 190 }.count
        return white >= 80 && white <= 310
    }
    /// The D disk can be next to or below a stack. Find a white round connected
    /// component in that seat's bounded stack neighborhood, then OCR its real D.
    /// A stack digit or card corner cannot become a dealer merely by being white.
    private static func dealerCandidates(_ image: CGImage, seat: Int) -> [CGRect] {
        let stack = stacks[seat]
        let region = stack.insetBy(dx: -37, dy: -40).intersection(CGRect(x: 0, y: 0, width: 720, height: 1564))
        let width = Int(region.width), height = Int(region.height)
        guard let b = pixels(image, rect: region, width: width, height: height) else { return [] }
        // Component coordinates use the same rendered crop row order.
        var seen = [Bool](repeating: false, count: width * height), result: [CGRect] = []
        func white(_ n: Int) -> Bool { min(b[n * 4], b[n * 4 + 1], b[n * 4 + 2]) >= 195 }
        for start in 0..<(width * height) where !seen[start] && white(start) {
            var queue = [start], at = 0, minX = width, minY = height, maxX = 0, maxY = 0
            seen[start] = true
            while at < queue.count {
                let n = queue[at]; at += 1; let x = n % width, y = n / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for neighbor in [x > 0 ? n - 1 : -1, x + 1 < width ? n + 1 : -1, y > 0 ? n - width : -1, y + 1 < height ? n + width : -1]
                where neighbor >= 0 && !seen[neighbor] && white(neighbor) { seen[neighbor] = true; queue.append(neighbor) }
            }
            let w = maxX - minX + 1, h = maxY - minY + 1
            guard (21...35).contains(w), (21...35).contains(h), abs(w - h) <= 5,
                  queue.count >= 180, Double(queue.count) / Double(w * h) > 0.35 else { continue }
            let rect = CGRect(x: region.minX + CGFloat(minX) - 3, y: region.minY + CGFloat(minY) - 3,
                              width: CGFloat(w) + 6, height: CGFloat(h) + 6)
            if whiteDiskVisible(image, rect: rect) { result.append(rect) }
        }
        return result
    }
    private static func positiveCards(_ image: CGImage, index: Int) -> WPKSnapshotVisualEvidence? {
        if index == 7 {
            let cards = [CGRect(x: 286, y: 1300, width: 70, height: 105), CGRect(x: 362, y: 1300, width: 70, height: 105)]
            let white = cards.map { rect -> Float in
                guard let b = pixels(image, rect: rect, width: 20, height: 28) else { return 0 }
                return Float(stride(from: 0, to: b.count, by: 4).filter { min(b[$0], b[$0 + 1], b[$0 + 2]) > 185 }.count) / 560
            }
            guard white.allSatisfy({ $0 > 0.42 }) else { return nil }
            return WPKSnapshotVisualEvidence(source: "two-visible-hero-card-faces", matchScore: white.min()!)
        }
        guard let b = pixels(image, rect: backs[index], width: 24, height: 24) else { return nil }
        var red = 0, white = 0
        for p in stride(from: 0, to: b.count, by: 4) {
            let r = Int(b[p]), g = Int(b[p + 1]), blue = Int(b[p + 2])
            if r >= 105, g <= 145, blue >= 35, blue <= 175, r * 100 >= g * 145, r * 100 >= blue * 122, blue * 100 >= g * 90 { red += 1 }
            if min(r, g, blue) > 170, max(r, g, blue) - min(r, g, blue) < 60 { white += 1 }
        }
        guard red >= 105, white >= 6 else { return nil }
        return WPKSnapshotVisualEvidence(source: "red-white-card-back-in-seat-slot", matchScore: Float(red) / 576)
    }
    static func backgroundMatch(_ pixels: [UInt8], _ reference: [UInt8]) -> Float {
        guard pixels.count == reference.count, !pixels.isEmpty else { return 0 }
        var matching = 0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let difference = (0..<3).map { abs(Int(pixels[p + $0]) - Int(reference[p + $0])) }.max()!
            if difference <= 16 { matching += 1 }
        }
        return Float(matching) / Float(pixels.count / 4)
    }
}
#endif
