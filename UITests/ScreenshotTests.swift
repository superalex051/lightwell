import XCTest

/// Walks every screen on preview data and attaches a window screenshot of each
/// (export with `xcrun xcresulttool export attachments`). Also checks the AX ids each screen promises.
final class ScreenshotTests: XCTestCase {
    @MainActor
    private func launch(scene: String? = nil, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = ["-LightwellUITestMode", "YES", "-LightwellAppearance", dark ? "dark" : "light"]
        if let scene { arguments += ["-LightwellUITestScene", scene] }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String, window: XCUIElement? = nil) {
        let shot = XCTAttachment(screenshot: (window ?? app.windows.firstMatch).screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func openExplore(_ app: XCUIApplication) {
        let row = element(app, "start.volume.Macintosh HD")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons.firstMatch.click()
        XCTAssertTrue(element(app, "explore.map").waitForExistence(timeout: 10))
    }

    @MainActor
    func testStartAndOnboarding() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            XCTAssertTrue(element(app, "start.scanFolder").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, "start.fdaBanner").exists)
            snap(app, dark ? "01-start-dark" : "01-start-light")
            if !dark {
                element(app, "start.fdaBanner.showHow").click()
                XCTAssertTrue(element(app, "onboarding.root").waitForExistence(timeout: 5))
                XCTAssertTrue(element(app, "onboarding.openSettings").exists)
                XCTAssertTrue(element(app, "onboarding.relaunch").exists)
                snap(app, "02-onboarding")
                element(app, "onboarding.skip").click()
            }
            app.terminate()
        }
    }

    @MainActor
    func testScanning() {
        let app = launch(scene: "scanning")
        XCTAssertTrue(element(app, "scan.progress").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "scan.cancel").exists)
        snap(app, "03-scanning")
        app.terminate()
    }

    @MainActor
    func testExploreOverviewReclaim() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            openExplore(app)
            XCTAssertTrue(element(app, "explore.list.row.Users").exists)
            XCTAssertTrue(element(app, "explore.breadcrumb.0").exists)
            XCTAssertTrue(element(app, "explore.back").exists)
            XCTAssertTrue(element(app, "explore.forward").exists)
            XCTAssertTrue(element(app, "explore.inspector").exists)
            element(app, "explore.list.row.Users").click()
            snap(app, dark ? "04-explore-dark" : "04-explore-light")
            if !dark {
                element(app, "explore.list.row.Users").doubleClick()
                XCTAssertTrue(element(app, "explore.list.row.preview").waitForExistence(timeout: 5))
                element(app, "explore.list.row.preview").doubleClick()
                XCTAssertTrue(element(app, "explore.list.row.Library").waitForExistence(timeout: 5))
                element(app, "explore.list.row.Library").click()
                snap(app, "05-explore-drilled")

                element(app, "sidebar.overview").click()
                XCTAssertTrue(element(app, "overview.hero").waitForExistence(timeout: 5))
                snap(app, "06-overview")

                element(app, "sidebar.reclaim").click()
                XCTAssertTrue(element(app, "reclaim.addSafe").waitForExistence(timeout: 5))
                XCTAssertTrue(element(app, "reclaim.category.xcode.derivedData").exists)
                element(app, "reclaim.category.simulator.devices.toggle").click()
                snap(app, "07-reclaim")
            }
            app.terminate()
        }
    }

    @MainActor
    func testCleanupFlow() {
        let app = launch()
        openExplore(app)

        // A dangerous item queued by the user starts unticked and locked until acknowledged.
        element(app, "sidebar.reclaim").click()
        XCTAssertTrue(element(app, "reclaim.category.ios.backups.toggle").waitForExistence(timeout: 5))
        element(app, "reclaim.category.ios.backups.toggle").click()
        XCTAssertTrue(element(app, "reclaim.add.ios.backups").waitForExistence(timeout: 5))
        element(app, "reclaim.add.ios.backups").click()

        element(app, "explore.queueToggle").click()
        XCTAssertTrue(element(app, "queue.trash").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "queue.deletePermanently").exists)
        XCTAssertTrue(element(app, "queue.row.DerivedData").exists)
        let backup = app.checkBoxes["queue.row.Backup.checkbox"].firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        XCTAssertFalse(backup.isEnabled)
        XCTAssertEqual(backup.value as? Int, 0)
        snap(app, "08-cleanup")
        element(app, "queue.row.Backup.acknowledge").click()
        XCTAssertTrue(backup.isEnabled)
        snap(app, "08b-cleanup-acknowledged")

        element(app, "queue.trash").click()
        XCTAssertTrue(element(app, "queue.confirm").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "queue.confirm.counts").exists)
        snap(app, "09-cleanup-confirm-trash")
        element(app, "queue.confirm.trash").click()
        XCTAssertTrue(element(app, "queue.report").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "queue.report.emptyTrash").exists)
        snap(app, "10-cleanup-report")

        // Leaving Cleanup during the countdown stops it visibly and deletes nothing.
        element(app, "queue.row.node_modules.checkbox").click()
        element(app, "queue.deletePermanently").click()
        XCTAssertTrue(element(app, "queue.confirm.permanent").waitForExistence(timeout: 5))
        snap(app, "11-cleanup-confirm-permanent")
        element(app, "queue.confirm.permanent").click()
        XCTAssertTrue(element(app, "queue.countdown.stop").waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes["queue.row.node_modules.checkbox"].firstMatch.isEnabled)
        snap(app, "12-cleanup-countdown")
        element(app, "sidebar.explore").click()
        XCTAssertTrue(element(app, "session.notice").waitForExistence(timeout: 5))
        snap(app, "12b-countdown-stopped-notice")
        element(app, "session.notice.dismiss").click()

        // Stop also keeps everything.
        element(app, "sidebar.cleanup").click()
        XCTAssertTrue(element(app, "queue.row.node_modules").waitForExistence(timeout: 5))
        element(app, "queue.deletePermanently").click()
        XCTAssertTrue(element(app, "queue.confirm.permanent").waitForExistence(timeout: 5))
        element(app, "queue.confirm.permanent").click()
        XCTAssertTrue(element(app, "queue.countdown.stop").waitForExistence(timeout: 5))
        element(app, "queue.countdown.stop").click()
        XCTAssertTrue(element(app, "queue.row.node_modules").exists)
        app.terminate()
    }

    @MainActor
    func testAssistantReady() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            openExplore(app)
            element(app, "explore.assistantToggle").click()
            XCTAssertTrue(element(app, "assistant.input").waitForExistence(timeout: 5))
            XCTAssertTrue(element(app, "assistant.send").exists)
            XCTAssertTrue(element(app, "assistant.proposal.0").exists)
            snap(app, dark ? "13-assistant-dark" : "13-assistant-light")
            if !dark {
                element(app, "assistant.toolLogToggle").click()
                XCTAssertTrue(element(app, "assistant.toolLog").waitForExistence(timeout: 5))
                snap(app, "14-assistant-tool-log")
            }
            app.terminate()
        }
    }

    @MainActor
    func testAssistantStates() {
        let scenes = ["assistant-consent", "assistant-notInstalled", "assistant-notSignedIn", "assistant-failed", "assistant-disabled", "assistant-checking"]
        for (index, scene) in scenes.enumerated() {
            let app = launch(scene: scene)
            XCTAssertTrue(element(app, "assistant.setup").waitForExistence(timeout: 10), scene)
            snap(app, String(format: "15-%02d-%@", index, scene))
            if scene == "assistant-consent" {
                element(app, "assistant.consent.open").click()
                XCTAssertTrue(element(app, "assistant.consent").waitForExistence(timeout: 5))
                snap(app, "15-consent-sheet")
                element(app, "assistant.consent.accept").click()
                XCTAssertTrue(element(app, "assistant.input").waitForExistence(timeout: 5))
            }
            app.terminate()
        }
        for scene in ["assistant-streaming", "assistant-empty"] {
            let app = launch(scene: scene)
            XCTAssertTrue(element(app, "assistant.input").waitForExistence(timeout: 10), scene)
            if scene == "assistant-streaming" {
                XCTAssertTrue(element(app, "assistant.stop").exists)
            }
            snap(app, "16-\(scene)")
            app.terminate()
        }
    }

    @MainActor
    func testSettings() {
        let app = launch()
        XCTAssertTrue(element(app, "start.scanFolder").waitForExistence(timeout: 10))
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        // The Settings window reopens on the tab used last, so pick General explicitly.
        let generalTab = app.toolbars.buttons["General"].firstMatch
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5))
        generalTab.click()
        let general = element(app, "settings.general")
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        let window = app.windows.containing(.any, identifier: "settings.general").firstMatch
        snap(app, "17-settings-general", window: window)
        let tabs = [("Scanning", "settings.scanning"), ("Assistant", "settings.assistant"), ("Permissions", "settings.permissions"), ("About", "settings.about")]
        // A system prompt left in the middle of the screen (for example a permission request from
        // another app) covers the centered Settings toolbar; move the window to the left edge then.
        if !app.toolbars.buttons[tabs[0].0].firstMatch.isHittable {
            let grip = window.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.02))
            grip.press(forDuration: 0.3, thenDragTo: grip.withOffset(CGVector(dx: 12 - window.frame.minX, dy: 0)))
        }
        for (index, tab) in tabs.enumerated() {
            app.toolbars.buttons[tab.0].firstMatch.click()
            XCTAssertTrue(element(app, tab.1).waitForExistence(timeout: 5), tab.1)
            let window = app.windows.containing(.any, identifier: tab.1).firstMatch
            snap(app, "17-settings-\(index + 1)-\(tab.0.lowercased())", window: window)
        }
        app.terminate()
    }
}
