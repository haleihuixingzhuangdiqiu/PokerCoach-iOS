import XCTest
@testable import PokerCoachCore
@testable import PokerCoachCapture

final class ScanTests: XCTestCase {
    func testLocalChangeAndSlowDrift() {
        var detector = RegionChangeDetector()
        XCTAssertEqual(detector.inspect([RegionDigest(id: "pot", pixels: [UInt8](repeating: 0, count: 20))], sequence: 1, capturedAt: 1).count, 1)
        XCTAssertEqual(detector.inspect([RegionDigest(id: "pot", pixels: [UInt8](repeating: 5, count: 20))], sequence: 2, capturedAt: 2).count, 0)
        XCTAssertEqual(detector.inspect([RegionDigest(id: "pot", pixels: [UInt8](repeating: 20, count: 20))], sequence: 3, capturedAt: 3).count, 1)
    }
    func testTransitionOverflowMarksHistoryGap() {
        var q = CriticalTransitionQueue<Int>(capacity: 2)
        q.append(1); q.append(2); XCTAssertFalse(q.historyGap)
        q.append(3); XCTAssertTrue(q.historyGap); XCTAssertEqual(q.take(), 2); XCTAssertEqual(q.take(), 3)
        q.resetAtNewHand(); XCTAssertFalse(q.historyGap)
    }
    func testChipDecimalsAndAmbiguousOCR() throws {
        XCTAssertEqual(try ChipAmountParser.parse("53.93"), 5393)
        XCTAssertEqual(try ChipAmountParser.parse("1.5K", unitScale: 1), 1500)
        XCTAssertEqual(try ChipAmountParser.parse("1,250.50"), 125050)
        for bad in ["12,34", "O.5", "1..2", "0.001", "NaN", "-1", "1 2"] { XCTAssertThrowsError(try ChipAmountParser.parse(bad), bad) }
    }
    func testFramePacketRejectsMalformedAndFrameAdmissionDropsOldFrames() {
        let packet = FramePacketHeader(payloadSize: 100, capturedAt: 10).data
        XCTAssertEqual(FramePacketHeader(data: packet)?.payloadSize, 100)
        XCTAssertNil(FramePacketHeader(data: packet.dropLast()))
        XCTAssertNil(FramePacketHeader(data: FramePacketHeader(payloadSize: 100, capturedAt: .nan).data))
        var admission = FrameAdmission<Int>()
        let generation = admission.offer(1, capturedAt: 10)!
        XCTAssertNil(admission.offer(2, capturedAt: 10.01))
        guard case .frame(let latest) = admission.next(generation: generation, at: 10.02) else { return XCTFail("No frame") }
        XCTAssertEqual(latest.payload, 2)
        admission.setActive(false)
        guard case .idle = admission.next(generation: generation, at: 10.03) else { return XCTFail("Stale generation resumed") }
    }
}
