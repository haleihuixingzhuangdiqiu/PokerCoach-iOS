#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class EmptyBoardPresenceTests: XCTestCase {
    private var work: URL {
        PrivateTestFixtures.workRoot
    }
    private func image(_ path: String) throws -> CGImage {
        let url = work.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private real table fixture unavailable: \(path)") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func painting(_ source: CGImage, rectangle: CGRect, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        // CGContext painting is bottom-up; incoming fixture regions use top-left.
        context.setFillColor(color)
        context.fill(CGRect(x: rectangle.minX * Double(source.width),
                            y: (1 - rectangle.maxY) * Double(source.height),
                            width: rectangle.width * Double(source.width), height: rectangle.height * Double(source.height)))
        return try XCTUnwrap(context.makeImage())
    }

    func testSuppliedPreflopAndProductionJPEGHavePositiveEmptyBoardEvidence() throws {
        for file in ["rank-56-fixtures/train-5h4h.jpg", "rank-56-fixtures/train-5h4h-production.jpg",
                     "rank-56-fixtures/train-5h4h-664x1440.jpg", "video-holdout/t012.png",
                     "video-holdout/t043.png", "video-holdout/t058.png", "video-holdout/t090.png"] {
            let input = try image(file)
            XCTAssertTrue(WPKBoardPresence.hasEmptyBoardArea(input), file)
        }
    }

    func testCompleteFlopTurnRiverAndTenFaceCannotBecomePreflop() throws {
        for file in ["video-holdout/t022.png", "video-holdout/t030.png", "video-holdout/t065.png",
                     "video-holdout/t115.png", "rank-56-fixtures/settlement-jd7c-5d4c6d.jpg",
                     "rank-56-fixtures/holdout-as2c-4sts9d.jpg", "rank-56-fixtures/holdout-as2c-4sts9d-production.jpg"] {
            let input = try image(file)
            XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(input), file)
        }
    }

    func testAllDealingAndNearEdgeFlopFramesRemainUnknownOrOccupied() throws {
        // Frames 1–3 are genuinely still empty. Frame 4 first exposes a back in
        // the flight corridor; frame 10 includes the nearly edge-on third card.
        for index in 4...20 {
            let file = String(format: "card-confirm-audit/flop-motion/%04d.jpg", index)
            let input = try image(file)
            XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(input), file)
        }
        for index in [39, 117, 118, 135, 202, 212, 234] {
            let file = String(format: "card-confirm-audit/frames/%04d.jpg", index)
            let input = try image(file)
            XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(input), file)
        }
    }

    func testPopupAndControlCenterCannotSupplyEmptyBoardEvidence() throws {
        for index in [150, 151, 152, 153, 240] {
            let file = String(format: "card-confirm-audit/frames/%04d.jpg", index)
            let input = try image(file)
            XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(input), file)
        }
    }

    func testBlackMaskedBoardOrOneCardRegionCannotBeTreatedAsEmpty() throws {
        let source = try image("video-holdout/t022.png")
        let black = CGColor(gray: 0, alpha: 1)
        let fullBoard = CGRect(x: 48.0 / 220, y: 219.0 / 480, width: 126.0 / 220, height: 40.0 / 480)
        XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(try painting(source, rectangle: fullBoard, color: black)))
        let preflop = try image("rank-56-fixtures/train-5h4h-production.jpg")
        XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(try painting(preflop,
            rectangle: CGRect(x: 0.33, y: 0.465, width: 0.10, height: 0.067), color: black)))
    }

    func testOnePixelBrightEdgeAndThinFlyingBackRejectAnOtherwiseEmptyBoard() throws {
        let source = try image("rank-56-fixtures/train-5h4h-production.jpg")
        let edge = CGRect(x: 0.47, y: 0.47, width: 1.0 / Double(source.width), height: 0.06)
        XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(try painting(source, rectangle: edge, color: CGColor(gray: 1, alpha: 1))))
        let back = CGRect(x: 0.49, y: 0.36, width: 0.003, height: 0.05)
        XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(try painting(source, rectangle: back,
            color: CGColor(red: 0.75, green: 0.15, blue: 0.28, alpha: 1))))
    }

    func testSolidBlueCoverAndWrongOrientationDoNotConfirmEmptyOceanBoard() throws {
        let source = try image("rank-56-fixtures/train-5h4h-production.jpg")
        let cover = CGRect(x: 0.20, y: 0.45, width: 0.60, height: 0.10)
        XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(try painting(source, rectangle: cover,
            color: CGColor(red: 0.03, green: 0.25, blue: 0.45, alpha: 1))))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1440, height: 663,
                                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        XCTAssertFalse(WPKBoardPresence.hasEmptyBoardArea(try XCTUnwrap(context.makeImage())))
    }
}
#endif
