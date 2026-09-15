import XCTest

final class SmokeTests: XCTestCase {
    func testRankLearningFitsOneScreenAndCanUndo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POKER_RUN_PRIVATE_UI_FIXTURES"] == "1",
                          "Private image UI regression is opt-in; public checkout does not include its screenshot.")
        let app = XCUIApplication()
        app.launchArguments = ["--show-rank-learning"]
        app.launch()
        if app.staticTexts["rank.empty"].exists {
            XCTFail("Private fixture mode was explicitly enabled, but Documents/RankLearningFixture.png could not be loaded.")
            return
        }
        let boardAce = app.buttons["rank.sample.board.0"]
        XCTAssertTrue(boardAce.waitForExistence(timeout: 10), "The local real-card fixture must be available")
        boardAce.tap()
        XCTAssertTrue(app.buttons["rank.value.A"].isHittable)
        app.buttons["rank.value.A"].tap()
        XCTAssertTrue(app.buttons["rank.save"].isHittable)
        app.buttons["rank.save"].tap()
        XCTAssertTrue(app.staticTexts["rank.status"].label.contains("已记住 A"))
        XCTAssertTrue(app.buttons["rank.undo"].isHittable)
        XCTAssertTrue(app.buttons["rank.undo"].isEnabled)
        attach(app, name: "rank-learning-saved")
        app.buttons["rank.undo"].tap()
        XCTAssertTrue(app.staticTexts["rank.status"].label.contains("已撤销"))
    }
    func testPlainLanguageHelpFitsOneScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--show-help-glossary"]
        app.launch()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["未成对／高牌"].isHittable)
        XCTAssertTrue(app.staticTexts["同花顺"].isHittable)
        let amountMeaning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "建议：跟注 3.20＝")).firstMatch
        XCTAssertTrue(amountMeaning.isHittable, "The amount explanation must fit without scrolling")
        attach(app, name: "plain-language-help")
    }
    func testSingleEntryHome() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["capture.start"].isHittable)
        XCTAssertTrue(app.buttons["help.open"].isHittable)
        XCTAssertFalse(app.buttons["demo.run"].exists)
        XCTAssertFalse(app.buttons["pip.start"].exists)
        XCTAssertFalse(app.buttons["capture.pause"].exists)
        attach(app, name: "home")
        app.buttons["help.open"].tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 3))
        attach(app, name: "help")
        app.buttons["help.done"].tap()
        XCTAssertTrue(app.buttons["capture.start"].isHittable)
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
