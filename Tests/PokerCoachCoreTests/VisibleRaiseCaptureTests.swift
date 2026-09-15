#if canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class VisibleRaiseCaptureTests: XCTestCase {
    private func fixture(_ path: String) throws -> CGImage {
        let root = PrivateTestFixtures.workRoot
        let file = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Local user fixture unavailable: \(path)") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testRealPrintedRaiseTargetsAndHeroContributionsExcludeGrayPreset() throws {
        let cases: [(String, String?, [String])] = [
            ("card-confirm-audit/frames/0018.jpg", "0.2", ["2.3", "2.7", "3.5", "4"]),
            ("card-confirm-audit/frames/0186.jpg", "1", ["21", "26", "30", "40", "46"]),
            ("video-holdout/t065.png", nil, ["7.4", "9.6", "12", "16", "18"]),
            ("rank-56-fixtures/train-5h4h-production.jpg", "1", ["7.4", "9.4", "11", "15", "18"]),
            ("rank-56-fixtures/holdout-as2c-4sts9d-production.jpg", nil, ["11", "14", "17", "23", "27"])
        ]
        let reader = WPKActionControlReader()
        for (path, wager, targets) in cases {
            let result = try reader.read(try fixture(path))
            XCTAssertTrue(result.heroTurnConfirmed, path + ": " + result.reason)
            XCTAssertEqual(result.heroWager?.amountText, wager, path)
            if wager == nil { XCTAssertTrue(result.heroWagerAreaClear, path) }
            else { XCTAssertGreaterThanOrEqual(result.heroWager?.confidence ?? 0, 0.90, path) }
            XCTAssertEqual(result.raiseCandidates.map(\.amountText), targets, path)
            XCTAssertTrue(result.raiseCandidates.allSatisfy { $0.meaning == .raiseTo && $0.confidence >= 0.90 })
        }
    }

    func testNumbersWithoutCurrentStreetChipMarkerDoNotInventHeroContribution() throws {
        let reader = WPKActionControlReader()
        let original = try fixture("card-confirm-audit/frames/0186.jpg")
        let masked = try covering(original, rect: CGRect(x: 446, y: 1158, width: 39, height: 39))
        let result = try reader.read(masked)
        XCTAssertEqual(result.callAmountText, "10.22")
        XCTAssertNil(result.heroWager)
        XCTAssertFalse(result.heroWagerAreaClear)
        XCTAssertTrue(result.raiseCandidates.isEmpty)
    }

    func testRaiseNeedsKnownContributionEnabledButtonAndConfirmedTotalAboveCall() {
        func visual(clear: Bool = false, marker: Bool = true) -> WPKActionVisualFeatures {
            WPKActionVisualFeatures(foldRed: true, middleBlue: true, rightBlue: true, rightGreen: false,
                                    presetCount: 4, presetEnabled: [false, true, true, true, true],
                                    heroWagerAreaClear: clear, heroWagerMarkerVisible: marker)
        }
        var raw = ["fold": "弃牌", "middle": "自由加注", "right": "0.8", "countdown": "6s", "hero.wager": "0.2",
                   "preset.0": "1.8", "preset.1": "2.3", "preset.2": "1", "preset.3": "3.5", "preset.4": "4", "preset.4.label": "1.2"]
        var scores = raw.mapValues { _ in Float(1) }
        var result = WPKActionControlPolicy.evaluate(features: visual(), raw: raw, confidence: scores)
        XCTAssertEqual(result.raiseCandidates.map(\.amountText), ["2.3", "3.5", "4"])
        // Actual All-in label replaces the last ratio: its unvalidated amount convention is excluded.
        raw["preset.4.label"] = "All-in"
        result = WPKActionControlPolicy.evaluate(features: visual(), raw: raw, confidence: scores)
        XCTAssertEqual(result.raiseCandidates.map(\.amountText), ["2.3", "3.5"])
        scores["hero.wager"] = 0.89
        XCTAssertTrue(WPKActionControlPolicy.evaluate(features: visual(), raw: raw, confidence: scores).raiseCandidates.isEmpty)
        scores["hero.wager"] = 1
        for invalid in ["0", "0.222", "-1", "O.2"] {
            raw["hero.wager"] = invalid
            let unknown = WPKActionControlPolicy.evaluate(features: visual(), raw: raw, confidence: scores)
            XCTAssertNil(unknown.heroWager); XCTAssertTrue(unknown.raiseCandidates.isEmpty)
        }
    }

    func testOldActionEvidenceDecodesUnknownContribution() throws {
        let legacy = Data(#"{"heroTurnConfirmed":true,"canFold":true,"canCheck":false,"callAmountText":"3.2","callConfidence":1,"raiseCandidates":[],"visibleBetAmounts":[],"heroWagerAreaClear":false,"reason":"旧样本","rightText":"3.2","rightConfidence":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WPKActionControlEvidence.self, from: legacy).heroWager)
    }

    func testAllInWarningMeansPlayerBadgeNotAvailableAllInButton() throws {
        let reader = WPKPublicStateReader()
        let facingAllIn = try reader.read(try fixture("card-confirm-audit/frames/0186.jpg"))
        XCTAssertEqual(facingAllIn.raw["hero.wager"], "1")
        XCTAssertEqual(facingAllIn.raw["allin.visible"], "true")
        XCTAssertEqual(facingAllIn.raw["allin.seats"], "0")
        XCTAssertGreaterThanOrEqual(facingAllIn.scores["allin.visible"] ?? 0, 0.90)
        let withAllInButton = try fixture("card-confirm-audit/frames/0203.jpg")
        let playerBadgeCovered = try covering(withAllInButton, rect: CGRect(x: 310, y: 202, width: 90, height: 53))
        let onlyButton = try reader.read(playerBadgeCovered)
        XCTAssertNil(onlyButton.raw["allin.visible"], "A selectable All-in control does not mean an opponent is already all-in")
    }

    private func covering(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(red: 0.04, green: 0.12, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: rect.minX / 720 * CGFloat(image.width), y: (1 - rect.maxY / 1564) * CGFloat(image.height),
                            width: rect.width / 720 * CGFloat(image.width), height: rect.height / 1564 * CGFloat(image.height)))
        return try XCTUnwrap(context.makeImage())
    }
}
#endif
