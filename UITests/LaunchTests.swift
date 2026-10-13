import XCTest

/// E2E skeleton (PLAN 5.3). TODO(WS10): fixture-backed scenarios E1 to E13.
final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsStart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LightwellUITestMode", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["start.scanFolder"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "start-screen"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    @MainActor
    func testScanVolumeOpensExplore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LightwellUITestMode", "YES"]
        app.launch()
        let row = app.descendants(matching: .any)["start.volume.Macintosh HD"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["explore.map"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["explore.list.row.Users"].exists)
        app.descendants(matching: .any)["explore.queueToggle"].firstMatch.click()
        app.descendants(matching: .any)["explore.assistantToggle"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["queue.trash"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].exists)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "explore-screen"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }
}
