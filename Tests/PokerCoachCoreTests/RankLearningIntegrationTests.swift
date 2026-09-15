#if canImport(Vision)
import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class RankLearningIntegrationTests: XCTestCase {
    private func fixture() throws -> CGImage {
        let file = PrivateTestFixtures.file("rank-coverage-fixtures/holdout-as-jh-9d.png")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Private screenshot unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    func testTwoExistingReadersUseSavedGlyphAndUndoWithoutRestart() throws {
        let image = try fixture(), base = try FourColorCardReader.bundledTemplates().filter { $0.rank != "A" }
        let library = RankLearningLibrary()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try library.configure(storageURL: directory.appendingPathComponent("glyphs.json"))
        let readers = [FourColorCardReader(templates: base, additionalTemplates: { library.templates }),
                       FourColorCardReader(templates: base, additionalTemplates: { library.templates })]
        let evidence = try readers[0].read(image, regions: WPKVideoLayout.cardRegions)
        let sample = try XCTUnwrap(RankLearningSample.capture(image, evidence: evidence).first { $0.region == "board.0" })
        XCTAssertEqual(evidence[2].card, "As")
        XCTAssertEqual(evidence[2].reason, "OCR双图一致，仍需跨帧确认")
        try library.save(rank: "A", pixels: sample.pixels, region: sample.region, builtInTemplates: base)
        for reader in readers {
            let updated = try reader.read(image, regions: WPKVideoLayout.cardRegions)
            XCTAssertEqual(updated[2].card, "As")
            XCTAssertEqual(updated[2].reason, "字形候选，仍需跨帧确认")
        }
        try library.removeLast()
        XCTAssertEqual(try readers[0].read(image, regions: WPKVideoLayout.cardRegions)[2].reason, "OCR双图一致，仍需跨帧确认")
    }
    func testSamplesRetainOnlySmallGlyphsForVisibleCardsAndPermitCorrection() throws {
        let image = try fixture(), reader = try FourColorCardReader.wpkVideoProfile()
        let samples = RankLearningSample.capture(image, evidence: try reader.read(image, regions: WPKVideoLayout.cardRegions))
        XCTAssertEqual(samples.map(\.region), ["hero.0", "hero.1", "board.0", "board.1", "board.2"])
        XCTAssertTrue(samples.allSatisfy { !$0.unresolved }, "Already recognized glyphs remain selectable for correction")
        for sample in samples {
            XCTAssertEqual(sample.pixels.count, 768)
            XCTAssertLessThan(sample.previewPNG.count, 4_096)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(sample.previewPNG as CFData, nil))
            let preview = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(preview.width, 24); XCTAssertEqual(preview.height, 32)
        }
    }
    func testExplicitCorrectionFixesKnownUnseenFontSixWithoutChangingRealNine() throws {
        // Historical open-set mechanics counterexample with the pre-5/6 library.
        // The bundled real WPK six is covered separately by GenuineFiveSixCoverageTests.
        let file = PrivateTestFixtures.file("card-reader-synthetic/synthetic-6.png")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Local synthetic counterexample unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let shape = try XCTUnwrap(RankShape.extract(image))
        let base = try FourColorCardReader.bundledTemplates().filter { $0.rank != "5" && $0.rank != "6" }
        XCTAssertEqual(RankShape.match(shape, templates: base)?.rank, "8", "Keep the known open-set failure visible")
        let library = RankLearningLibrary(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try library.configure(storageURL: directory.appendingPathComponent("glyphs.json"))
        let reader = FourColorCardReader(templates: base, additionalTemplates: { library.templates })
        try library.save(rank: "6", pixels: shape, region: "hero.0", builtInTemplates: base)
        let corrected = try reader.read(image, regions: [.init(id: "synthetic", x: 0, y: 0, width: 1, height: 1)])
        XCTAssertEqual(corrected.first?.card, "6c")
        let real = try reader.read(fixture(), regions: WPKVideoLayout.cardRegions)
        XCTAssertEqual(real[4].card, "9d")
    }
}
#endif
