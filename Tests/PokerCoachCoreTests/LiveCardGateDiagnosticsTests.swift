import XCTest
@testable import PokerCoachCore

final class LiveCardGateDiagnosticsTests: XCTestCase {
    func testDuplicateReadCannotHideAsConfirmationAndRecoversWithTwoFreshFrames() throws {
        var gate = LiveCardGate()
        let duplicate: [String?] = ["As", "2c", "As", "Ts", "9d", nil, nil]
        gate.ingest(slots: duplicate, timestamp: 1, now: 1)
        XCTAssertNil(gate.validationIssue)
        gate.ingest(slots: duplicate, timestamp: 1.1, now: 1.1)
        XCTAssertNil(gate.position)
        XCTAssertEqual(gate.validationIssue, "发现重复牌")
        let corrected: [String?] = ["As", "2c", "4s", "Ts", "9d", nil, nil]
        gate.ingest(slots: corrected, timestamp: 1.2, now: 1.2)
        XCTAssertNil(gate.validationIssue)
        XCTAssertNil(gate.position)
        gate.ingest(slots: corrected, timestamp: 1.3, now: 1.3)
        XCTAssertEqual(try XCTUnwrap(gate.position).board.map(\.description), ["4s", "Ts", "9d"])
        gate.expire(now: 2.2)
        XCTAssertNil(gate.validationIssue)
        XCTAssertNil(gate.position)
    }

    func testPartialFlopExplainsMissingCardsAndNeverBecomesPreflopEstimate() {
        var gate = LiveCardGate()
        let partial: [String?] = ["As", "2c", "4s", nil, "9d", nil, nil]
        gate.ingest(slots: partial, timestamp: 1, now: 1)
        gate.ingest(slots: partial, timestamp: 1.1, now: 1.1)
        XCTAssertEqual(gate.validationIssue, "公共牌尚未读全")
        XCTAssertNil(gate.position)
        gate.reset()
        XCTAssertNil(gate.validationIssue)
    }
}
