import XCTest
@testable import PokerCoachCore

final class CaptureActivityMonitorTests: XCTestCase {
    func testTransientFalseKeepsOnlyNeutralWindowAndRecoversWithNewFrames() {
        var gate = CaptureActivityMonitor()
        XCTAssertEqual(gate.system(true, now: 1), .started)
        XCTAssertEqual(gate.system(false, now: 2), .suspended)
        XCTAssertTrue(gate.isReconciling)
        XCTAssertEqual(gate.frame(capturedAt: 2.05, now: 2.06), .none)
        XCTAssertEqual(gate.frame(capturedAt: 2.3, now: 2.31), .resumed)
        XCTAssertTrue(gate.usingFrameEvidence)
        XCTAssertEqual(gate.system(false, now: 2.4), .none)
        XCTAssertEqual(gate.frame(capturedAt: 2.7, now: 2.71), .none)
        XCTAssertEqual(gate.tick(now: 3.4), .none)
        XCTAssertEqual(gate.tick(now: 3.6), .stopped)
    }
    func testActualStopOldFramesAndSingleTailCannotKeepWindowAlive() {
        for tail in [false, true] {
            var gate = CaptureActivityMonitor()
            _ = gate.system(true, now: 1); _ = gate.system(false, now: 2)
            XCTAssertEqual(gate.frame(capturedAt: 1.99, now: 2.1), .none)
            if tail { XCTAssertEqual(gate.frame(capturedAt: 2.1, now: 2.11), .none) }
            XCTAssertEqual(gate.tick(now: 2.81), .stopped)
            XCTAssertEqual(gate.frame(capturedAt: 3, now: 3.01), .none)
            XCTAssertFalse(gate.isActive)
        }
    }
    func testDuplicatesFutureFramesAndQuickTailPairCannotResume() {
        var gate = CaptureActivityMonitor()
        _ = gate.system(true, now: 1); _ = gate.system(false, now: 2)
        _ = gate.frame(capturedAt: 2.05, now: 2.06)
        XCTAssertEqual(gate.frame(capturedAt: 2.05, now: 2.4), .none)
        XCTAssertEqual(gate.frame(capturedAt: 2.5, now: 2.4), .none)
        XCTAssertEqual(gate.frame(capturedAt: 2.1, now: 2.4), .none)
        XCTAssertEqual(gate.tick(now: 2.81), .stopped)
        XCTAssertEqual(gate.system(true, now: 3), .started)
    }
}

final class CaptureResumeAuditTests: XCTestCase {
    private func resumedMonitor() -> CaptureActivityMonitor {
        var gate = CaptureActivityMonitor()
        XCTAssertEqual(gate.system(true, now: 1), .started)
        XCTAssertEqual(gate.system(false, now: 2), .suspended)
        XCTAssertEqual(gate.frame(capturedAt: 2.05, now: 2.06), .none)
        XCTAssertEqual(gate.frame(capturedAt: 2.3, now: 2.31), .resumed)
        return gate
    }
    func testLateNewFrameCannotReviveSessionWhenTimerDidNotRun() {
        var gate = resumedMonitor()
        XCTAssertEqual(gate.frame(capturedAt: 3.2, now: 3.21), .stopped)
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(gate.tick(now: 3.22), .none)
        XCTAssertEqual(gate.frame(capturedAt: 3.4, now: 3.41), .none)
    }
    func testFrameAtReconciliationDeadlineStopsEvenWithoutTimer() {
        var gate = CaptureActivityMonitor()
        _ = gate.system(true, now: 1); _ = gate.system(false, now: 2)
        _ = gate.frame(capturedAt: 2.05, now: 2.06)
        XCTAssertEqual(gate.frame(capturedAt: 2.9, now: 2.91), .stopped)
        XCTAssertFalse(gate.isActive)
    }
    func testSuspensionRejectsQueuedWorkerGenerationAndDelayedRawFrame() {
        var clock = CaptureSessionClock()
        _ = clock.setActive(true, now: 1)
        let oldWorkerGeneration = clock.generation
        // Mirrors CoachModel.applyCaptureEvent(.suspended).
        clock.invalidatePendingFrames(at: 2)
        let gate = resumedMonitor()
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.isReconciling)
        XCTAssertTrue(clock.isCapturing)
        XCTAssertNotEqual(clock.generation, oldWorkerGeneration)
        // A callback queued before suspension cannot return after resumption.
        XCTAssertFalse(clock.accepts(capturedAt: 1.99, now: 2.31, generation: oldWorkerGeneration))
        // Even giving an old raw frame the current generation cannot bypass the time floor.
        XCTAssertFalse(clock.accepts(capturedAt: 1.99, now: 2.31, generation: clock.generation))
        XCTAssertFalse(clock.accepts(capturedAt: 2, now: 2.31, generation: clock.generation))
        XCTAssertTrue(clock.accepts(capturedAt: 2.3, now: 2.31, generation: clock.generation))
    }
    func testConfirmedStopStillTransitionsClockAfterSuspension() {
        var clock = CaptureSessionClock()
        _ = clock.setActive(true, now: 1)
        clock.invalidatePendingFrames(at: 2)
        XCTAssertTrue(clock.setActive(false, now: 2.81))
        XCTAssertFalse(clock.isCapturing)
        XCTAssertFalse(clock.setActive(false, now: 2.9))
        XCTAssertFalse(clock.accepts(capturedAt: 2.85, now: 2.91, generation: clock.generation))
    }
    func testFurtherSuspensionInvalidatesWorkFromPreviousResume() {
        var clock = CaptureSessionClock()
        _ = clock.setActive(true, now: 1)
        clock.invalidatePendingFrames(at: 2)
        let previousResumeGeneration = clock.generation
        clock.invalidatePendingFrames(at: 2.5)
        XCTAssertFalse(clock.accepts(capturedAt: 2.4, now: 2.6, generation: previousResumeGeneration))
        XCTAssertFalse(clock.accepts(capturedAt: 2.4, now: 2.6, generation: clock.generation))
        XCTAssertTrue(clock.accepts(capturedAt: 2.55, now: 2.6, generation: clock.generation))
    }
    func testProbeAuthoritativeTrueDoesNotFallIntoFalseFlagReconciliation() {
        var gate = CaptureActivityMonitor()
        XCTAssertEqual(gate.system(true, now: 1), .started)
        for now in [1.2, 2.0, 2.8, 3.6] {
            // CoachModel supplies diagnosticCaptureActive || UIScreen.isCaptured.
            XCTAssertEqual(gate.system(true, now: now), .none)
            XCTAssertEqual(gate.tick(now: now), .none)
            XCTAssertTrue(gate.isActive)
            XCTAssertFalse(gate.isReconciling)
        }
        XCTAssertEqual(gate.system(false, now: 4), .suspended)
        XCTAssertEqual(gate.tick(now: 4.81), .stopped)
    }
}
