import AppKit
import XCTest

/// Base for the fixture-mode E2E scenarios (PLAN 5.3): the real AppCore stores run against a
/// fixture under `$TMPDIR/lightwell-fixtures/<uuid>/`, and every test ends with the sentinel guard
/// (files in a sibling folder must be unchanged).
class E2ETestCase: XCTestCase {
    private(set) var fixture: E2EFixture!
    private var sentinel: SentinelGuard!
    private(set) var app: XCUIApplication!

    static var fixtureArea: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lightwell-fixtures", isDirectory: true)
    }

    /// The deterministic claude double, built by `swift build --product fake-claude` (or `make test`).
    static var fakeClaudePath: String {
        // UITests/E2E/E2ETestCase.swift -> repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/Kit/.build/debug/fake-claude").path
    }

    static let missingFakeClaude = "/nonexistent/lightwell-uitest/fake-claude"

    /// Name of the fixture's unique folder (the scan root's name in the app).
    var fixtureFolderName: String { UUID().uuidString }

    /// Folder the fixture is created in (the fixture area itself by default).
    var fixtureParent: URL { Self.fixtureArea }

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try E2EFixture.make(in: fixtureParent, name: fixtureFolderName)
        sentinel = try SentinelGuard.make(beside: fixture.root)
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        if let sentinel {
            let changed = sentinel.changes()
            XCTAssertEqual(changed, [], "files outside the fixture changed")
            sentinel.delete()
        }
        // Also removes the app's scratch folder, `<fixture>/.lightwell-app`.
        fixture?.delete()
    }

    // MARK: Launch and scan

    @MainActor
    @discardableResult
    func launch(fakeClaude: String = E2ETestCase.missingFakeClaude, extraArguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments = [
            "-LightwellUITestMode", "YES",
            "-LightwellFixtureRoot", fixture.root.path,
            "-LightwellFakeClaude", fakeClaude,
            "-LightwellAppearance", "light",
        ] + extraArguments
        app.launch()
        self.app = app
        return app
    }

    /// Start: the fixture row, then a scan that lands on Explore at the fixture root.
    @MainActor
    func scanFixture() {
        let row = element("start.recent.\(fixture.name)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the fixture is listed on Start")
        if row.buttons.firstMatch.exists { row.buttons.firstMatch.click() } else { row.click() }
        XCTAssertTrue(element("explore.map").waitForExistence(timeout: 30), "Explore opens after the scan")
        XCTAssertTrue(listRow("home").waitForExistence(timeout: 10))
    }

    // MARK: Queries

    @MainActor
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    func listRow(_ name: String) -> XCUIElement { element("explore.list.row.\(name)") }

    @MainActor
    func tile(_ name: String) -> XCUIElement { element("explore.tile.\(name)") }

    /// Clicks the map tile `name` (an `explore.tile.<name>` AX element, framed like its drawn tile).
    /// The click goes near the top of the tile: a folder tile draws its children below a header,
    /// and a click there opens the folder rather than a child. Returns false when the element has
    /// no usable frame.
    @MainActor
    @discardableResult
    func clickTile(_ name: String) -> Bool {
        let target = tile(name)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "tile \(name) is an AX element")
        let frame = target.frame
        guard !frame.isEmpty, frame.width.isFinite, frame.height.isFinite else { return false }
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: min(12, frame.height / 2)))
            .click()
        return true
    }

    /// Visible text of an element (macOS static texts carry it in the value, buttons in the label).
    @MainActor
    func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    /// Text of the current folder's size in the Explore header.
    @MainActor
    var headerSize: String { text(of: element("explore.mapHeader.size")) }

    /// Polls `condition` until it holds or `timeout` passes.
    @MainActor
    @discardableResult
    func eventually(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    // MARK: Navigation

    /// Opens folders one after another: select the row, then Return (the list's primary action).
    /// Not a double-click: under load a synthesized double-click can arrive as two single clicks,
    /// and its second click can land on the row that takes the folder's place. One retry.
    @MainActor
    func open(_ names: String...) {
        for name in names {
            var opened = false
            for _ in 0..<2 where !opened {
                let row = listRow(name)
                XCTAssertTrue(row.waitForExistence(timeout: 10), "row \(name)")
                row.click()
                app.typeKey(.return, modifierFlags: [])
                opened = eventually(timeout: 5) { crumbLabels.last == name }
            }
            XCTAssertTrue(opened, "opened \(name), breadcrumb \(crumbLabels)")
        }
    }

    /// Labels of the breadcrumb buttons, root first.
    @MainActor
    var crumbLabels: [String] {
        var labels: [String] = []
        var index = 0
        while true {
            let crumb = element("explore.breadcrumb.\(index)")
            guard crumb.exists else { return labels }
            labels.append(crumb.label)
            index += 1
        }
    }

    /// Selects a list row and adds it to the queue with the menu command (Cmd+Delete).
    @MainActor
    func queueRow(_ name: String) {
        let row = listRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "row \(name)")
        row.click()
        XCTAssertTrue(eventually(timeout: 3) { element("explore.inspector.addToCleanup").isEnabled }, "\(name) can be queued")
        app.typeKey(.delete, modifierFlags: .command)
    }

    /// Moves the list selection one row down (keyboard) and queues that row.
    @MainActor
    func queueNextRow() {
        app.typeKey(.downArrow, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey(.delete, modifierFlags: .command)
    }

    /// History back (Cmd+[), then waits for a row of the folder it returns to.
    @MainActor
    func goBack(expecting name: String) {
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(listRow(name).waitForExistence(timeout: 5), "back shows \(name)")
    }

    /// Presses an alert's default (first) button with Return, after checking it is that button.
    /// Keyboard, not a click: the alert is centered on screen, where a system prompt from another
    /// app can cover it, and a click there would land on the prompt.
    @MainActor
    func pressDefaultAlertButton(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5), "alert button \(button)")
        let alertButtons = app.dialogs.firstMatch.buttons
        if alertButtons.count > 0 {
            XCTAssertEqual(alertButtons.element(boundBy: 0).label, button.label, "the default button")
        }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(eventually(timeout: 5) { !button.exists }, "the alert closed")
    }

    @MainActor
    func isBelowToolbar(_ element: XCUIElement) -> Bool {
        let window = app.windows["main"].frame
        let toolbar = app.windows["main"].toolbars.firstMatch
        let toolbarBottom = toolbar.exists ? toolbar.frame.maxY : window.minY + 40
        let frame = element.frame
        return !frame.isEmpty && frame.minY >= toolbarBottom - 1 && window.insetBy(dx: -1, dy: -1).contains(frame)
    }

    /// Whether the Explore page fits the window: the breadcrumb can be clicked (not under the
    /// toolbar or above the window) and the item inspector ends inside the window.
    @MainActor
    var explorePageFitsWindow: Bool {
        let window = app.windows["main"].frame
        let crumb = element("explore.breadcrumb.0")
        return crumb.isHittable && isBelowToolbar(crumb) && element("explore.inspector").frame.maxY <= window.maxY + 1
    }

    /// Clicks `element`; when another window (for example a system permission prompt in the middle
    /// of the screen) covers it, first drags Lightwell's window sideways until it is uncovered.
    @MainActor
    func clickEvenIfCovered(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element)")
        if !element.isHittable {
            let window = app.windows["main"]
            let screen = NSScreen.main?.visibleFrame ?? .zero
            for delta in [-320.0, 320, -520, 520] {
                let frame = window.frame
                let target = min(max(frame.minX + delta, screen.minX), screen.maxX - frame.width)
                guard abs(target - frame.minX) > 20 else { continue }
                let grip = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width * 0.55, dy: 14))
                grip.press(forDuration: 0.5, thenDragTo: grip.withOffset(CGVector(dx: target - frame.minX, dy: 0)))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                if element.isHittable { break }
            }
        }
        element.click()
    }

    @MainActor
    func showQueue() {
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(element("queue.trash").waitForExistence(timeout: 5))
    }

    @MainActor
    func showExplore() {
        let item = element("sidebar.explore")
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(element("explore.map").waitForExistence(timeout: 5))
    }

    @MainActor
    func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
