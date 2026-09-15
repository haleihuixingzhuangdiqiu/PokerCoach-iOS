#if canImport(Vision)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small normalized rank glyphs only. No table screenshot or opponent information is retained.
public struct RankLearningSample: Sendable, Identifiable {
    public var id: String { region }
    public let region: String
    public let pixels: [UInt8]
    public let previewPNG: Data
    public let unresolved: Bool
    public var label: String {
        let number = (Int(region.split(separator: ".").last ?? "") ?? 0) + 1
        return (region.hasPrefix("hero") ? "底" : "公") + String(number)
    }

    public static func capture(_ image: CGImage, evidence: [CardReadEvidence]) -> [RankLearningSample] {
        evidence.compactMap { item in
            guard item.card != nil || item.hasUnresolvedCard,
                  let region = WPKVideoLayout.cardRegions.first(where: { $0.id == item.region }),
                  let card = region.crop(image), let shape = RankShape.extract(card),
                  let preview = preview(shape) else { return nil }
            return RankLearningSample(region: item.region, pixels: shape, previewPNG: preview, unresolved: item.hasUnresolvedCard)
        }
    }
    private static func preview(_ shape: [UInt8]) -> Data? {
        guard shape.count == 768 else { return nil }
        let data = Data(shape.map { 255 - $0 })
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 24, height: 32, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: 24, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
#endif
