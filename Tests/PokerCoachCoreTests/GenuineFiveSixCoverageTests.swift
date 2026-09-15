#if canImport(Vision)
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture
import PokerCoachCore

/// Only real WPK glyphs train the bundled deck; resized copies are not independent holdouts.
final class GenuineFiveSixCoverageTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixtureRoot: URL {
        PrivateTestFixtures.file("rank-56-fixtures")
    }
    private let fiveSHA = "418cc6d5456ff8e062b38296da1e9a143efa880432ce615a9bed1257c094ce0e"
    private let sixSHA = "c07cad8e628e58f0ffea5f865f9e26bdfd44db492929d30acf059580f3b4baf3"
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func data(_ name: String) throws -> Data {
        let url = fixtureRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private real WPK fixture unavailable: \(name)") }
        return try Data(contentsOf: url)
    }
    private func image(_ name: String) throws -> CGImage {
        let contents = try data(name)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(contents as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func shape(_ image: CGImage, region id: String) throws -> [UInt8] {
        let region = try XCTUnwrap(WPKVideoLayout.cardRegions.first { $0.id == id })
        return try XCTUnwrap(RankShape.extract(try XCTUnwrap(region.crop(image))))
    }

    func testBundledDeckCoversAllThirteenRanksWithoutPrivateFixtures() throws {
        let all = try FourColorCardReader.bundledTemplates()
        XCTAssertEqual(all.count, 23)
        XCTAssertEqual(Set(all.map(\.rank)), Set(RankLearningLibrary.ranks))
        let five = try XCTUnwrap(all.first { $0.rank == "5" })
        let six = try XCTUnwrap(all.first { $0.rank == "6" })
        XCTAssertTrue(five.source.contains(fiveSHA))
        XCTAssertFalse(five.source.contains(sixSHA))
        XCTAssertTrue(six.source.contains(sixSHA))
    }

    func testOriginalTwentyOneTemplatesPreservedAndAllThirteenRanksHaveRealSources() throws {
        let beforeData = try data("before-56.json")
        let before = try JSONDecoder().decode([RankTemplate].self, from: beforeData)
        XCTAssertEqual(sha(beforeData), "83743b3889746622fa6416b0d02a99aeb74ce242f6c312219986a4a664f8db3b")
        let all = try FourColorCardReader.bundledTemplates()
        XCTAssertEqual(all.count, 23)
        XCTAssertEqual(Set(all.map(\.rank)), Set(RankLearningLibrary.ranks))
        for (old, current) in zip(before, all.prefix(21)) {
            XCTAssertEqual(old.rank, current.rank); XCTAssertEqual(old.pixels, current.pixels); XCTAssertEqual(old.source, current.source)
        }
        let five = try XCTUnwrap(all.first { $0.rank == "5" }), six = try XCTUnwrap(all.first { $0.rank == "6" })
        XCTAssertTrue(five.source.contains(fiveSHA)); XCTAssertFalse(five.source.contains(sixSHA))
        XCTAssertTrue(six.source.contains(sixSHA))
    }

    func testTrainingUsesOnlyFiveHeartsAndSixDiamondsAndExcludesFiveDiamondsPixels() throws {
        let all = try FourColorCardReader.bundledTemplates()
        let five = try XCTUnwrap(all.first { $0.rank == "5" }), six = try XCTUnwrap(all.first { $0.rank == "6" })
        let fiveData = try data("train-5h4h.jpg"), sixData = try data("settlement-jd7c-5d4c6d.jpg")
        let fiveImage = try image("train-5h4h.jpg"), sixImage = try image("settlement-jd7c-5d4c6d.jpg")
        XCTAssertEqual(sha(fiveData), fiveSHA)
        XCTAssertEqual(sha(sixData), sixSHA)
        XCTAssertEqual(five.pixels, try shape(fiveImage, region: "hero.0"))
        XCTAssertEqual(six.pixels, try shape(sixImage, region: "board.2"))
        XCTAssertNotEqual(five.pixels, try shape(sixImage, region: "board.0"))
    }

    func testRealFiveHoldoutAndSixRemainCorrectAcrossProductionJPEGDimensions() throws {
        let reader = FourColorCardReader(templates: try FourColorCardReader.bundledTemplates())
        for suffix in [".jpg", "-production.jpg", "-664x1440.jpg"] {
            for (name, expected) in [
                ("train-5h4h", ["5h", "4h", nil, nil, nil, nil, nil]),
                ("settlement-jd7c-5d4c6d", ["Jd", "7c", "5d", "4c", "6d", nil, nil])
            ] {
                let cards = try reader.read(image(name + suffix), regions: WPKVideoLayout.cardRegions)
                XCTAssertEqual(cards.map(\.card), expected, name + suffix)
                XCTAssertFalse(cards.contains { $0.hasUnresolvedCard })
                for card in cards where card.card != nil {
                    XCTAssertEqual(card.reason, "字形候选，仍需跨帧确认", name + suffix)
                }
            }
        }
    }

    func testKnownRealSixToEightFailureIsFixedAndRealNineStaysDistinct() throws {
        let baseline = try JSONDecoder().decode([RankTemplate].self, from: data("before-56.json"))
        let all = try FourColorCardReader.bundledTemplates()
        let six = try shape(image("settlement-jd7c-5d4c6d.jpg"), region: "board.2")
        XCTAssertEqual(RankShape.match(six, templates: baseline)?.rank, "8", "Retain the real historical misclassification as evidence")
        for suffix in [".jpg", "-production.jpg", "-664x1440.jpg"] {
            let six = try shape(image("settlement-jd7c-5d4c6d" + suffix), region: "board.2")
            let nine = try shape(image("holdout-as2c-4sts9d" + suffix), region: "board.2")
            XCTAssertEqual(RankShape.match(six, templates: all)?.rank, "6")
            XCTAssertEqual(RankShape.match(nine, templates: all)?.rank, "9")
        }
    }

    func testWideTenFaceIsNotAnEmptyBoardSlotAndConfirmsAfterTwoFreshReads() throws {
        let reader = FourColorCardReader(templates: try FourColorCardReader.bundledTemplates())
        for suffix in [".jpg", "-production.jpg", "-664x1440.jpg"] {
            let input = try image("holdout-as2c-4sts9d" + suffix)
            let first = try reader.read(input, regions: WPKVideoLayout.cardRegions)
            let second = try reader.read(input, regions: WPKVideoLayout.cardRegions)
            XCTAssertEqual(first.map(\.card), ["As", "2c", "4s", "Ts", "9d", nil, nil])
            XCTAssertFalse(first.contains { $0.hasUnresolvedCard })
            var gate = LiveCardGate()
            gate.ingest(slots: first.map(\.card), timestamp: 1, now: 1.01)
            XCTAssertNil(gate.position)
            gate.ingest(slots: second.map(\.card), timestamp: 1.1, now: 1.11)
            XCTAssertNotNil(gate.position, suffix)
        }
    }
}
#endif
