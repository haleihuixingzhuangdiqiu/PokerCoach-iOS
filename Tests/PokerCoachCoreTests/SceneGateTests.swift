import XCTest
@testable import PokerCoachCapture
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

final class SceneGateTests: XCTestCase {
    private func image(panel: Bool = false, brightStrip: Bool = false, redRects: [CGRect] = [], orangeBadge: Bool = false) throws -> CGImage {
        let width = 720, height = 1564
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Use top-left coordinates, like the orientation-corrected input frame.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.05, green: 0.20, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for index in 0..<5 {
            context.fill(CGRect(x: Double(48 + index * 24) / 220 * Double(width), y: 219.0 / 480 * Double(height),
                                width: 24.0 / 220 * Double(width), height: 40.0 / 480 * Double(height)))
        }
        context.fill(CGRect(x: 86.0 / 220 * Double(width), y: 397.0 / 480 * Double(height),
                            width: 48.0 / 220 * Double(width), height: 36.0 / 480 * Double(height)))
        if panel {
            context.fill(CGRect(x: 0.11 * Double(width), y: 0.41 * Double(height),
                                width: 0.78 * Double(width), height: 0.18 * Double(height)))
        }
        if brightStrip {
            context.fill(CGRect(x: 0, y: 0.40 * Double(height), width: Double(width), height: 0.04 * Double(height)))
        }
        context.setFillColor(CGColor(red: 0.68, green: 0.18, blue: 0.27, alpha: 1))
        for rect in redRects {
            context.fill(CGRect(x: rect.minX * Double(width), y: rect.minY * Double(height),
                                width: rect.width * Double(width), height: rect.height * Double(height)))
        }
        if orangeBadge {
            context.setFillColor(CGColor(red: 0.95, green: 0.40, blue: 0.04, alpha: 1))
            context.fill(CGRect(x: 0.43 * Double(width), y: 0.38 * Double(height),
                                width: 0.14 * Double(width), height: 0.035 * Double(height)))
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testFiveWhitePublicCardsAndHeroCardsDoNotBlockTable() throws {
        XCTAssertFalse(WPKSceneGate.hasWhitePanelObstruction(try image()))
    }

    func testLargeWhitePanelAcrossOutsideCardAreasBlocksTable() throws {
        XCTAssertTrue(WPKSceneGate.hasWhitePanelObstruction(try image(panel: true)))
    }

    func testOneWhiteStripIsNotEnoughToBlockTable() throws {
        XCTAssertFalse(WPKSceneGate.hasWhitePanelObstruction(try image(brightStrip: true)))
    }

    func testRedBackAboveBoardBlocksButWhiteCardsAndSidePlayersDoNot() throws {
        XCTAssertTrue(WPKSceneGate.hasBoardDealingAnimation(try image(redRects: [
            CGRect(x: 0.48, y: 0.40, width: 0.10, height: 0.05)
        ])))
        XCTAssertFalse(WPKSceneGate.hasBoardDealingAnimation(try image()))
        let redSuitAreas = (0..<5).map { index in
            CGRect(x: 0.241 + Double(index) * 0.109, y: 0.49, width: 0.055, height: 0.025)
        }
        let sidePlayerBacks = [CGRect(x: 0.02, y: 0.40, width: 0.05, height: 0.05),
                               CGRect(x: 0.91, y: 0.40, width: 0.05, height: 0.05)]
        XCTAssertFalse(WPKSceneGate.hasBoardDealingAnimation(try image(redRects: redSuitAreas + sidePlayerBacks)))
        XCTAssertFalse(WPKSceneGate.hasBoardDealingAnimation(try image(orangeBadge: true)))
    }

    private func localFixture(_ path: String) throws -> CGImage {
        let file = fixtureRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Local supplied-video fixture unavailable: \(path)") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private var fixtureRoot: URL {
        PrivateTestFixtures.workRoot
    }

    func testRealTurnBackBlocksOldFlopWhileFollowingFrameRecovers() throws {
        for file in ["card-confirm-audit/frames/0135.jpg", "card-confirm-audit/frames/0212.jpg", "video-hd/t28.png"] {
            let input = try localFixture(file)
            XCTAssertTrue(WPKSceneGate.hasBoardDealingAnimation(input), file)
        }
        for file in ["card-confirm-audit/frames/0134.jpg", "card-confirm-audit/frames/0136.jpg",
                     "card-confirm-audit/frames/0213.jpg", "video-holdout/t022.png", "video-holdout/t065.png"] {
            let input = try localFixture(file)
            XCTAssertFalse(WPKSceneGate.hasBoardDealingAnimation(input), file)
        }
    }

    func testTenFPSFlopBacksBlockUntilFaceUpCardsReplaceThem() throws {
        var matches: [Int] = []
        for index in 1...20 {
            let file = String(format: "card-confirm-audit/flop-motion/%04d.jpg", index)
            if WPKSceneGate.hasBoardDealingAnimation(try localFixture(file)) { matches.append(index) }
        }
        XCTAssertEqual(matches, Array(4...9))
        // Frame 10 is nearly edge-on and has only two complete faces: card completeness
        // must still reject it. This color check does not replace the existing card gate.
    }

    func testSuppliedVideo240FramesDoNotBlockNormalCardFacesOrPlayerBacks() throws {
        var matches: [Int] = []
        for index in 1...240 {
            let file = String(format: "card-confirm-audit/frames/%04d.jpg", index)
            if WPKSceneGate.hasBoardDealingAnimation(try localFixture(file)) { matches.append(index) }
        }
        // Independently inspected: three flop back sequences, two flying turn cards,
        // and a new-hand deal. Remaining 234 include red suits and active opponents.
        XCTAssertEqual(matches, [39, 117, 135, 202, 212, 234])
    }
}
#endif
