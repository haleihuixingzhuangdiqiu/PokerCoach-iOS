import XCTest
@testable import PokerCoachCore

final class LiveDecisionGateTests: XCTestCase {
    private func observation(active: Bool, amount: String = "3.20") -> LiveDecisionObservation {
        let raw = ["pot": "9.50", "settled": "6.30", "call": amount, "stack": "52.83"]
        let facts = PublicBettingFacts(raw: raw, scores: raw.mapValues { _ in 1 }, callControlVisible: true)
        return .init(facts: facts, actions: .init(heroTurnConfirmed: active, foldAvailable: active, callAmount: facts.call))
    }
    func testUnconfirmedControlsImmediatelyWithdrawAnOtherwiseIdenticalAmount() {
        var gate = LiveDecisionGate()
        let active = observation(active: true), inactive = observation(active: false)
        gate.ingest(active, timestamp: 1, now: 1)
        XCTAssertNil(gate.current(now: 1))
        gate.ingest(active, timestamp: 1.3, now: 1.3)
        let generation = gate.generation
        XCTAssertEqual(gate.current(now: 1.3), active)
        gate.ingest(inactive, timestamp: 1.6, now: 1.6)
        XCTAssertNil(gate.current(now: 1.6))
        XCTAssertFalse(gate.accepts(active, generation: generation, now: 1.6))
    }
    func testChangedCostCannotKeepPreviousRecommendationAndNeedsTwoNewImages() {
        var gate = LiveDecisionGate()
        let old = observation(active: true), new = observation(active: true, amount: "4.20")
        gate.ingest(old, timestamp: 1, now: 1); gate.ingest(old, timestamp: 1.3, now: 1.3)
        gate.ingest(new, timestamp: 1.6, now: 1.6)
        XCTAssertNil(gate.current(now: 1.6))
        gate.ingest(new, timestamp: 1.6, now: 1.6)
        XCTAssertNil(gate.current(now: 1.6), "A duplicate callback is not another image")
        gate.ingest(new, timestamp: 1.9, now: 1.9)
        XCTAssertEqual(gate.current(now: 1.9), new)
    }
    func testExpiredAndFutureObservationsCannotAuthorizeAnAction() {
        var gate = LiveDecisionGate(); let value = observation(active: true)
        gate.ingest(value, timestamp: 1, now: 1); gate.ingest(value, timestamp: 1.3, now: 1.3)
        XCTAssertNil(gate.current(now: 2.11))
        gate.ingest(value, timestamp: 4, now: 3)
        XCTAssertNil(gate.current(now: 3))
        gate.ingest(value, timestamp: 3, now: 3)
        XCTAssertNil(gate.current(now: 3))
    }
}
