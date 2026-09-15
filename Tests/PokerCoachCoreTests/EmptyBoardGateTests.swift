import XCTest
@testable import PokerCoachCore

final class EmptyBoardGateTests: XCTestCase {
    func testTwoFreshEmptyFramesAndImmediateWithdrawalOnPartialCard() {
        var gate = EmptyBoardGate()
        gate.ingest(verifiedEmpty: true, timestamp: 1, now: 1)
        gate.ingest(verifiedEmpty: true, timestamp: 1, now: 1.1)
        XCTAssertFalse(gate.confirmed(now: 1.1))
        gate.ingest(verifiedEmpty: true, timestamp: 1.2, now: 1.2)
        XCTAssertTrue(gate.confirmed(now: 1.2))
        gate.ingest(verifiedEmpty: false, timestamp: 1.3, now: 1.3)
        XCTAssertFalse(gate.confirmed(now: 1.3))
        gate.ingest(verifiedEmpty: true, timestamp: 1.4, now: 1.4)
        XCTAssertFalse(gate.confirmed(now: 1.4))
        gate.ingest(verifiedEmpty: true, timestamp: 1.5, now: 1.5)
        XCTAssertTrue(gate.confirmed(now: 1.5))
        XCTAssertFalse(gate.confirmed(now: 2.4))
        gate.ingest(verifiedEmpty: true, timestamp: 2.5, now: 2.5)
        XCTAssertFalse(gate.confirmed(now: 2.5))
    }
    func testMissingEvidenceFutureAndStaleFramesCannotConfirm() {
        var gate = EmptyBoardGate()
        for t in [1.0, 1.1, 1.2] { gate.ingest(verifiedEmpty: false, timestamp: t, now: t) }
        XCTAssertFalse(gate.confirmed(now: 1.2))
        gate.ingest(verifiedEmpty: true, timestamp: 4, now: 3)
        gate.ingest(verifiedEmpty: true, timestamp: 2, now: 3)
        XCTAssertFalse(gate.confirmed(now: 3))
    }
}
