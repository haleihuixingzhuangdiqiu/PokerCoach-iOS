#if canImport(Vision)
import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Vision
import CryptoKit
@testable import PokerCoachCapture

final class RankGlyphIsolationTests: XCTestCase {
    private func load(_ url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local supplied image unavailable: \(url.lastPathComponent)") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testAll240FramesKeepLegacyExtractBytesUnchanged() throws {
        let root = PrivateTestFixtures.workRoot
            .appendingPathComponent("card-confirm-audit/frames")
        var hash = SHA256(), extracted = 0
        for index in 1...240 {
            let image = try load(root.appendingPathComponent(String(format: "%04d.jpg", index)))
            for region in WPKVideoLayout.cardRegions {
                if let crop = region.crop(image), let shape = RankShape.extract(crop) {
                    hash.update(data: Data([1])); hash.update(data: Data(shape)); extracted += 1
                } else { hash.update(data: Data([0])) }
            }
        }
        // Recorded from the pre-refactor RankTemplates.swift binary, covering every
        // non-nil shape and nil slot in order, including motion, panels and empty slots.
        XCTAssertEqual(extracted, 777)
        XCTAssertEqual(hash.finalize().map { String(format: "%02x", $0) }.joined(),
                       "a84b9cc355e98e898735077088c9b4a330de5953b2097194cb0fc404426eda19")
    }

    func testNativeIsolatedRealClubAndSpadeAcePassBothExistingOCRViews() throws {
        let screenshots = [
            ("codex-clipboard-e6d17b4c-8c3f-4442-aa5f-ddcf00947492.png", "hero.0"),
            ("codex-clipboard-19a57175-316e-4121-90d0-2a295ad05fc7.png", "board.0")
        ]
        for (file, slot) in screenshots {
            let url = PrivateTestFixtures.screenshotRoot.appendingPathComponent(file)
            let image = try load(url)
            let region = try XCTUnwrap(WPKVideoLayout.cardRegions.first { $0.id == slot })
            let card = try XCTUnwrap(region.crop(image))
            let glyph = try XCTUnwrap(RankShape.isolatedGlyph(card))
            // No rotation or square stretching: the upright glyph retains its source aspect ratio.
            XCTAssertGreaterThan(glyph.height, glyph.width)
            let color = try read(glyph, grayscale: false), gray = try read(glyph, grayscale: true)
            XCTAssertEqual(RankOCRPolicy.agree(color, gray).rank, "A", file)
        }
    }

    func testEmptyFaceAndBoundaryOnlyInkDoNotProduceAnIsolatedGlyph() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 150, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        XCTAssertNil(RankShape.isolatedGlyph(try XCTUnwrap(context.makeImage())))
        context.setFillColor(CGColor(red: 0.01, green: 0.10, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 150))
        XCTAssertNil(RankShape.isolatedGlyph(try XCTUnwrap(context.makeImage())))
    }

    func testHighScoreSixAndNineStillRequireTemplatesAfterIsolation() {
        for rank in ["6", "9"] {
            let reading = RankOCRReading(raw: rank, confidence: 1, alternate: nil,
                                         alternateConfidence: 0, observationCount: 1)
            XCTAssertNil(RankOCRPolicy.agree(reading, reading).rank)
        }
    }

    private func read(_ glyph: CGImage, grayscale: Bool) throws -> RankOCRReading {
        let scale = grayscale ? 4 : 3, border = 20
        let width = glyph.width * scale + border * 2, height = glyph.height * scale + border * 2
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(glyph, in: CGRect(x: border, y: border, width: glyph.width * scale, height: glyph.height * scale))
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
        request.customWords = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(context.makeImage())).perform([request])
        let observations = request.results ?? [], candidates = observations.first?.topCandidates(2) ?? []
        return RankOCRReading(raw: candidates.first?.string ?? "", confidence: candidates.first?.confidence ?? 0,
                              alternate: candidates.count > 1 ? candidates[1].string : nil,
                              alternateConfidence: candidates.count > 1 ? candidates[1].confidence : 0,
                              observationCount: observations.count)
    }
}
#endif
