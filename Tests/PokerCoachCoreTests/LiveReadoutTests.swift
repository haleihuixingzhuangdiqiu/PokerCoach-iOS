import XCTest
@testable import PokerCoachCore
@testable import PokerCoachCapture
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class LiveReadoutTests: XCTestCase {
    private let flop: [String?] = ["Kh", "Qs", "7h", "Qd", "Ks", nil, nil]
    private func facts(pot: String = "9.5", settled: String = "6.3", call: String = "3.2", stack: String = "52.83",
                       blue: Bool = true, score: Float = 1, folds: Int = 6) -> PublicBettingFacts {
        var raw = ["pot": pot, "settled": settled, "call": call, "stack": stack]
        var scores = Dictionary(uniqueKeysWithValues: raw.keys.map { ($0, score) })
        for seat in 0..<folds { raw["seat.\(seat)"] = "弃牌"; scores["seat.\(seat)"] = 1 }
        return PublicBettingFacts(raw: raw, scores: scores, callControlVisible: blue)
    }
    func testRejectsMissingCardsDuplicateCardsAndBoardGaps() throws {
        XCTAssertEqual(try LiveCardPosition(slots: flop).handName, "两对")
        for slots: [String?] in [[nil, "Qs", nil, nil, nil, nil, nil], ["Kh", "Kh", nil, nil, nil, nil, nil],
                                 ["Kh", "Qs", "Kh", "Qd", "7s", nil, nil], ["Kh", "Qs", "7h", nil, "Ks", nil, nil],
                                 ["Kh", "Qs", "7h", "Qd", nil, nil, nil]] {
            XCTAssertThrowsError(try LiveCardPosition(slots: slots))
        }
    }
    func testActualVideoAmountsAndImmediatePotRatio() throws {
        let f = facts()
        XCTAssertEqual(f.pot, 950); XCTAssertEqual(f.call, 320); XCTAssertEqual(f.heroStack, 5283)
        XCTAssertEqual(try XCTUnwrap(f.callThreshold), 3.2 / 12.7, accuracy: 0.000001)
        XCTAssertEqual(f.maximumOpponents, 1)
    }
    func testNoNumericCallFromCheckControlOrUnconfirmedNumber() {
        XCTAssertNil(facts(blue: false).call)
        XCTAssertNil(facts(call: "让牌").call)
        XCTAssertNil(facts(score: 0.5).call)
        XCTAssertNil(facts(call: "3..2").call)
        XCTAssertNil(facts(stack: "").call)
    }
    func testInconsistentAmountsAndAllFoldedAreNotInvented() {
        XCTAssertNil(facts(pot: "3", settled: "6.3").pot)
        XCTAssertNil(facts(call: "10").call)
        XCTAssertNil(facts(stack: "1").call)
        XCTAssertEqual(facts(folds: 7).maximumOpponents, 0)
        XCTAssertEqual(facts(folds: 0).maximumOpponents, 7)
    }
    func testDistinctFreshOCRFramesRequiredAndChangedAmountWithdraws() {
        var gate = PublicFactsGate()
        gate.ingest(facts(), at: 1, now: 1.1)
        gate.ingest(facts(), at: 1, now: 1.2)
        XCTAssertNil(gate.confirmed)
        gate.ingest(facts(), at: 1.3, now: 1.4)
        XCTAssertNotNil(gate.confirmed)
        gate.ingest(facts(pot: "12"), at: 1.5, now: 1.6)
        XCTAssertNil(gate.confirmed)
        gate.ingest(facts(pot: "12"), at: 1.7, now: 1.8)
        XCTAssertNotNil(gate.current(now: 1.9))
        XCTAssertNil(gate.current(now: 2.6))
    }
    func testStaleAndFutureOCRCannotConfirm() {
        var gate = PublicFactsGate()
        gate.ingest(facts(), at: 1, now: 2)
        gate.ingest(facts(), at: 2, now: 1)
        gate.ingest(facts(), at: .nan, now: 3)
        XCTAssertNil(gate.confirmed)
    }
    func testCardChangeImmediatelyRejectsAnInFlightResult() throws {
        var gate = LiveCardGate()
        gate.ingest(slots: flop, timestamp: 1, now: 1.01)
        gate.ingest(slots: flop, timestamp: 1, now: 1.02)
        XCTAssertNil(gate.position)
        gate.ingest(slots: flop, timestamp: 1.1, now: 1.11)
        let position = try XCTUnwrap(gate.position), generation = gate.generation
        XCTAssertTrue(gate.accepts(generation: generation, position: position, now: 1.12))
        var turn = flop; turn[5] = "9d"
        gate.ingest(slots: turn, timestamp: 1.2, now: 1.21)
        XCTAssertNil(gate.position)
        XCTAssertFalse(gate.accepts(generation: generation, position: position, now: 1.22))
        gate.ingest(slots: turn, timestamp: 1.3, now: 1.31)
        XCTAssertEqual(gate.position?.board.count, 4)
    }
    func testStaleCardsCannotReappearWithOneFrameOrOldGeneration() throws {
        var gate = LiveCardGate()
        gate.ingest(slots: flop, timestamp: 1, now: 1)
        gate.ingest(slots: flop, timestamp: 1.1, now: 1.1)
        let position = try XCTUnwrap(gate.position), generation = gate.generation
        XCTAssertFalse(gate.accepts(generation: generation, position: position, now: 2))
        gate.ingest(slots: flop, timestamp: 3, now: 3)
        XCTAssertNil(gate.position)
        gate.ingest(slots: flop, timestamp: 3.1, now: 3.1)
        XCTAssertFalse(gate.accepts(generation: generation, position: position, now: 3.2))
        gate.expire(now: 4)
        XCTAssertNil(gate.slots)
    }
    func testRoyalFlushRemainsNutsAcrossPlayerScenarios() throws {
        let position = try LiveCardPosition(slots: ["Ah", "Kh", "Qh", "Jh", "Th", "2s", "3c"])
        let estimate = try LiveCardAnalyzer.analyze(position, maximumOpponents: 7, budget: .init(samples: 1000, milliseconds: 1000, exactOutcomeLimit: 0))
        XCTAssertEqual(estimate.headsUp.equity, 1)
        XCTAssertEqual(estimate.mostOpponents.equity, 1)
        XCTAssertGreaterThanOrEqual(estimate.mostOpponents.samples, 500)
    }
    func testSharedRoyalBoardUsesSplitPotEquityNotOutrightWinProbability() throws {
        let position = try LiveCardPosition(slots: ["2c", "3d", "Ah", "Kh", "Qh", "Jh", "Th"])
        let estimate = try LiveCardAnalyzer.analyze(position, maximumOpponents: 7, budget: .init(samples: 1000, milliseconds: 1000, exactOutcomeLimit: 0))
        XCTAssertEqual(estimate.headsUp.equity, 0.5)
        XCTAssertEqual(estimate.mostOpponents.equity, 0.125)
        XCTAssertEqual(estimate.headsUp.outrightWinProbability, 0)
        XCTAssertEqual(estimate.percentLabel, "约12–50%")
    }
    #if canImport(Vision)
    func testVisibleUnreadableCardIsDifferentFromAnEmptySlot() throws {
        let reader = try FourColorCardReader.wpkVideoProfile()
        let region = ScreenRegion(id: "board.3", x: 0, y: 0, width: 1, height: 1)
        for (gray, expectedUnresolved) in [(CGFloat(1), true), (CGFloat(0.1), false)] {
            let c = try XCTUnwrap(CGContext(data: nil, width: 100, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            c.setFillColor(gray: gray, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
            let image = try XCTUnwrap(c.makeImage()), evidence = try XCTUnwrap(reader.read(image, regions: [region]).first)
            XCTAssertNil(evidence.card)
            XCTAssertEqual(evidence.hasUnresolvedCard, expectedUnresolved)
        }
    }
    #endif
}
