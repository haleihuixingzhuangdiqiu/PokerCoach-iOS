#if canImport(Vision)
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture

/// Real WPK screenshot coverage. No generic font, OCR substitution or relaxed matching threshold.
/// Private screenshots stay under work/, outside the package and mobile bundle.
final class AceTemplateCoverageTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var workRoot: URL { PrivateTestFixtures.workRoot }
    private var fixtures: URL { workRoot.appendingPathComponent("rank-coverage-fixtures") }
    private let trainSHA = "bce471dd0cb1a34546ff1e58ec8bf725c011075edb949ff610e974beb057562d"
    private let holdoutSHA = "1344eb0c3f2bb0a0a6d7e4a8338930401f8492348f25af2c5ab30e6e7115a0a5"
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func load(_ url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Private local coverage fixture unavailable: \(url.lastPathComponent). Run tools/audit_rank_coverage.swift with the supplied sources.")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func templates() throws -> [RankTemplate] {
        let file = projectRoot.appendingPathComponent("Sources/PokerCoachCapture/Resources/wpk-rank-templates.json")
        return try JSONDecoder().decode([RankTemplate].self, from: Data(contentsOf: file))
    }
    private func bundledReader() throws -> FourColorCardReader {
        // Isolate the packaged-template regression from any user-confirmed templates
        // persisted by another run on this Mac. Both readers still use the production pipeline.
        FourColorCardReader(templates: try FourColorCardReader.bundledTemplates())
    }
    private func baseline() throws -> [RankTemplate] {
        let url = fixtures.appendingPathComponent("wpk-rank-templates-before-a.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local pre-A template baseline unavailable") }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(sha(data), "037e750ce10eee598d36fef63db40658eb9d31748a6a1606e6cc71d20ffb59d0")
        return try JSONDecoder().decode([RankTemplate].self, from: data)
    }
    private func shape(_ image: CGImage, _ regionID: String) throws -> [UInt8] {
        let region = try XCTUnwrap(WPKVideoLayout.cardRegions.first { $0.id == regionID })
        return try XCTUnwrap(RankShape.extract(try XCTUnwrap(region.crop(image))))
    }
    private func assertCards(_ file: String, expected: [String?], size: (Int, Int)) throws {
        let image = try load(fixtures.appendingPathComponent(file))
        XCTAssertEqual(image.width, size.0); XCTAssertEqual(image.height, size.1)
        let reader = try bundledReader()
        let cards = try reader.read(image, regions: WPKVideoLayout.cardRegions)
        XCTAssertEqual(cards.map(\.card), expected, file)
        for card in cards where card.card != nil {
            XCTAssertEqual(card.reason, "字形候选，仍需跨帧确认", "All supplied known cards must use the fast template path: \(file) \(card.region)")
            XCTAssertFalse(card.hasUnresolvedCard)
        }
        let region = file.hasPrefix("train") ? "hero.0" : "board.0"
        let pixels = try shape(image, region)
        let match = try XCTUnwrap(RankShape.match(pixels, templates: templates()))
        XCTAssertEqual(match.rank, "A"); XCTAssertLessThanOrEqual(match.distance, 0.16)
        XCTAssertGreaterThanOrEqual(match.margin, 0.04)
        let oldTemplates = try baseline()
        XCTAssertNil(RankShape.match(pixels, templates: oldTemplates), "The old template library did not cover this actual A")
    }

    func testTemplateCoverageRetainsRealAceWithIndependentSource() throws {
        let all = try templates()
        XCTAssertEqual(all.filter { $0.rank == "A" }.count, 1)
        let ace = try XCTUnwrap(all.first { $0.rank == "A" })
        XCTAssertEqual(ace.pixels.count, 24 * 32)
        XCTAssertTrue(ace.source.contains(trainSHA)); XCTAssertFalse(ace.source.contains(holdoutSHA))
    }

    func testOnlyTrainingAcPixelsWereAddedAndOriginalTwentyTemplatesAreUnchanged() throws {
        let all = try templates(), before = try baseline()
        for (old, new) in zip(before, all.prefix(before.count)) {
            XCTAssertEqual(old.rank, new.rank); XCTAssertEqual(old.pixels, new.pixels); XCTAssertEqual(old.source, new.source)
        }
        let trainURL = fixtures.appendingPathComponent("train-ac-jc.png")
        let holdoutURL = fixtures.appendingPathComponent("holdout-as-jh-9d.png")
        let train = try load(trainURL), holdout = try load(holdoutURL)
        XCTAssertEqual(sha(try Data(contentsOf: trainURL)), trainSHA)
        XCTAssertEqual(sha(try Data(contentsOf: holdoutURL)), holdoutSHA)
        let ace = try XCTUnwrap(all.first { $0.rank == "A" })
        XCTAssertEqual(ace.pixels, try shape(train, "hero.0"))
        XCTAssertNotEqual(ace.pixels, try shape(holdout, "board.0"), "The independent holdout is a distinct real glyph sample")
    }

    func testOriginalAcAndIndependentAsScreenshotsReadEveryVisibleCard() throws {
        try assertCards("train-ac-jc.png", expected: ["Ac", "Jc", nil, nil, nil, nil, nil], size: (1320, 2868))
        try assertCards("holdout-as-jh-9d.png", expected: ["Jd", "4d", "As", "Jh", "9d", nil, nil], size: (1320, 2868))
    }

    func testProductionJPEGAndExact664PixelVariantPreserveCardReadings() throws {
        for (suffix, width) in [("production", 663), ("664x1440", 664)] {
            try assertCards("train-ac-jc-\(suffix).jpg", expected: ["Ac", "Jc", nil, nil, nil, nil, nil], size: (width, 1440))
            try assertCards("holdout-as-jh-9d-\(suffix).jpg", expected: ["Jd", "4d", "As", "Jh", "9d", nil, nil], size: (width, 1440))
        }
    }

    func testAddingAceDoesNotChangeAnyCardOrUnresolvedStatusAcross240OldVideoFrames() throws {
        let oldReader = FourColorCardReader(templates: try baseline())
        let newReader = try bundledReader()
        for index in 1...240 {
            try autoreleasepool {
                let file = String(format: "card-confirm-audit/frames/%04d.jpg", index)
                let image = try load(workRoot.appendingPathComponent(file))
                let before = try oldReader.read(image, regions: WPKVideoLayout.cardRegions)
                let after = try newReader.read(image, regions: WPKVideoLayout.cardRegions)
                XCTAssertEqual(before.map(\.card), after.map(\.card), file)
                XCTAssertEqual(before.map(\.hasUnresolvedCard), after.map(\.hasUnresolvedCard), file)
            }
        }
    }

    func testPreviouslyLabeledEightHoldoutFramesStillReadAll31CardsAnd25EmptySlots() throws {
        struct Labels: Decodable { let frames: [String: [String: String]] }
        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: projectRoot.appendingPathComponent("fixtures/video-card-labels.json")))
        let reader = try bundledReader()
        var occupied = 0, empty = 0
        for (file, cards) in labels.frames {
            let image = try load(workRoot.appendingPathComponent("video-holdout/\(file)"))
            for card in try reader.read(image, regions: WPKVideoLayout.cardRegions) {
                XCTAssertEqual(card.card, cards[card.region], "\(file) \(card.region)")
                if cards[card.region] != nil { occupied += 1 } else { empty += 1 }
            }
        }
        XCTAssertEqual(occupied, 31); XCTAssertEqual(empty, 25)
    }
}
#endif
