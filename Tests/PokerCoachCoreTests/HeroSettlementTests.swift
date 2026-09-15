import XCTest
@testable import PokerCoachCapture
#if canImport(Vision)
import CoreGraphics
import CoreText
import ImageIO

final class HeroSettlementTests: XCTestCase {
    private var fixtureRoot: URL {
        PrivateTestFixtures.workRoot
    }
    private func localFixture(_ path: String) throws -> CGImage {
        let file = fixtureRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Local supplied-video fixture unavailable: \(path)") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testSuppliedWinScreenshotAndBothLiveScreensAtThreeResolutions() throws {
        for suffix in ["", "-production", "-664x1440"] {
            let settlement = try localFixture("rank-56-fixtures/settlement-jd7c-5d4c6d\(suffix).jpg")
            let preflop = try localFixture("rank-56-fixtures/train-5h4h\(suffix).jpg")
            let flop = try localFixture("rank-56-fixtures/holdout-as2c-4sts9d\(suffix).jpg")
            XCTAssertTrue(WPKSceneGate.hasHeroWinSettlement(settlement), suffix)
            XCTAssertFalse(WPKSceneGate.hasHeroWinSettlement(preflop), suffix)
            XCTAssertFalse(WPKSceneGate.hasHeroWinSettlement(flop), suffix)
        }
    }

    func testOldVideoOnlyClearHeroWinBannersConfirmSettlement() throws {
        var matches: [Int] = []
        for index in 1...240 {
            if WPKSceneGate.hasHeroWinSettlement(try localFixture(String(format: "card-confirm-audit/frames/%04d.jpg", index))) {
                matches.append(index)
            }
        }
        // Independently viewed: banners at 69...73 and 92...96. Frame 92's bright
        // flash hides the word and Vision reads only "Y", so it must remain unconfirmed.
        XCTAssertEqual(matches, [69, 70, 71, 72, 73, 93, 94, 95, 96])
    }

    func testGoldWordsMustBeTheExactWinBannerAndBlueActionRejectsIt() throws {
        XCTAssertTrue(WPKSceneGate.hasHeroWinSettlement(try banner("YOU WIN")))
        XCTAssertFalse(WPKSceneGate.hasHeroWinSettlement(try banner("YOU LOSE")))
        XCTAssertFalse(WPKSceneGate.hasHeroWinSettlement(try banner("YOU WIN", blueAction: true)))
        XCTAssertTrue(WPKSceneGate.hasHeroWinSettlement(try banner("YOU WIN", blueAvatar: true)))
    }

    private func banner(_ text: String, blueAction: Bool = false, blueAvatar: Bool = false) throws -> CGImage {
        let width = 720, height = 1564
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.03, green: 0.12, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 43, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.98, green: 0.83, blue: 0.17, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(string)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (Double(width) - lineWidth) / 2, y: Double(height) * (1 - 0.57) - 14)
        CTLineDraw(line, context)
        if blueAction || blueAvatar {
            context.setFillColor(CGColor(red: 0.05, green: 0.65, blue: 0.98, alpha: 1))
            context.fill(CGRect(x: 0.44 * Double(width), y: (1 - 0.795) * Double(height),
                                width: 0.12 * Double(width), height: 0.045 * Double(height)))
        }
        if blueAction {
            context.setFillColor(CGColor(red: 0.05, green: 0.65, blue: 0.98, alpha: 1))
            context.fill(CGRect(x: 0.71 * Double(width), y: (1 - 0.83) * Double(height),
                                width: 0.06 * Double(width), height: 0.03 * Double(height)))
            context.setFillColor(CGColor(red: 0.90, green: 0.10, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 0.22 * Double(width), y: (1 - 0.83) * Double(height),
                                width: 0.06 * Double(width), height: 0.03 * Double(height)))
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testIdenticalConcurrentROIsShareOneRecognitionButChangedPixelsDoNot() {
        let cache = WPKSettlementOCRCache(), calls = RecognitionCalls()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let result = cache.result(for: Data([1, 2, 3])) { calls.increment(); return true }
            XCTAssertTrue(result)
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(cache.result(for: Data([1, 2, 4])) { calls.increment(); return false })
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(cache.result(for: Data([1, 2, 4])) { calls.increment(); return true })
        XCTAssertEqual(calls.count, 2)
    }

    func testTransientRecognitionErrorIsRetriedOnIdenticalNextFrame() {
        let cache = WPKSettlementOCRCache(), key = Data([9, 2, 6])
        XCTAssertFalse(cache.result(for: key) { nil })
        XCTAssertTrue(cache.result(for: key) { true })
    }
}

private final class RecognitionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
#endif
