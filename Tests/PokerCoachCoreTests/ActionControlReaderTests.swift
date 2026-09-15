#if canImport(Vision)
import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class ActionControlReaderTests: XCTestCase {
    private func newFixture(_ file: String) throws -> CGImage {
        let root = PrivateTestFixtures.workRoot
        let path = root.appendingPathComponent("rank-56-fixtures/\(file).jpg")
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Local user screenshot unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testNewSixSecondScreensGiveActualCallAmountsAtAllSuppliedResolutions() throws {
        let reader = WPKActionControlReader()
        for suffix in ["", "-production", "-664x1440"] {
            for (file, expected) in [("train-5h4h", "2.5"), ("holdout-as2c-4sts9d", "4.6")] {
                let result = try reader.read(try newFixture(file + suffix))
                XCTAssertTrue(result.heroTurnConfirmed, file + suffix + ": " + result.reason)
                XCTAssertTrue(result.canFold)
                XCTAssertEqual(result.callAmountText, expected, file + suffix)
                XCTAssertGreaterThanOrEqual(result.callConfidence, 0.90)
                XCTAssertFalse(result.canCheck)
            }
            let settlementImage = try newFixture("settlement-jd7c-5d4c6d" + suffix)
            XCTAssertFalse(try reader.read(settlementImage).heroTurnConfirmed)
        }
    }

    func testLegibleCallStillNeedsOwnTimerAndUnreadableAmountIsNeverInferred() throws {
        let reader = WPKActionControlReader()
        let original = try newFixture("holdout-as2c-4sts9d-production")
        XCTAssertEqual(try reader.read(original).callAmountText, "4.6")
        let noTimer = try masking(original, rects: [CGRect(x: 145, y: 1170, width: 92, height: 62),
                                                    CGRect(x: 480, y: 1170, width: 104, height: 62)],
                                  color: CGColor(red: 0.04, green: 0.12, blue: 0.22, alpha: 1))
        let noTimerResult = try reader.read(noTimer)
        XCTAssertFalse(noTimerResult.heroTurnConfirmed)
        XCTAssertNil(noTimerResult.callAmountText)
        let noAmount = try masking(original, rects: [CGRect(x: 496, y: 1242, width: 73, height: 44)],
                                   color: CGColor(red: 0.10, green: 0.65, blue: 0.95, alpha: 1))
        let noAmountResult = try reader.read(noAmount)
        XCTAssertFalse(noAmountResult.heroTurnConfirmed)
        XCTAssertNil(noAmountResult.callAmountText)
        // Reusing the same reader cannot carry the masked result or a prior amount forward.
        XCTAssertEqual(try reader.read(original).callAmountText, "4.6")
    }

    private func masking(_ image: CGImage, rects: [CGRect], color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(color)
        for rect in rects {
            context.fill(CGRect(x: rect.minX / 720 * CGFloat(image.width),
                                y: (1 - rect.maxY / 1564) * CGFloat(image.height),
                                width: rect.width / 720 * CGFloat(image.width), height: rect.height / 1564 * CGFloat(image.height)))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private let callVisual = WPKActionVisualFeatures(foldRed: true, middleBlue: true, rightBlue: true, rightGreen: false, presetCount: 5)
    private let checkVisual = WPKActionVisualFeatures(foldRed: true, middleBlue: true, rightBlue: false, rightGreen: true, presetCount: 5)
    private let scores: [String: Float] = ["fold": 1, "middle": 1, "right": 1, "countdown": 1]
    private func words(_ right: String) -> [String: String] { ["fold": "弃牌", "middle": "自由加注", "right": right, "countdown": "9s"] }

    func testCallAndCheckNeedBothEnabledGroupAndCorrectLabels() {
        let call = WPKActionControlPolicy.evaluate(features: callVisual, raw: words("3.2"), confidence: scores)
        XCTAssertTrue(call.heroTurnConfirmed); XCTAssertTrue(call.canFold); XCTAssertFalse(call.canCheck)
        XCTAssertEqual(call.callAmountText, "3.2"); XCTAssertTrue(call.raiseCandidates.isEmpty)
        let check = WPKActionControlPolicy.evaluate(features: checkVisual, raw: words("让牌"), confidence: scores)
        XCTAssertTrue(check.heroTurnConfirmed); XCTAssertTrue(check.canCheck); XCTAssertNil(check.callAmountText)
        XCTAssertFalse(WPKActionControlPolicy.evaluate(features: callVisual, raw: words("让牌"), confidence: scores).heroTurnConfirmed)
        XCTAssertFalse(WPKActionControlPolicy.evaluate(features: checkVisual, raw: words("3.2"), confidence: scores).heroTurnConfirmed)
    }
    func testPreselectionGrayButtonNoOwnTimerAndOCRAmbiguityAreRejected() {
        let gray = WPKActionVisualFeatures(foldRed: true, middleBlue: false, rightBlue: false, rightGreen: false, presetCount: 0)
        XCTAssertFalse(WPKActionControlPolicy.evaluate(features: gray, raw: words("让牌"), confidence: scores).heroTurnConfirmed)
        var raw = words("3.2"); raw["fold"] = "快速弃牌"
        XCTAssertFalse(WPKActionControlPolicy.evaluate(features: callVisual, raw: raw, confidence: scores).heroTurnConfirmed)
        raw = words("3.2"); raw["countdown"] = ""
        XCTAssertFalse(WPKActionControlPolicy.evaluate(features: callVisual, raw: raw, confidence: scores).heroTurnConfirmed)
        for amount in ["0", "O.2", "1/3", "3..2", "3.222", "跟注3.2", "-1"] {
            XCTAssertFalse(WPKActionControlPolicy.evaluate(features: callVisual, raw: words(amount), confidence: scores).heroTurnConfirmed, amount)
        }
        var weak = scores; weak["right"] = 0.89
        XCTAssertFalse(WPKActionControlPolicy.evaluate(features: callVisual, raw: words("3.2"), confidence: weak).heroTurnConfirmed)
    }
    func testLegacyPublicEvidenceDecodesWithNoConfirmedActions() throws {
        let data = Data(#"{"raw":{"call":"3.2"},"scores":{"call":1},"callControlVisible":true}"#.utf8)
        let evidence = try JSONDecoder().decode(PublicStateEvidence.self, from: data)
        XCTAssertFalse(evidence.actionControls.heroTurnConfirmed)
        XCTAssertEqual(evidence.actionControls, .unconfirmed)
    }
    func testFieldCacheRequiresExactSamePixelsAndExpiresWithoutExtendingOnHit() {
        let cache = WPKExactFieldCache(), pixels = Data([1, 2, 3])
        cache.store("pot", pixels: pixels, text: "3.5", confidence: 1, now: 1)
        XCTAssertEqual(cache.lookup("pot", pixels: pixels, now: 1.5)?.text, "3.5")
        XCTAssertNil(cache.lookup("stack", pixels: pixels, now: 1.5))
        XCTAssertNil(cache.lookup("pot", pixels: Data([1, 2, 4]), now: 1.5))
        XCTAssertNil(cache.lookup("pot", pixels: pixels, now: 1.76))
        XCTAssertNil(cache.lookup("pot", pixels: pixels, now: 0.9))
    }
    func testOpeningBetCandidatesUseOnlyEnabledPrintedAmountsAndClearHeroWagerArea() {
        let visual = WPKActionVisualFeatures(foldRed: true, middleBlue: true, rightBlue: false, rightGreen: true,
                                             presetCount: 5, presetEnabled: [true, true, true, false, true], heroWagerAreaClear: true)
        var raw = words("让牌"), confidence = scores
        for (index, amount) in ["1.2", "1.8", "2/3", "3.5", "4.2"].enumerated() {
            raw["preset.\(index)"] = amount; confidence["preset.\(index)"] = index == 4 ? 0.8 : 1
        }
        let result = WPKActionControlPolicy.evaluate(features: visual, raw: raw, confidence: confidence)
        XCTAssertEqual(result.raiseCandidates.map(\.amountText), ["1.2", "1.8"])
        XCTAssertTrue(result.raiseCandidates.allSatisfy { $0.meaning == .bet })
        let markerVisible = WPKActionVisualFeatures(foldRed: true, middleBlue: true, rightBlue: false, rightGreen: true,
                                                    presetCount: 5, presetEnabled: [true, true, true, true, true], heroWagerAreaClear: false)
        XCTAssertTrue(WPKActionControlPolicy.evaluate(features: markerVisible, raw: raw, confidence: confidence).raiseCandidates.isEmpty)
        raw["right"] = "3.2"
        XCTAssertTrue(WPKActionControlPolicy.evaluate(features: callVisual, raw: raw, confidence: confidence).raiseCandidates.isEmpty)
    }
    func testSuppliedVideoHasPositiveAndNegativeOwnTurnControls() throws {
        let root = PrivateTestFixtures.workRoot
        let paths: [(String, String?)] = [("video-holdout/t022.png", "check"), ("video-holdout/t065.png", "3.2"),
                                         ("video-holdout/t012.png", nil), ("video-holdout/t058.png", nil),
                                         ("video-hd/t20.png", nil), ("video-hd/t105.png", nil),
                                         ("card-confirm-audit/frames/0151.jpg", nil),
                                         ("card-confirm-audit/frames/0184.jpg", nil),
                                         ("card-confirm-audit/frames/0186.jpg", "10.22"),
                                         ("card-confirm-audit/frames/0045.jpg", "check"),
                                         ("card-confirm-audit/frames/0046.jpg", "check"),
                                         ("card-confirm-audit/frames/0049.jpg", nil)]
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(paths[0].0).path) else { throw XCTSkip("User-provided local video fixtures are not bundled") }
        let reader = WPKActionControlReader()
        for (path, expected) in paths {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let result = try reader.read(image)
            print("Action fixture \(path): turn=\(result.heroTurnConfirmed), check=\(result.canCheck), call=\(result.callAmountText ?? "nil"), right=\(result.rightText), reason=\(result.reason)")
            XCTAssertEqual(result.heroTurnConfirmed, expected != nil, path + ": " + result.reason)
            if expected == "check" {
                XCTAssertTrue(result.canCheck); XCTAssertTrue(result.canFold); XCTAssertTrue(result.heroWagerAreaClear)
                XCTAssertEqual(result.raiseCandidates.map(\.amountText), ["1.2", "1.8", "2.3", "3.5", "4.2"], path)
                XCTAssertTrue(result.raiseCandidates.allSatisfy { $0.meaning == .bet })
            }
            else if let expected { XCTAssertEqual(result.callAmountText, expected); XCTAssertTrue(result.canFold) }
            else { XCTAssertFalse(result.canCheck); XCTAssertFalse(result.canFold); XCTAssertNil(result.callAmountText) }
        }
    }
    func testUniqueOpponentStackFromSuppliedVideoUsesRemainingNonFoldedSeat() throws {
        let root = PrivateTestFixtures.workRoot
        let cases = [("video-holdout/t022.png", 5, "202.73"), ("video-holdout/t065.png", 4, "37.56")]
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(cases[0].0).path) else { throw XCTSkip("User video fixtures unavailable") }
        let reader = WPKPublicStateReader()
        for (path, seat, stack) in cases {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let result = try reader.read(image)
            XCTAssertEqual(result.activeOpponentSeat, seat)
            XCTAssertEqual(result.activeOpponentStackText, stack)
            XCTAssertEqual(result.raw["opponent.stack"], stack)
            XCTAssertEqual(result.raw["opponent.seat"], String(seat))
            XCTAssertGreaterThanOrEqual(result.activeOpponentStackConfidence, 0.9)
        }
    }
}
#endif
