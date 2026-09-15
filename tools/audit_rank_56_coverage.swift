// Compile against production RegionImaging.swift, RankTemplates.swift and CardRegionReader.swift.
// See reports/genuine-five-six-coverage.md for provenance and frozen/current reader comparisons.
import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import CryptoKit

@main
enum Rank56CoverageAudit {
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func require(_ ok: Bool, _ description: String) throws {
        if !ok { throw NSError(domain: "RankCoverage", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
    }
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "RankCoverage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot load \(url.path)"])
        }
        return image
    }
    static func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    /// Mirrors ScreenFrameTransportProbe's BGRA input and FrameSender's portrait JPEG encoding.
    /// This is an offline encoding check, not a claim that ReplayKit or TCP was exercised.
    static func productionJPEG(_ image: CGImage, widthOverride: Int? = nil) throws -> Data {
        var buffer: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                        kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                    "CVPixelBuffer allocation failed")
        guard let pixel = buffer else { throw NSError(domain: "RankCoverage", code: 3) }
        CVPixelBufferLockBaseAddress(pixel, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(pixel, []); throw NSError(domain: "RankCoverage", code: 4)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.flush()
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let input = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, 1440 / max(input.extent.width, input.extent.height))
        // The optional 664-pixel width is an extra one-column geometry stress case.
        // Leave it nil for the production proportional resize (663×1440 on this Mac).
        let xScale = widthOverride.map { Double($0) / Double(image.width) } ?? scale
        let scaled = input.transformed(by: CGAffineTransform(scaleX: xScale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        guard let data = CIContext(options: [.cacheIntermediates: false]).jpegRepresentation(
            of: translated, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else {
            throw NSError(domain: "RankCoverage", code: 5, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }
        return data
    }
    struct Slot: Codable {
        let region: String
        let before: CardReadEvidence
        let after: CardReadEvidence
        let nearestBefore: Nearest?
        let nearestAfter: Nearest?
    }
    struct Nearest: Codable {
        let rank: String
        let distance: Double
        let margin: Double
        init?(_ match: (rank: String, distance: Double, margin: Double)?) {
            guard let match else { return nil }
            rank = match.rank; distance = match.distance; margin = match.margin
        }
    }
    struct Row: Codable { let file: String; let sha256: String; let width: Int; let height: Int; let slots: [Slot] }
    static func main() throws {
        let args = CommandLine.arguments
        try require(args.count == 3 && ["train", "new", "audit"].contains(args[1]), "Usage: rank-56-audit train|new|audit /absolute/path/to/PokerCoach")
        let project = URL(fileURLWithPath: args[2])
        let work = project.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work")
        let fixtures = work.appendingPathComponent("rank-56-fixtures")
        let templateURL = project.appendingPathComponent("Sources/PokerCoachCapture/Resources/wpk-rank-templates.json")
        let baselineData = try Data(contentsOf: fixtures.appendingPathComponent("before-56.json"))
        try require(sha(baselineData) == "83743b3889746622fa6416b0d02a99aeb74ce242f6c312219986a4a664f8db3b", "21-template baseline changed")
        let baseline = try JSONDecoder().decode([RankTemplate].self, from: baselineData)
        let names = ["settlement-jd7c-5d4c6d.jpg", "train-5h4h.jpg", "holdout-as2c-4sts9d.jpg"]
        let sourceHashes = ["c07cad8e628e58f0ffea5f865f9e26bdfd44db492929d30acf059580f3b4baf3", "418cc6d5456ff8e062b38296da1e9a143efa880432ce615a9bed1257c094ce0e", "4cc36135d489259bd46821fff00825e7e9e44a6270e7c4aa297d8c37be9521c0"]
        if args[1] == "train" {
            var additions: [RankTemplate] = []
            for (rank, source, slot) in [("5", 1, "hero.0"), ("6", 0, "board.2")] {
                let url = fixtures.appendingPathComponent(names[source])
                try require(sha(Data(contentsOf: url)) == sourceHashes[source], "Training source changed")
                let region = WPKVideoLayout.cardRegions.first { $0.id == slot }!
                guard let card = region.crop(try load(url)), let pixels = RankShape.extract(card) else { throw NSError(domain: "Rank56Coverage", code: 6) }
                additions.append(RankTemplate(rank: rank, pixels: pixels, source: "user screenshot " + names[source] + " SHA256=" + sourceHashes[source] + " " + slot + " original 1280x2781; 5d pixels excluded; six has no independent holdout"))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(baseline + additions).write(to: templateURL, options: .atomic)
            print("Added only genuine hero 5h and board 6d, preserving 21 originals.")
            return
        }
        let templates = try JSONDecoder().decode([RankTemplate].self, from: Data(contentsOf: templateURL))
        let oldReader = FourColorCardReader(templates: baseline), newReader = FourColorCardReader(templates: templates)
        var paths = names.map { fixtures.appendingPathComponent($0) }
        for (index, url) in paths.enumerated() { try require(sha(Data(contentsOf: url)) == sourceHashes[index], "Supplied screenshot changed") }
        let originals = paths
        for url in originals {
            try productionJPEG(load(url)).write(to: fixtures.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-production.jpg"), options: .atomic)
            try productionJPEG(load(url), widthOverride: 664).write(to: fixtures.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-664x1440.jpg"), options: .atomic)
        }
        paths += originals.map { fixtures.appendingPathComponent($0.deletingPathExtension().lastPathComponent + "-production.jpg") }
        paths += originals.map { fixtures.appendingPathComponent($0.deletingPathExtension().lastPathComponent + "-664x1440.jpg") }
        if args[1] == "audit" {
            paths += (1...240).map { work.appendingPathComponent(String(format: "card-confirm-audit/frames/%04d.jpg", $0)) }
            paths += ["t012", "t022", "t030", "t043", "t058", "t065", "t090", "t115"].map { work.appendingPathComponent("video-holdout/\($0).png") }
        }
        var rows: [Row] = []
        for url in paths {
            rows.append(try autoreleasepool { () throws -> Row in
                let image = try load(url)
                let before = try oldReader.read(image, regions: WPKVideoLayout.cardRegions)
                let after = try newReader.read(image, regions: WPKVideoLayout.cardRegions)
                let slots = WPKVideoLayout.cardRegions.enumerated().map { index, region -> Slot in
                    let pixels = region.crop(image).flatMap { RankShape.extract($0) }
                    return Slot(region: region.id, before: before[index], after: after[index], nearestBefore: Nearest(pixels.flatMap { RankShape.nearest($0, templates: baseline) }), nearestAfter: Nearest(pixels.flatMap { RankShape.nearest($0, templates: templates) }))
                }
                return Row(file: url.lastPathComponent, sha256: sha(try Data(contentsOf: url)), width: image.width, height: image.height, slots: slots)
            })
        }
        let output = fixtures.appendingPathComponent(args[1] == "audit" ? "comparison.json" : "new-comparison.json")
        try writeJSON(rows, output)
        print("Saved \(rows.count) frame comparisons to \(output.path)")
    }
}
