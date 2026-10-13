import XCTest

/// The real stores in the app (PLAN 5.3 fixture mode): Start lists only the fixture root, a scan
/// of it opens Explore, a protected item can not be queued, and a home item goes to the
/// fixture's Trash. Everything happens inside a fixture folder that the test deletes.
final class FixtureModeTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        let area = FileManager.default.temporaryDirectory.appendingPathComponent("lightwell-fixtures", isDirectory: true)
        fixture = area.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files: [(String, Int)] = [
            ("home/Downloads/old-installer.dmg", 2_000_000),
            ("home/Library/Keychains/login.keychain-db", 4096),
            ("home/Library/Developer/Xcode/DerivedData/App-1/build.o", 1_000_000),
        ]
        for (path, size) in files {
            let url = fixture.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: size).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        if let fixture, fixture.path.contains("/lightwell-fixtures/") {
            // The app's scratch folder (`.lightwell-app`) lives inside the fixture and goes with it.
            try? FileManager.default.removeItem(at: fixture)
        }
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Opens a folder row by double-click and waits for one of its children. A double-click on a
    /// busy machine can arrive as two single clicks, so it is retried a few times.
    @MainActor
    private func open(_ app: XCUIApplication, _ folder: String, showing child: String) {
        for _ in 0..<3 {
            element(app, "explore.list.row.\(folder)").doubleClick()
            if element(app, "explore.list.row.\(child)").waitForExistence(timeout: 5) { return }
        }
        XCTFail("could not open \(folder)")
    }

    @MainActor
    func testFixtureScanQueueAndTrash() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LightwellUITestMode", "YES", "-LightwellFixtureRoot", fixture.path, "-LightwellFakeClaude", "/nonexistent/fake-claude"]
        app.launch()
        defer { app.terminate() }

        let row = element(app, "start.recent.\(fixture.lastPathComponent)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "start.volume.Macintosh HD").exists, "only the fixture root is listed")
        row.buttons.firstMatch.exists ? row.buttons.firstMatch.click() : row.click()
        XCTAssertTrue(element(app, "explore.map").waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "explore.list.row.home").waitForExistence(timeout: 15))

        // Drill to home/Library: Keychains is protected, Add to Cleanup is disabled with a reason.
        open(app, "home", showing: "Library")
        open(app, "Library", showing: "Keychains")
        element(app, "explore.list.row.Keychains").click()
        XCTAssertFalse(element(app, "explore.inspector.addToCleanup").isEnabled)
        XCTAssertTrue(element(app, "explore.inspector.note").exists)

        // Back to home/Downloads: queue the installer and move it to the fixture Trash.
        element(app, "explore.back").click()
        XCTAssertTrue(element(app, "explore.list.row.Downloads").waitForExistence(timeout: 5))
        open(app, "Downloads", showing: "old-installer.dmg")
        element(app, "explore.list.row.old-installer.dmg").click()
        let note = element(app, "explore.inspector.note")
        XCTAssertTrue(element(app, "explore.inspector.addToCleanup").isEnabled, "note: \(note.exists ? note.label + " / " + String(describing: note.value) : "none")")
        // The menu command (Cmd+Delete) works however tall the window is.
        app.typeKey(.delete, modifierFlags: .command)

        element(app, "explore.queueToggle").click()
        XCTAssertTrue(element(app, "queue.row.old-installer.dmg").waitForExistence(timeout: 15))
        let trashButton = element(app, "queue.trash")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: trashButton)
        waitForExpectations(timeout: 15)
        // On a busy machine the first click can land while the queue page is still animating in.
        var confirmed = false
        for _ in 0..<3 where !confirmed {
            trashButton.click()
            confirmed = element(app, "queue.confirm.trash").waitForExistence(timeout: 5)
        }
        XCTAssertTrue(confirmed)
        element(app, "queue.confirm.trash").click()
        XCTAssertTrue(element(app, "queue.report").waitForExistence(timeout: 20))

        let original = fixture.appendingPathComponent("home/Downloads/old-installer.dmg").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: original))
        let trash = fixture.appendingPathComponent(".test-trash")
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        XCTAssertTrue(trashed.contains { $0.hasSuffix("old-installer.dmg") })
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "fixture-after-trash"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
