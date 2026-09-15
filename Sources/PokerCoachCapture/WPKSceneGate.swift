#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#if canImport(Vision)
import Vision
#endif

/// A narrow obstruction check for the supplied ocean-table layout, not a general scene classifier.
/// All four areas sit outside the five public-card rectangles. A bright card or one bright control
/// cannot reject a table by itself; the caller must still validate card and layout evidence.
public enum WPKSceneGate {
    /// Positive evidence for this theme's *hero* settlement banner. This deliberately
    /// does not infer a finished hand from missing buttons, folded seats or a chip gain.
    /// A false result can also mean the win animation currently obscures its text.
    public static func hasHeroWinSettlement(_ image: CGImage) -> Bool {
        #if canImport(Vision)
        guard image.height >= 700,
              abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035 else { return false }
        let region = CGRect(x: 0.25, y: 0.535, width: 0.50, height: 0.065)
        guard let preview = scenePixels(image, region: region, width: 160, height: 48),
              hasGoldWordGeometry(preview, width: 160, height: 48) else { return false }
        // Require all three control colors: a blue avatar behind the absent middle
        // button must not hide a genuine win banner. These tiny samples need no OCR.
        guard !hasLiveActionColors(image) else { return false }
        let rect = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                          width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: rect), let key = exactSettlementPixels(crop) else { return false }
        return settlementCache.result(for: key) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            do { try VNImageRequestHandler(cgImage: crop).perform([request]) }
            catch { return nil } // A transient Vision error must be retried on the next frame.
            // Accept only the complete literal banner. Gold alone and partial letters
            // (e.g. the bright flash at the start of the animation) are insufficient.
            return (request.results ?? []).contains { observation in
                guard let word = observation.topCandidates(1).first, word.confidence >= 0.90 else { return false }
                return word.string.filter { !$0.isWhitespace } == "YOUWIN"
            }
        }
        #else
        return false
        #endif
    }

    private static let settlementCache = WPKSettlementOCRCache()

    private static func hasLiveActionColors(_ image: CGImage) -> Bool {
        func fractions(_ rect: CGRect) -> (red: Int, blue: Int, green: Int) {
            guard let pixels = scenePixels(image, region: rect, width: 10, height: 10) else { return (0, 0, 0) }
            var red = 0, blue = 0, green = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                if r > 65, r * 100 > g * 155, r * 100 > b * 135 { red += 1 }
                if b > 125, b * 100 > g * 108, b * 100 > r * 135 { blue += 1 }
                if g > 55, g * 100 > r * 140, g * 100 > b * 108 { green += 1 }
            }
            return (red, blue, green)
        }
        let middle = fractions(CGRect(x: 0.45, y: 0.755, width: 0.10, height: 0.032))
        guard middle.blue >= 40 else { return false }
        let fold = fractions(CGRect(x: 0.23, y: 0.805, width: 0.04, height: 0.02))
        guard fold.red >= 40 else { return false }
        let right = fractions(CGRect(x: 0.715, y: 0.805, width: 0.04, height: 0.02))
        return right.blue >= 40 || right.green >= 40
    }

    private static func exactSettlementPixels(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard bytes.withUnsafeMutableBytes({ memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }) else { return nil }
        // Include dimensions: the same byte sequence laid out differently is a different ROI.
        var key = Data("\(width)x\(height):".utf8)
        key.append(contentsOf: bytes)
        return key
    }

    private static func hasGoldWordGeometry(_ bytes: [UInt8], width: Int, height: Int) -> Bool {
        var count = 0, minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            if r >= 170, g >= 125, b <= 155, r * 100 >= g * 95, g * 100 >= b * 130 {
                count += 1; minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        // The centered banner is a wide, short line below the board. Isolated yellow
        // chip numbers, names and a broad decorative glow cannot establish settlement.
        guard count >= width * height / 40, count <= width * height / 3,
              maxX - minX >= width / 2, maxY - minY >= height / 6,
              maxY - minY <= height * 2 / 3 else { return false }
        return minX < width / 3 && maxX > width * 2 / 3
    }

    /// This theme can expose the next action menu before a new public card has landed.
    /// Detect its red back in the central flight corridor or a still face-down board slot.
    /// A false result is not proof of stability: callers must retain complete-card and
    /// cross-frame confirmation, including the nearly edge-on part of a card flip.
    public static func hasBoardDealingAnimation(_ image: CGImage) -> Bool {
        guard image.height >= 700,
              abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035 else { return false }

        // Stop above the white public-card faces (their top edge is about y=0.461).
        // The central corridor excludes both players' card backs and side action badges.
        if let pixels = scenePixels(image, region: CGRect(x: 0.31, y: 0.315, width: 0.38, height: 0.138),
                                    width: 92, height: 82),
           redBackFraction(pixels) >= 0.025, whiteFraction(pixels) < 0.10,
           hasDenseRedPatch(pixels, width: 92, height: 82) { return true }

        // A back fills most of a board slot with red. A normal heart/diamond occupies
        // much less area and its surrounding white face prevents this branch matching.
        for index in 0..<5 {
            let region = CGRect(x: 0.224 + Double(index) * 0.1135, y: 0.464, width: 0.096, height: 0.066)
            if let pixels = scenePixels(image, region: region, width: 18, height: 30),
               redBackFraction(pixels) >= 0.55, whiteFraction(pixels) < 0.25 { return true }
        }
        return false
    }

    public static func hasWhitePanelObstruction(_ image: CGImage) -> Bool {
        guard image.height >= 700,
              abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035 else { return false }
        let regions = [
            CGRect(x: 0.19, y: 0.416, width: 0.10, height: 0.018),
            CGRect(x: 0.71, y: 0.416, width: 0.10, height: 0.018),
            CGRect(x: 0.125, y: 0.45, width: 0.055, height: 0.055),
            CGRect(x: 0.825, y: 0.45, width: 0.055, height: 0.055)
        ]
        for region in regions {
            let rect = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                              width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
            guard let crop = image.cropping(to: rect), hasMostlyWhiteSurface(crop) else { return false }
        }
        return true
    }

    private static func hasMostlyWhiteSurface(_ image: CGImage) -> Bool {
        let width = 12, height = 8
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return false }
        var white = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let lowest = min(bytes[offset], min(bytes[offset + 1], bytes[offset + 2]))
            let highest = max(bytes[offset], max(bytes[offset + 1], bytes[offset + 2]))
            if lowest >= 215, highest - lowest <= 30 { white += 1 }
        }
        return Double(white) / Double(width * height) >= 0.90
    }

    private static func scenePixels(_ image: CGImage, region: CGRect, width: Int, height: Int) -> [UInt8]? {
        let rect = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                          width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? bytes : nil
    }

    private static func isRedBack(_ bytes: [UInt8], _ offset: Int) -> Bool {
        let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
        // Crimson/magenta card backs; exclude orange action labels and green chips.
        return r >= 105 && g <= 145 && b >= 35 && b <= 175 && r * 100 >= g * 145
            && r * 100 >= b * 122 && b * 100 >= g * 90
    }

    private static func redBackFraction(_ bytes: [UInt8]) -> Double {
        var count = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) { if isRedBack(bytes, offset) { count += 1 } }
        return Double(count) / Double(bytes.count / 4)
    }

    private static func whiteFraction(_ bytes: [UInt8]) -> Double {
        var count = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            if min(r, g, b) >= 190 && max(r, g, b) - min(r, g, b) <= 45 { count += 1 }
        }
        return Double(count) / Double(bytes.count / 4)
    }

    private static func hasDenseRedPatch(_ bytes: [UInt8], width: Int, height: Int) -> Bool {
        // Scattered red pixels or a thin moving chip trail cannot impersonate a card.
        for y in stride(from: 0, through: height - 8, by: 4) {
            for x in stride(from: 0, through: width - 8, by: 4) {
                var count = 0
                for row in y..<(y + 8) {
                    for column in x..<(x + 8) {
                        if isRedBack(bytes, (row * width + column) * 4) { count += 1 }
                    }
                }
                if count >= 36 { return true }
            }
        }
        return false
    }
}

/// The card and public workers can inspect the same frame concurrently. Serialize
/// only the already-filtered tiny-ROI recognition so an identical in-flight request
/// is performed once. Full byte equality avoids reusing an answer on changed text.
final class WPKSettlementOCRCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Data: Bool] = [:]
    private var order: [Data] = []
    func result(for key: Data, recognize: () -> Bool?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let result = entries[key] { return result }
        guard let result = recognize() else { return false }
        entries[key] = result; order.append(key)
        if order.count > 8 { entries.removeValue(forKey: order.removeFirst()) }
        return result
    }
}
#endif
