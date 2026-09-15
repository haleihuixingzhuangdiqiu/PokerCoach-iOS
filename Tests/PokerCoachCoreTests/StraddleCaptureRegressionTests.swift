#if canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class StraddleCaptureRegressionTests: XCTestCase {
    private func frame(_ number: Int) throws -> CGImage {
        let url = PrivateTestFixtures.workRoot.appendingPathComponent(String(format: "card-confirm-audit/frames/%04d.jpg", number))
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local video fixture unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testHeroStraddleIsReadFromItsPrintedLabelInBothRealHands() throws {
        let reader = WPKTableSnapshotReader()
        // 0102 located the missing hero ROI. The QQ hand was reserved for
        // validation, with no separate crop or threshold adjustment.
        for number in [102, 103, 104, 105, 106, 161, 162, 163, 164] {
            let evidence = try reader.read(frame(number))
            XCTAssertEqual(evidence.straddleSeat, 7, "frame \(number)")
            XCTAssertEqual(evidence.seats[7].straddle?.rawText, "Straddle", "frame \(number)")
            XCTAssertGreaterThanOrEqual(evidence.seats[7].straddle?.confidence ?? 0, 0.9, "frame \(number)")
            XCTAssertEqual(evidence.seats.filter { $0.straddle != nil }.count, 1, "frame \(number)")
            XCTAssertEqual(evidence.dealerSeat, 1, "frame \(number)")
            XCTAssertEqual(evidence.blindText?.rawText, "0.2/0.5/1", "frame \(number)")
        }
    }

    func testTopBlueVioletLabelAndExistingSideLabelKeepTheirActualSeat() throws {
        let reader = WPKTableSnapshotReader()
        for number in [77, 78, 79, 80] {
            let evidence = try reader.read(frame(number))
            XCTAssertEqual(evidence.straddleSeat, 0, "frame \(number)")
            XCTAssertEqual(evidence.seats[0].straddle?.rawText, "Straddle", "frame \(number)")
            XCTAssertNil(evidence.seats[7].straddle, "frame \(number)")
        }
        let sideLabel = try reader.read(frame(18))
        XCTAssertEqual(sideLabel.straddleSeat, 5)
    }

    func testVisibleOneChipAndEarlierLabelDoNotImplyCurrentStraddleEvidence() throws {
        let reader = WPKTableSnapshotReader()
        let initial = try reader.read(frame(102))
        XCTAssertEqual(initial.straddleSeat, 7)
        // The literal label has disappeared in these captures while the
        // one-unit chip remains. This reader must not invent or carry it forward.
        for number in [107, 108, 109, 110, 166, 186] {
            let evidence = try reader.read(frame(number))
            XCTAssertEqual(evidence.seats[7].currentStreetWager?.rawText, "1", "frame \(number)")
            XCTAssertNil(evidence.straddleSeat, "frame \(number)")
            XCTAssertNil(evidence.seats[7].straddle, "frame \(number)")
        }
        for number in [44, 81, 119, 129] {
            let evidence = try reader.read(frame(number))
            XCTAssertNil(evidence.straddleSeat, "frame \(number)")
        }
    }

    func testPurpleColorWithoutThePrintedWordCannotCreateStraddle() throws {
        let original = try frame(102), reader = WPKTableSnapshotReader()
        let initial = try reader.read(original)
        XCTAssertEqual(initial.straddleSeat, 7)
        let context = try XCTUnwrap(CGContext(data: nil, width: original.width, height: original.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        // A conspicuously purple field passes the cheap color check but has no
        // text. The original visible one-unit wager is outside this rectangle.
        let rect = CGRect(x: 205, y: 1154, width: 107, height: 43)
        context.setFillColor(CGColor(red: 0.45, green: 0.15, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: rect.minX / 720 * CGFloat(original.width),
            y: (1 - rect.maxY / 1564) * CGFloat(original.height),
            width: rect.width / 720 * CGFloat(original.width), height: rect.height / 1564 * CGFloat(original.height)))
        let obscured = try reader.read(XCTUnwrap(context.makeImage()))
        XCTAssertNil(obscured.straddleSeat)
        XCTAssertNil(obscured.seats[7].straddle)
        XCTAssertEqual(obscured.seats[7].currentStreetWager?.rawText, "1")
    }
}
#endif
