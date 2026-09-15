#if canImport(Vision)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import PokerCoachCapture

final class CardReaderFallbackTests: XCTestCase {
    private func reading(_ value: String, confidence: Float = 0.99, alternate: String? = nil,
                         alternateConfidence: Float = 0, count: Int = 1) -> RankOCRReading {
        RankOCRReading(raw: value, confidence: confidence, alternate: alternate,
                       alternateConfidence: alternateConfidence, observationCount: count)
    }
    func testRankPolicyRequiresHighConfidenceAgreementWithoutOCRSubstitutions() {
        XCTAssertEqual(RankOCRPolicy.agree(reading("10"), reading("T")).rank, "T")
        XCTAssertEqual(RankOCRPolicy.agree(reading("A"), reading("A")).rank, "A")
        for value in ["O", "I", "B", "S", "5K", "1 0", "11", "0", ""] {
            XCTAssertNil(RankOCRPolicy.agree(reading(value), reading(value)).rank, value)
        }
        XCTAssertNil(RankOCRPolicy.agree(reading("5"), reading("6")).rank)
        XCTAssertNil(RankOCRPolicy.agree(reading("5", confidence: 0.89), reading("5")).rank)
        XCTAssertNil(RankOCRPolicy.agree(reading("5", count: 2), reading("5")).rank)
        XCTAssertNil(RankOCRPolicy.agree(reading("5", alternate: "6", alternateConfidence: 0.85), reading("5")).rank)
        XCTAssertNil(RankOCRPolicy.agree(reading("Q", alternate: "O", alternateConfidence: 0.95), reading("Q")).rank)
        XCTAssertNil(RankOCRPolicy.agree(reading("6"), reading("6")).rank)
        XCTAssertNil(RankOCRPolicy.agree(reading("9"), reading("9")).rank)
    }

    func testExactPixelCacheDeduplicatesAndExpiresWithoutReusingChangedGlyph() {
        let cache = RankOCRCache(), first = Data([10, 20, 30]), changed = Data([10, 21, 30])
        guard case .start = cache.begin(first, now: 1) else { return XCTFail("First image must be verified") }
        guard case .pending = cache.begin(first, now: 1.1) else { return XCTFail("Second worker must not duplicate in-flight OCR") }
        let result = RankOCRPolicy.agree(reading("5"), reading("5"))
        cache.finish(first, result: result, now: 1.2)
        guard case let .cached(hit) = cache.begin(first, now: 1.3) else { return XCTFail("Identical source bytes should reuse verification") }
        XCTAssertEqual(hit.rank, "5")
        guard case .start = cache.begin(changed, now: 1.3) else { return XCTFail("Changed pixel must invalidate cache") }
        guard case .start = cache.begin(first, now: 4.3) else { return XCTFail("Positive cache must expire") }
    }

    func testNegativeCacheExpiresQuicklyAndCannotBecomeAccepted() {
        let cache = RankOCRCache(), key = Data([1, 2, 3])
        _ = cache.begin(key, now: 1)
        cache.finish(key, result: .rejected("OCR置信不足"), now: 1)
        guard case let .cached(hit) = cache.begin(key, now: 1.3) else { return XCTFail("Avoid repeating failed OCR at 15 Hz") }
        XCTAssertNil(hit.rank)
        guard case .start = cache.begin(key, now: 1.36) else { return XCTFail("A failed result must be reconsidered soon") }
    }

    func testTemplateDiagnosticsDoNotRelaxExistingDistanceAndMargin() {
        let zero = [UInt8](repeating: 0, count: 768)
        let full = [UInt8](repeating: 255, count: 768)
        let templates = [RankTemplate(rank: "2", pixels: zero, source: "synthetic threshold test"),
                         RankTemplate(rank: "3", pixels: full, source: "synthetic threshold test")]
        XCTAssertEqual(RankShape.match(zero, templates: templates)?.rank, "2")
        var middle = zero
        for i in 0..<384 { middle[i] = 255 }
        XCTAssertNotNil(RankShape.nearest(middle, templates: templates))
        XCTAssertNil(RankShape.match(middle, templates: templates))
    }

    func testRealVisionFallbackRecoversSyntheticAAndFiveAndKeepsUncertainSixUnresolved() throws {
        let reader = FourColorCardReader(templates: [
            RankTemplate(rank: "2", pixels: [UInt8](repeating: 0, count: 768), source: "deliberately nonmatching test template"),
            RankTemplate(rank: "3", pixels: [UInt8](repeating: 255, count: 768), source: "deliberately nonmatching test template")
        ])
        for rank in ["A", "5", "6"] {
            let image = try syntheticCard(rank: rank)
            let card = try XCTUnwrap(reader.read(image, regions: [.init(id: "synthetic", x: 0, y: 0, width: 1, height: 1)]).first)
            print("Synthetic missing rank \(rank): card=\(card.card ?? "nil"), raw=\(card.rawRank), confidence=\(card.rankConfidence), reason=\(card.reason)")
            if rank == "6", card.card == nil {
                // This system Vision version finds no text for this synthetic six. No threshold reduction or invented template.
                XCTAssertTrue(card.hasUnresolvedCard)
                XCTAssertTrue(card.reason.hasPrefix("点数复核未通过："))
            } else {
                XCTAssertEqual(card.card, rank + "c")
                XCTAssertFalse(card.hasUnresolvedCard)
                XCTAssertEqual(card.reason, "OCR双图一致，仍需跨帧确认")
            }
        }
    }

    func testWhiteBlankAndUnknownGlyphStayUnresolved() throws {
        let reader = FourColorCardReader()
        for rank in ["", "Z"] {
            let card = try XCTUnwrap(reader.read(syntheticCard(rank: rank), regions: [.init(id: "synthetic", x: 0, y: 0, width: 1, height: 1)]).first)
            XCTAssertNil(card.card)
            XCTAssertTrue(card.hasUnresolvedCard)
        }
    }

    /// Generated mechanics fixture only: this font is not claimed to be the missing WPK video glyphs.
    private func syntheticCard(rank: String) throws -> CGImage {
        let width = 100, height = 150
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let green = CGColor(red: 0.02, green: 0.45, blue: 0.22, alpha: 1)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let string = NSAttributedString(string: rank, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): green
        ])
        context.textPosition = CGPoint(x: 7, y: 99)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.setFillColor(green)
        context.fillEllipse(in: CGRect(x: 24, y: 18, width: 48, height: 43))
        let image = try XCTUnwrap(context.makeImage())
        if let path = ProcessInfo.processInfo.environment["POKER_READER_ARTIFACT_DIR"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("synthetic-" + (rank.isEmpty ? "blank" : rank) + ".png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return image
    }
}
#endif
