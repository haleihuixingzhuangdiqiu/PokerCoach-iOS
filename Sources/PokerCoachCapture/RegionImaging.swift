#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

public struct ScreenRegion: Codable, Sendable {
    public let id: String
    /// Normalized top-left coordinates in the orientation-corrected frame.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(id: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func crop(_ image: CGImage) -> CGImage? {
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1.000001, y + height <= 1.000001 else { return nil }
        let rect = CGRect(x: x * Double(image.width), y: y * Double(image.height), width: width * Double(image.width), height: height * Double(image.height)).integral
        return image.cropping(to: rect)
    }
    public func digest(_ image: CGImage, columns: Int = 24, rows: Int = 12) -> [UInt8]? {
        guard columns > 0, rows > 0, columns <= 128, rows <= 128, let crop = crop(image) else { return nil }
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        let drawn = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows)); return true
        }
        return drawn ? pixels : nil
    }
}

/// Calibrated geometrically against the supplied 220×480 clip, not an all-device WPK profile.
public enum WPKVideoLayout {
    public static let identifier = "wpk-ocean-220x480-v1"
    public static let regions: [ScreenRegion] = [
        .init(id: "hero.cards", x: 86.0/220, y: 397.0/480, width: 48.0/220, height: 36.0/480),
        .init(id: "board", x: 48.0/220, y: 219.0/480, width: 126.0/220, height: 40.0/480),
        .init(id: "pot", x: 76.0/220, y: 117.0/480, width: 68.0/220, height: 18.0/480),
        .init(id: "hero.stack", x: 84.0/220, y: 443.0/480, width: 54.0/220, height: 20.0/480),
        .init(id: "top.stack", x: 88.0/220, y: 84.0/480, width: 47.0/220, height: 20.0/480),
        .init(id: "actions", x: 15.0/220, y: 307.0/480, width: 192.0/220, height: 88.0/480),
        .init(id: "left.upper", x: 2.0/220, y: 93.0/480, width: 56.0/220, height: 64.0/480),
        .init(id: "right.upper", x: 160.0/220, y: 93.0/480, width: 58.0/220, height: 64.0/480),
        .init(id: "left.middle", x: 2.0/220, y: 164.0/480, width: 56.0/220, height: 61.0/480),
        .init(id: "right.middle", x: 160.0/220, y: 164.0/480, width: 58.0/220, height: 61.0/480),
        .init(id: "left.lower", x: 2.0/220, y: 260.0/480, width: 60.0/220, height: 57.0/480),
        .init(id: "right.lower", x: 160.0/220, y: 260.0/480, width: 58.0/220, height: 57.0/480)
    ]
    /// Reserve the entire bottom interaction area, including expanded radial bet controls.
    public static let protectedControls = ScreenRegion(id: "protected.controls", x: 0, y: 0.64, width: 1, height: 0.36)
}
#endif
