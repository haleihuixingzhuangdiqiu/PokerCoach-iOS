#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// Positive empty-board evidence for the calibrated ocean four-color layout.
/// This does not infer preflop from unreadable card slots. The caller must also
/// confirm the hero cards, the same-frame result and two fresh observations.
public enum WPKBoardPresence {
    public static func hasEmptyBoardArea(_ image: CGImage) -> Bool {
        guard image.height >= 700,
              abs(Double(image.width) / Double(image.height) - 720.0 / 1564.0) < 0.035,
              !WPKSceneGate.hasWhitePanelObstruction(image),
              !WPKSceneGate.hasBoardDealingAnimation(image) else { return false }

        // Inspect every pixel across all five public-card slots AND their gaps.
        // A single white-face probe can miss a wide rank, an edge-on flip or a mask.
        let board = ScreenRegion(id: "board.presence", x: 48.0 / 220, y: 219.0 / 480,
                                 width: 126.0 / 220, height: 40.0 / 480)
        guard visibleOceanSurface(image, region: board, requireTexture: true) else { return false }

        // Public cards fly through this corridor before landing. Require positive
        // visible table here too, including thin backs below the red-scene threshold.
        let flight = ScreenRegion(id: "board.flight", x: 0.31, y: 0.315, width: 0.38, height: 0.138)
        return visibleOceanSurface(image, region: flight, requireTexture: false)
    }

    private static func visibleOceanSurface(_ image: CGImage, region: ScreenRegion,
                                           requireTexture: Bool) -> Bool {
        guard let crop = region.crop(image) else { return false }
        let width = crop.width, height = crop.height
        guard width >= 150, height >= 50 else { return false }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        let columns = 15, rows = 5
        var blueCounts = [Int](repeating: 0, count: columns * rows)
        var tileCounts = blueCounts, blueSums = blueCounts
        var whiteColumns = [Int](repeating: 0, count: width)
        var ocean = 0, white = 0, red = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                let tile = min(rows - 1, y * rows / height) * columns + min(columns - 1, x * columns / width)
                tileCounts[tile] += 1; blueSums[tile] += b
                // The known table is blue even where the dark central logo crosses
                // the board. Black/gray occlusions and another table theme fail closed.
                // Native DeviceRGB conversion of the earlier PNG frames renders
                // the lower-right ocean shadow near (2, 15, 36). Keep that blue
                // shadow without accepting a black/neutral mask or lowering the
                // per-tile visible-table requirement.
                if r < 110, g >= 12, g < 170, b >= 30, b <= 230,
                   b * 100 > g * 108, b * 100 > r * 140 {
                    ocean += 1; blueCounts[tile] += 1
                }
                if min(r, g, b) >= 150, max(r, g, b) - min(r, g, b) <= 60 {
                    white += 1; whiteColumns[x] += 1
                }
                if r >= 100, r * 100 > g * 140, r * 100 > b * 120 { red += 1 }
            }
        }
        let total = width * height
        guard ocean * 100 >= total * 97,
              white * 1_000 <= total, red * 1_000 <= total else { return false }
        // A nearly edge-on card can occupy much less than 0.1% of the rectangle.
        // Its continuous bright column still cannot establish an empty board.
        guard !whiteColumns.contains(where: { $0 >= max(3, height * 8 / 100) }) else { return false }
        for index in blueCounts.indices {
            guard tileCounts[index] > 0, blueCounts[index] * 100 >= tileCounts[index] * 80 else { return false }
        }
        if requireTexture {
            let tileMeans = blueSums.indices.map { Double(blueSums[$0]) / Double(tileCounts[$0]) }
            guard let lowest = tileMeans.min(), let highest = tileMeans.max(), highest - lowest >= 20 else { return false }
        }
        return true
    }
}
#endif
