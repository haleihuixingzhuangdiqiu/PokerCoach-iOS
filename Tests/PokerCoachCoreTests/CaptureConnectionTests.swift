import XCTest
@testable import PokerCoachCore

final class CaptureConnectionTests: XCTestCase {
    func testSystemRecordingWithoutOwnExtensionFrameCannotResume() {
        let phase = CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: nil, now: 10)
        XCTAssertEqual(phase, .waitingForFrames)
        XCTAssertFalse(phase.canResumeGuidance)
    }

    func testFirstOwnFrameEnablesResumeAndInterruptionCanRecover() {
        XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 10, now: 10.2), .receiving)
        XCTAssertTrue(CaptureConnectionPhase.receiving.canResumeGuidance)
        let interrupted = CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 10, now: 13.01)
        XCTAssertEqual(interrupted, .interrupted)
        XCTAssertFalse(interrupted.canResumeGuidance)
        XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 14, now: 14.1), .receiving)
    }

    func testConnectionWindowIncludesExactlyThreeSeconds() {
        XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 10, now: 13), .receiving)
        XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 10, now: 13.001), .interrupted)
    }

    func testStoppedCaptureDoesNotResumeFromARecentFrame() {
        let phase = CaptureConnectionPhase.evaluate(isCaptured: false, lastFrameAt: 10, now: 10.1)
        XCTAssertEqual(phase, .stopped)
        XCTAssertFalse(phase.canResumeGuidance)
    }

    func testConnectionRejectsInvalidAndFutureClocks() {
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: invalid, now: 10), .interrupted)
            XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 10, now: invalid), .interrupted)
            XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: nil, now: invalid), .interrupted)
        }
        XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 10.1, now: 10), .interrupted)
    }

    func testFirstFrameMayPrecedeStartNotification() {
        var clock = CaptureSessionClock()
        XCTAssertTrue(clock.setActive(true, now: 10.1))
        XCTAssertEqual(clock.generation, 1)
        XCTAssertTrue(clock.accepts(capturedAt: 10, now: 10.2, generation: clock.generation))
        XCTAssertEqual(clock.lastStoppedAt, -Double.infinity)
    }

    func testDuplicateCaptureNotificationsDoNotResetGeneration() {
        var clock = CaptureSessionClock()
        XCTAssertFalse(clock.setActive(false, now: 9))
        XCTAssertEqual(clock.generation, 0)
        XCTAssertTrue(clock.setActive(true, now: 10))
        XCTAssertFalse(clock.setActive(true, now: 10.2))
        XCTAssertEqual(clock.generation, 1)
        XCTAssertTrue(clock.accepts(capturedAt: 10.1, now: 10.3, generation: 1))
        XCTAssertTrue(clock.setActive(false, now: 11))
        XCTAssertFalse(clock.setActive(false, now: 12))
        XCTAssertEqual(clock.generation, 2)
        XCTAssertEqual(clock.lastStoppedAt, 11)
    }

    func testQueuedFramesAtOrBeforeStopCannotEnterRestartedSession() {
        var clock = CaptureSessionClock()
        clock.setActive(true, now: 10)
        clock.setActive(false, now: 10.2)
        XCTAssertFalse(clock.accepts(capturedAt: 10.1, now: 10.3, generation: clock.generation))
        clock.setActive(true, now: 10.4)
        XCTAssertFalse(clock.accepts(capturedAt: 10.1, now: 10.5, generation: clock.generation))
        XCTAssertFalse(clock.accepts(capturedAt: 10.2, now: 10.5, generation: clock.generation))
        // The new session's real first frame may again precede its start notification.
        XCTAssertTrue(clock.accepts(capturedAt: 10.3, now: 10.5, generation: clock.generation))
    }

    func testPriorGenerationRecognitionIsRejectedEvenWhenTimestampIsFresh() {
        var clock = CaptureSessionClock()
        clock.setActive(true, now: 10)
        let oldGeneration = clock.generation
        clock.setActive(false, now: 10.1)
        clock.setActive(true, now: 10.2)
        XCTAssertFalse(clock.accepts(capturedAt: 10.25, now: 10.3, generation: oldGeneration))
        XCTAssertTrue(clock.accepts(capturedAt: 10.25, now: 10.3, generation: clock.generation))
    }

    func testAnalysisFreshnessRemainsShorterThanConnectionWindow() {
        var clock = CaptureSessionClock()
        clock.setActive(true, now: 0)
        XCTAssertTrue(clock.accepts(capturedAt: 0, now: 0.8, generation: clock.generation))
        XCTAssertFalse(clock.accepts(capturedAt: 0, now: 0.801, generation: clock.generation))
        XCTAssertEqual(CaptureConnectionPhase.evaluate(isCaptured: true, lastFrameAt: 0, now: 0.801), .receiving)
    }

    func testSessionRejectsInvalidAndFutureFrameClocks() {
        var clock = CaptureSessionClock()
        clock.setActive(true, now: 10)
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertFalse(clock.accepts(capturedAt: invalid, now: 10, generation: clock.generation))
            XCTAssertFalse(clock.accepts(capturedAt: 10, now: invalid, generation: clock.generation))
        }
        XCTAssertFalse(clock.accepts(capturedAt: 10.1, now: 10, generation: clock.generation))
    }
}
