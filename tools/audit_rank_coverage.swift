// Compile against the production RegionImaging.swift, RankTemplates.swift and CardRegionReader.swift.
// See docs/PUBLIC-REPOSITORY.md. Train writes a candidate, never the bundled resource.
import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import CryptoKit

@main
enum RankCoverageAudit {
    static let trainName = "train-ac-jc.png"
    static let holdoutName = "holdout-as-jh-9d.png"
    static let trainSHA = "bce471dd0cb1a34546ff1e58ec8bf725c011075edb949ff610e974beb057562d"
    static let holdoutSHA = "1344eb0c3f2bb0a0a6d7e4a8338930401f8492348f25af2c5ab30e6e7115a0a5"
    static let baselineSHA = "037e750ce10eee598d36fef63db40658eb9d31748a6a1606e6cc71d20ffb59d0"
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
    struct Manifest: Codable {
        let schemaVersion: Int
        let templateSHA256: String
        let baselineSHA256: String
        let comparisonSHA256: String
        let readerSourceSHA256: [String: String]
        let scope: String
    }
    static func main() throws {
        let args = CommandLine.arguments
        try require(args.count == 3 && ["train", "audit"].contains(args[1]), "Usage: rank-coverage-audit train|audit /absolute/path/to/PokerCoach")
        let project = URL(fileURLWithPath: args[2])
        let work = ProcessInfo.processInfo.environment["POKER_PRIVATE_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? project.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work")
        let fixtures = work.appendingPathComponent("rank-coverage-fixtures")
        let templateURL = project.appendingPathComponent("Sources/PokerCoachCapture/Resources/wpk-rank-templates.json")
        let baselineData = try Data(contentsOf: fixtures.appendingPathComponent("wpk-rank-templates-before-a.json"))
        try require(sha(baselineData) == baselineSHA, "The saved baseline is not the reviewed 20-template source")
        let baseline = try JSONDecoder().decode([RankTemplate].self, from: baselineData)
        let templateData = try Data(contentsOf: templateURL)
        let templates = try JSONDecoder().decode([RankTemplate].self, from: templateData)
        try require(templates.count == 23 && Set(templates.map(\.rank)) == Set("23456789TJQKA".map(String.init)),
                    "This audit expects the current 23-template A/5/6 library")
        try require(baseline.count == 20 && zip(baseline, templates.prefix(20)).allSatisfy {
            $0.rank == $1.rank && $0.pixels == $1.pixels && $0.source == $1.source
        }, "Current library must retain the original 20 templates")
        let trainURL = fixtures.appendingPathComponent(trainName)
        try require(sha(Data(contentsOf: trainURL)) == trainSHA, "Training screenshot SHA mismatch")

        if args[1] == "train" {
            // No holdout image is loaded on this path. Only the genuine Ac screenshot contributes pixels.
            let train = try load(trainURL)
            let region = WPKVideoLayout.cardRegions.first { $0.id == "hero.0" }!
            guard let card = region.crop(train), let pixels = RankShape.extract(card) else {
                throw NSError(domain: "RankCoverage", code: 6, userInfo: [NSLocalizedDescriptionKey: "Real Ac glyph could not be extracted"])
            }
            let ace = RankTemplate(rank: "A", pixels: pixels,
                                   source: "user screenshot codex-clipboard-e6d17b4c-8c3f-4442-aa5f-ddcf00947492.png SHA256=" + trainSHA + " hero.0 Ac original 1320x2868; independent As holdout excluded")
            guard let index = templates.firstIndex(where: { $0.rank == "A" }),
                  templates.filter({ $0.rank == "A" }).count == 1 else {
                throw NSError(domain: "RankCoverage", code: 7, userInfo: [NSLocalizedDescriptionKey: "Expected one current A template"])
            }
            var candidate = templates; candidate[index] = ace
            let candidateURL = fixtures.appendingPathComponent("wpk-rank-templates-candidate-a.json")
            try require(candidateURL.resolvingSymlinksInPath() != templateURL.resolvingSymlinksInPath(),
                        "Candidate output must not resolve to the bundled resource")
            try writeJSON(candidate, candidateURL)
            print("Candidate only: \(candidateURL.path). Bundled resource untouched; existing 5/6 retained. Six still has no independent holdout.")
            return
        }

        let holdoutURL = fixtures.appendingPathComponent(holdoutName)
        try require(sha(Data(contentsOf: holdoutURL)) == holdoutSHA, "Independent holdout screenshot SHA mismatch")
        let oldReader = FourColorCardReader(templates: baseline)
        let newReader = FourColorCardReader(templates: templates)
        var paths = [trainURL, holdoutURL]
        for original in paths {
            let jpegURL = fixtures.appendingPathComponent(original.deletingPathExtension().lastPathComponent + "-production.jpg")
            try productionJPEG(load(original)).write(to: jpegURL, options: .atomic)
            let evenURL = fixtures.appendingPathComponent(original.deletingPathExtension().lastPathComponent + "-664x1440.jpg")
            try productionJPEG(load(original), widthOverride: 664).write(to: evenURL, options: .atomic)
        }
        let originals = paths
        paths += originals.map { fixtures.appendingPathComponent($0.deletingPathExtension().lastPathComponent + "-production.jpg") }
        paths += originals.map { fixtures.appendingPathComponent($0.deletingPathExtension().lastPathComponent + "-664x1440.jpg") }
        paths += (1...240).map { work.appendingPathComponent(String(format: "card-confirm-audit/frames/%04d.jpg", $0)) }
        paths += ["t012", "t022", "t030", "t043", "t058", "t065", "t090", "t115"].map { work.appendingPathComponent("video-holdout/\($0).png") }
        var rows: [Row] = []
        for url in paths {
            let row = try autoreleasepool { () throws -> Row in
                let image = try load(url)
                let before = try oldReader.read(image, regions: WPKVideoLayout.cardRegions)
                let after = try newReader.read(image, regions: WPKVideoLayout.cardRegions)
                let slots = WPKVideoLayout.cardRegions.enumerated().map { index, region -> Slot in
                    let pixels = region.crop(image).flatMap { RankShape.extract($0) }
                    return Slot(region: region.id, before: before[index], after: after[index],
                                nearestBefore: Nearest(pixels.flatMap { RankShape.nearest($0, templates: baseline) }),
                                nearestAfter: Nearest(pixels.flatMap { RankShape.nearest($0, templates: templates) }))
                }
                return Row(file: url.lastPathComponent, sha256: sha(try Data(contentsOf: url)), width: image.width, height: image.height, slots: slots)
            }
            rows.append(row)
        }
        let output = fixtures.appendingPathComponent("comparison-current.json")
        try writeJSON(rows, output)
        var sourceHashes: [String: String] = [:]
        for name in ["RegionImaging.swift", "RankTemplates.swift", "CardRegionReader.swift"] {
            sourceHashes[name] = try sha(Data(contentsOf: project.appendingPathComponent("Sources/PokerCoachCapture/" + name)))
        }
        try require(sha(Data(contentsOf: templateURL)) == sha(templateData), "Templates changed during audit")
        let manifest = Manifest(schemaVersion: 1, templateSHA256: sha(templateData), baselineSHA256: sha(baselineData),
            comparisonSHA256: try sha(Data(contentsOf: output)), readerSourceSHA256: sourceHashes,
            scope: "Current 23-template library: A screenshot holdout and same-reader replay. This does not independently validate 5/6; six has no independent holdout.")
        try writeJSON(manifest, fixtures.appendingPathComponent("comparison-current-manifest.json"))
        print("Saved \(rows.count) current-library rows and source manifest to \(output.path); run check_rank_coverage.py to verify.")
    }
}
