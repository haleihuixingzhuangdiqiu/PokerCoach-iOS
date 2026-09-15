#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

public struct RankTemplate: Codable {
    public let rank: String
    public let pixels: [UInt8]
    public let source: String
    public init(rank: String, pixels: [UInt8], source: String) { self.rank = rank; self.pixels = pixels; self.source = source }
}

public enum RankShape {
    public static func extract(_ card: CGImage) -> [UInt8]? {
        guard let glyph = segment(card) else { return nil }
        let minX = glyph.minX, maxX = glyph.maxX, minY = glyph.minY, maxY = glyph.maxY
        var normalized = [UInt8](repeating: 0, count: 24 * 32)
        for y in 0..<32 { for x in 0..<24 {
            let sx = minX + min(maxX - minX, Int((Double(x) + 0.5) * Double(maxX - minX + 1) / 24))
            let sy = minY + min(maxY - minY, Int((Double(y) + 0.5) * Double(maxY - minY + 1) / 32))
            normalized[y * 24 + x] = glyph.ink[sy * glyph.width + sx] ? 255 : 0
        } }
        return normalized
    }

    /// The same retained, non-boundary components used by template extraction, at their
    /// original aspect ratio. Remove table borders and partial suit fragments before OCR.
    /// This image is evidence for the caller's existing OCR policy, not an accepted rank.
    public static func isolatedGlyph(_ card: CGImage) -> CGImage? {
        guard let glyph = segment(card) else { return nil }
        let width = glyph.maxX - glyph.minX + 1, height = glyph.maxY - glyph.minY + 1
        var source = [UInt8](repeating: 255, count: glyph.width * glyph.height * 4)
        let drawn = source.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: glyph.width, height: glyph.height,
                                          bitsPerComponent: 8, bytesPerRow: glyph.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(glyph.image, in: CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height))
            return true
        }
        guard drawn else { return nil }
        var isolated = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let original = (y + glyph.minY) * glyph.width + x + glyph.minX
            if glyph.ink[original] {
                let destination = (y * width + x) * 4
                isolated[destination] = source[original * 4]
                isolated[destination + 1] = source[original * 4 + 1]
                isolated[destination + 2] = source[original * 4 + 2]
            }
        } }
        guard let provider = CGDataProvider(data: Data(isolated) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private struct SegmentedGlyph {
        let image: CGImage
        let width: Int, height: Int
        let ink: [Bool]
        let minX: Int, maxX: Int, minY: Int, maxY: Int
    }

    private static func segment(_ card: CGImage) -> SegmentedGlyph? {
        let rect = CGRect(x: Double(card.width) * 0.03, y: Double(card.height) * 0.02,
                          width: Double(card.width) * 0.78, height: Double(card.height) * 0.49).integral
        guard let rank = card.cropping(to: rect) else { return nil }
        let w = rank.width, h = rank.height
        var gray = [UInt8](repeating: 255, count: w * h)
        let ok = gray.withUnsafeMutableBytes { data -> Bool in
            guard let c = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.draw(rank, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return nil }
        var ink = gray.map { $0 < 170 }, visited = [Bool](repeating: false, count: w * h)
        var components: [[Int]] = []
        for start in ink.indices where ink[start] && !visited[start] {
            var queue = [start], cursor = 0, boundary = false
            visited[start] = true
            while cursor < queue.count {
                let p = queue[cursor]; cursor += 1
                let x = p % w, y = p / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { boundary = true }
                for (dx, dy) in [(-1,0), (1,0), (0,-1), (0,1)] {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0 && nx < w && ny >= 0 && ny < h {
                        let n = ny * w + nx
                        if ink[n] && !visited[n] { visited[n] = true; queue.append(n) }
                    }
                }
            }
            if !boundary && queue.count >= 6 { components.append(queue) }
        }
        guard let largest = components.map(\.count).max(), largest >= 12 else { return nil }
        let kept = components.filter { $0.count * 8 >= largest }.flatMap { $0 }
        guard let minX = kept.map({ $0 % w }).min(), let maxX = kept.map({ $0 % w }).max(),
              let minY = kept.map({ $0 / w }).min(), let maxY = kept.map({ $0 / w }).max(), maxY - minY >= 8 else { return nil }
        ink = [Bool](repeating: false, count: w * h)
        for p in kept { ink[p] = true }
        return SegmentedGlyph(image: rank, width: w, height: h, ink: ink,
                              minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }
    public static func match(_ pixels: [UInt8], templates: [RankTemplate]) -> (rank: String, distance: Double, margin: Double)? {
        guard let best = nearest(pixels, templates: templates), best.distance <= 0.16, best.margin >= 0.04 else { return nil }
        return best
    }
    /// Keep rejection evidence available without relaxing the acceptance thresholds.
    public static func nearest(_ pixels: [UInt8], templates: [RankTemplate]) -> (rank: String, distance: Double, margin: Double)? {
        guard pixels.count == 768 else { return nil }
        var bestByRank: [String: Double] = [:]
        for template in templates where template.pixels.count == pixels.count {
            let mismatch = zip(pixels, template.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            let distance = Double(mismatch) / (255 * Double(pixels.count))
            bestByRank[template.rank] = min(bestByRank[template.rank] ?? 1, distance)
        }
        let scores = bestByRank.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        guard scores.count >= 2 else { return nil }
        return (scores[0].key, scores[0].value, scores[1].value - scores[0].value)
    }
}
#endif
