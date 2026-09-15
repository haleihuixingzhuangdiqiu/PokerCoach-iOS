import XCTest
@testable import PokerCoachCore

final class GuidanceRenderScheduleTests: XCTestCase {
    func testIdenticalContentOnlySubmitsAsHeartbeat() {
        var schedule = GuidanceRenderSchedule()
        XCTAssertTrue(schedule.shouldSubmit(key: "same text", now: 10))
        schedule.didSubmit(key: "same text", at: 10)
        for offset in 1..<50 {
            XCTAssertFalse(schedule.shouldSubmit(key: "same text", now: 10 + Double(offset) / 100))
        }
        XCTAssertTrue(schedule.shouldSubmit(key: "same text", now: 10.5))
    }

    func testWithdrawnActionAndExpiredContentBypassHeartbeatDelay() {
        var schedule = GuidanceRenderSchedule()
        schedule.didSubmit(key: "参考：跟注3.20", at: 10)
        XCTAssertTrue(schedule.shouldSubmit(key: "正在读取牌局", now: 10.001))
        schedule.didSubmit(key: "正在读取牌局", at: 10.001)
        XCTAssertTrue(schedule.shouldSubmit(key: "等待新画面", now: 10.002))
    }

    func testBackpressureDoesNotMarkUnsubmittedContentAsDisplayed() {
        var schedule = GuidanceRenderSchedule()
        schedule.didSubmit(key: "old action", at: 10)
        // A caller that cannot enqueue deliberately does not call didSubmit.
        XCTAssertTrue(schedule.shouldSubmit(key: "unknown card", now: 10.01))
        XCTAssertTrue(schedule.shouldSubmit(key: "unknown card", now: 10.02))
        // The next attempt takes the newest state, with no retained intermediate queue.
        XCTAssertTrue(schedule.shouldSubmit(key: "new hand", now: 10.03))
        schedule.didSubmit(key: "new hand", at: 10.03)
        XCTAssertFalse(schedule.shouldSubmit(key: "new hand", now: 10.04))
    }

    func testNewDisplayAttachmentAndClockRegressionResubmit() {
        var schedule = GuidanceRenderSchedule()
        schedule.didSubmit(key: "same", at: 10)
        XCTAssertTrue(schedule.shouldSubmit(key: "same", now: 9))
        XCTAssertFalse(schedule.shouldSubmit(key: "same", now: .nan))
        schedule.reset()
        XCTAssertTrue(schedule.shouldSubmit(key: "same", now: 10.01))
    }
}
