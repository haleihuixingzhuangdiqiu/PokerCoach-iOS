#if canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class TableSnapshotCaptureTests: XCTestCase {
    private var root: URL { PrivateTestFixtures.workRoot }
    private func fixture(_ path: String) throws -> CGImage {
        let file = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Local fixture unavailable") }
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil)), 0, nil))
    }
    func testSnapshotDiagnostics() throws {
        let reader = WPKTableSnapshotReader()
        let names = ["card-confirm-audit/frames/0018.jpg", "card-confirm-audit/frames/0044.jpg", "card-confirm-audit/frames/0186.jpg",
                     "video-holdout/t022.png", "rank-56-fixtures/train-5h4h-production.jpg", "rank-56-fixtures/holdout-as2c-4sts9d-production.jpg"]
        var results: [String: WPKTableSnapshotEvidence] = [:]
        var times: [String: Double] = [:]
        for name in names {
            let start = ProcessInfo.processInfo.systemUptime
            results[name] = try reader.read(try fixture(name))
            times[name] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        try FileManager.default.createDirectory(at: PrivateTestFixtures.artifactRoot.appendingPathComponent("table-snapshot-audit"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: PrivateTestFixtures.artifactRoot.appendingPathComponent("table-snapshot-audit/initial.json"))
        try encoder.encode(times).write(to: PrivateTestFixtures.artifactRoot.appendingPathComponent("table-snapshot-audit/times.json"))
        XCTAssertEqual(results[names[0]]?.seats.count, 8)
    }

    func testRealBlindOnlyTableHasEightStacksPositionsAndPositiveEmptyAreas() throws {
        let result = try WPKTableSnapshotReader().read(try fixture("card-confirm-audit/frames/0018.jpg"))
        XCTAssertEqual(result.seats.map { $0.stack?.rawText }, ["25.9", "38.49", "200", "494.95", "112.56", "130.63", "44.2", "49.8"])
        XCTAssertEqual(result.dealerSeat, 3)
        XCTAssertEqual(result.straddleSeat, 5)
        XCTAssertEqual(result.blindText?.rawText, "0.2/0.5/1")
        XCTAssertEqual(result.raw["table.pot"]?.rawText, "1.7")
        XCTAssertEqual(result.seats.map { $0.currentStreetWager?.rawText }, [nil, nil, nil, nil, "0.5", "1", nil, "0.2"])
        XCTAssertEqual(result.seats.filter { $0.streetWagerAreaClear != nil }.map(\.index), [0, 1, 2, 3, 6])
        XCTAssertEqual(result.seats.filter { $0.positiveCards != nil }.map(\.index), [4, 5, 7])
        XCTAssertEqual(result.seats.filter { $0.folded != nil }.map(\.index), [0, 1, 2, 3, 6])
    }

    func testFlopClearTableAndHigherResolutionCounterpart() throws {
        for path in ["card-confirm-audit/frames/0044.jpg", "video-holdout/t022.png"] {
            let result = try WPKTableSnapshotReader().read(try fixture(path))
            XCTAssertEqual(result.dealerSeat, 4, path)
            XCTAssertEqual(result.seats.map { $0.stack?.rawText }, ["70.78", "39.96", "82.24", "45.4", "104.46", "202.73", "8.55", "48.8"])
            XCTAssertTrue(result.seats.allSatisfy { $0.streetWagerAreaClear != nil && $0.currentStreetWager == nil }, path)
            XCTAssertEqual(result.seats.filter { $0.folded != nil }.map(\.index), [0, 1, 2, 3, 4, 6], path)
            XCTAssertEqual(result.seats.filter { $0.positiveCards != nil }.map(\.index), [5, 7], path)
            XCTAssertEqual(result.raw["table.pot"]?.rawText, "3.5")
            XCTAssertEqual(result.raw["table.settledPot"]?.rawText, "3.5")
        }
    }

    func testRealMultiwayAllInDoesNotDiscardFoldedContributions() throws {
        let result = try WPKTableSnapshotReader().read(try fixture("card-confirm-audit/frames/0186.jpg"))
        XCTAssertEqual(result.dealerSeat, 1)
        XCTAssertEqual(result.seats.map { $0.stack?.rawText }, ["0", "157.59", "84.29", "48", "62.41", "73.99", "114.68", "48.63"])
        XCTAssertEqual(result.seats.map { $0.currentStreetWager?.rawText }, ["11.22", nil, "0.2", "0.5", nil, "2.8", "2.8", "1"])
        XCTAssertEqual(result.seats.filter { $0.streetWagerAreaClear != nil }.map(\.index), [1, 4])
        XCTAssertEqual(result.seats.filter { $0.allIn != nil }.map(\.index), [0])
        XCTAssertEqual(result.seats.filter { $0.positiveCards != nil }.map(\.index), [0, 5, 6, 7])
        XCTAssertEqual(result.raw["table.pot"]?.rawText, "18.52")
        XCTAssertEqual(result.seats[0].stack?.recognitionMethod, "visible-stack-zero-template-v1")
        XCTAssertEqual(result.seats[6].currentStreetWager?.rawText, "2.8", "Must recognize the dot from the actual crop, not substitute a comma")
    }

    func testNextHandsReadActualHalfBlindAndDealerAcrossCompressionChanges() throws {
        let reader = WPKTableSnapshotReader()
        for frame in [24, 31, 38, 77, 88] {
            let result = try reader.read(try fixture(String(format: "card-confirm-audit/frames/%04d.jpg", frame)))
            XCTAssertEqual(result.seats[6].currentStreetWager?.rawText, "0.5", "frame \(frame)")
            XCTAssertEqual(result.seats[6].currentStreetWager?.confidence, 1, "frame \(frame)")
            XCTAssertEqual(result.dealerSeat, 4, "frame \(frame)")
        }
    }

    func testOverlayTextIsNotAPlayerAndNewPrintedWagersRemainExact() throws {
        let five = try WPKTableSnapshotReader().read(try fixture("rank-56-fixtures/train-5h4h-production.jpg"))
        XCTAssertNil(five.seats[0].playerName); XCTAssertNil(five.seats[0].folded); XCTAssertNil(five.seats[0].allIn)
        XCTAssertNil(five.seats[0].actionLabel)
        XCTAssertEqual(five.dealerSeat, 5)
        XCTAssertEqual(five.seats.map { $0.currentStreetWager?.rawText }, ["3.5", "1", nil, nil, nil, "3.5", "0.2", "1"])
        let ten = try WPKTableSnapshotReader().read(try fixture("rank-56-fixtures/holdout-as2c-4sts9d-production.jpg"))
        XCTAssertNil(ten.seats[0].playerName); XCTAssertNil(ten.seats[0].folded); XCTAssertNil(ten.seats[0].allIn)
        XCTAssertEqual(ten.seats[6].currentStreetWager?.rawText, "4.6")
        XCTAssertEqual(ten.seats.filter { $0.streetWagerAreaClear != nil }.count, 7)
    }

    func testMissingMarkerNumberOrZeroGlyphRemainsUnknown() throws {
        let original = try fixture("card-confirm-audit/frames/0186.jpg")
        let reader = WPKTableSnapshotReader()
        let hiddenMarker = try covering(original, rect: CGRect(x: 151, y: 358, width: 38, height: 36))
        let result = try reader.read(hiddenMarker)
        XCTAssertNil(result.seats[6].currentStreetWager); XCTAssertNil(result.seats[6].streetWagerAreaClear)
        let hiddenNumber = try covering(original, rect: CGRect(x: 314, y: 362, width: 100, height: 30))
        let missingNumber = try reader.read(hiddenNumber)
        XCTAssertNil(missingNumber.seats[0].currentStreetWager); XCTAssertNil(missingNumber.seats[0].streetWagerAreaClear)
        let hiddenZero = try covering(original, rect: CGRect(x: 346, y: 294, width: 31, height: 27))
        let missingZero = try reader.read(hiddenZero)
        XCTAssertNotNil(missingZero.seats[0].allIn)
        XCTAssertNil(missingZero.seats[0].stack, "An All-in badge does not infer the unreadable stack is zero")
    }

    func testFlatBlueMaskCannotPretendToBeEmptyBackground() throws {
        let image = try covering(try fixture("card-confirm-audit/frames/0044.jpg"), rect: CGRect(x: 120, y: 620, width: 100, height: 69))
        let result = try WPKTableSnapshotReader().read(image)
        XCTAssertNil(result.seats[5].currentStreetWager); XCTAssertNil(result.seats[5].streetWagerAreaClear)
    }

    func testExactROICacheIgnoresUnrelatedPixelsButNeverReusesChangedAmount() throws {
        let reader = WPKTableSnapshotReader(), original = try fixture("card-confirm-audit/frames/0018.jpg")
        _ = try reader.read(original)
        let count = reader.recognitionRequestCount
        _ = try reader.read(original)
        XCTAssertEqual(reader.recognitionRequestCount, count)
        // A point in the central empty table is outside all field ROIs.
        _ = try reader.read(covering(original, rect: CGRect(x: 350, y: 550, width: 15, height: 15)))
        XCTAssertEqual(reader.recognitionRequestCount, count)
        let obscured = try reader.read(covering(original, rect: CGRect(x: 302, y: 1454, width: 122, height: 38)))
        XCTAssertGreaterThan(reader.recognitionRequestCount, count)
        XCTAssertNil(obscured.seats[7].stack)
    }

    func testWarmSnapshotTimingAndChangedFieldReads() throws {
        let reader = WPKTableSnapshotReader()
        let images = try [fixture("card-confirm-audit/frames/0018.jpg"), fixture("card-confirm-audit/frames/0186.jpg")]
        var rows: [[String: Double]] = []
        for index in [0, 0, 0, 1, 1] {
            let before = reader.recognitionRequestCount, start = ProcessInfo.processInfo.systemUptime
            _ = try reader.read(images[index])
            rows.append(["fixture": Double(index), "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                         "visionRequests": Double(reader.recognitionRequestCount - before)])
        }
        XCTAssertGreaterThan(rows[0]["visionRequests"]!, 0)
        XCTAssertEqual(rows[1]["visionRequests"], 0); XCTAssertEqual(rows[2]["visionRequests"], 0)
        XCTAssertGreaterThan(rows[3]["visionRequests"]!, 0); XCTAssertEqual(rows[4]["visionRequests"], 0)
        try FileManager.default.createDirectory(at: PrivateTestFixtures.artifactRoot.appendingPathComponent("table-snapshot-audit"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: PrivateTestFixtures.artifactRoot.appendingPathComponent("table-snapshot-audit/warm-times.json"))
    }

    private func covering(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(red: 0.04, green: 0.12, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: rect.minX / 720 * CGFloat(image.width), y: (1 - rect.maxY / 1564) * CGFloat(image.height),
            width: rect.width / 720 * CGFloat(image.width), height: rect.height / 1564 * CGFloat(image.height)))
        return try XCTUnwrap(context.makeImage())
    }
}
#endif
