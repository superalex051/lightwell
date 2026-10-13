import XCTest

/// PLAN 5.3 scenarios E1 to E11 and E13, in fixture mode against the real stores.
/// The sentinel guard runs in `E2ETestCase.tearDownWithError` after every test.
final class E2EScenarioTests: E2ETestCase {
    // MARK: E1 Launch

    @MainActor
    func testE1LaunchShowsFixtureSource() {
        launch()
        XCTAssertTrue(element("start.recent.\(fixture.name)").waitForExistence(timeout: 15), "Start lists the fixture")
        XCTAssertTrue(element("start.scanFolder").exists)
        let volumes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'start.volume.'"))
        XCTAssertEqual(volumes.count, 0, "UI test mode lists no real volumes")
    }

    // MARK: E2 Scan

    @MainActor
    func testE2ScanRootSizeMatchesOracle() {
        let expected = E2EBytes.string(fixture.allocatedBytes())
        launch()
        scanFixture()
        XCTAssertTrue(eventually(timeout: 5) { headerSize == expected }, "root size \(headerSize), oracle \(expected)")
    }

    // MARK: E3 Navigate

    @MainActor
    func testE3NavigateListMapBreadcrumbAndHistory() {
        launch()
        scanFixture()

        // List row drill-in.
        open("home")
        XCTAssertTrue(listRow("Downloads").waitForExistence(timeout: 5))

        // Map tile click: a folder tile opens the folder.
        XCTAssertTrue(tile("Documents").waitForExistence(timeout: 5), "map tiles are AX elements")
        XCTAssertTrue(tile(fixture.revealFolder).exists, "two levels of tiles")
        XCTAssertTrue(tile("Documents").label.hasPrefix("Documents, "), "tile label is name and size")
        XCTAssertTrue(clickTile("Documents"), "the Documents tile is on the map")
        XCTAssertTrue(listRow(fixture.revealFolder).waitForExistence(timeout: 5), "the tile opened Documents")
        XCTAssertTrue(tile("report.pdf").waitForExistence(timeout: 5))
        // PB-1: tile elements carry the frame of their drawn tile, inside the map.
        let reportFrame = tile("report.pdf").frame
        XCTAssertFalse(reportFrame.isEmpty, "tile AX frame \(reportFrame)")
        XCTAssertTrue(element("explore.map").frame.insetBy(dx: -1, dy: -1).contains(reportFrame), "tile \(reportFrame) inside the map \(element("explore.map").frame)")

        // Breadcrumb back to home (PB-2: it sits below the toolbar, inside the window). A system
        // permission prompt in the middle of the screen can cover this crumb (it follows the long
        // fixture name); then the enclosing-folder command (Cmd+Up) stands in for the click.
        let crumb = element("explore.breadcrumb.1")
        XCTAssertEqual(crumb.label, "home")
        XCTAssertTrue(isBelowToolbar(crumb), "breadcrumb \(crumb.frame) below the toolbar, inside the window \(app.windows["main"].frame)")
        if crumb.isHittable { crumb.click() } else { app.typeKey(.upArrow, modifierFlags: .command) }
        XCTAssertTrue(listRow("Downloads").waitForExistence(timeout: 5), "breadcrumb opened home")

        // Cmd+[ goes back to Documents, Cmd+] forward to home again.
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(listRow(fixture.revealFolder).waitForExistence(timeout: 5), "Back returned to Documents")
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(listRow("Downloads").waitForExistence(timeout: 5), "Forward returned to home")
        XCTAssertFalse(listRow(fixture.revealFolder).exists)
    }

    // MARK: E4 Quick Look and Reveal

    @MainActor
    func testE4QuickLookAndReveal() {
        launch()
        scanFixture()
        open("home", "Documents", fixture.revealFolder)
        let row = listRow("report.pdf")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        // The Quick Look panel is a window of the app titled "Quick Look".
        let panel = app.windows.matching(NSPredicate(format: "title == %@", "Quick Look")).firstMatch
        XCTAssertFalse(panel.exists)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Space opens the Quick Look panel: \(app.windows.allElementsBoundByIndex.map(\.title))")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(eventually(timeout: 5) { !panel.exists }, "Space again closes it")

        // Reveal (Item menu, Opt+Cmd+R): Finder comes forward with the enclosing folder.
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 10), "Reveal brings Finder forward")
        let window = finder.windows[fixture.revealFolder]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Finder shows the enclosing folder")
        // Close only the window this test opened.
        let close = window.buttons[XCUIIdentifierCloseWindow]
        if close.exists { close.click() } else { finder.typeKey("w", modifierFlags: .command) }
        XCTAssertTrue(eventually(timeout: 5) { !window.exists }, "the Finder window this test opened is closed")
        app.activate()
    }

    // MARK: E5 Trash flow

    @MainActor
    func testE5MoveTwoItemsToTrash() {
        launch()
        scanFixture()
        open("home", "Downloads")
        // PB-2: the page fits the window before and after an add.
        XCTAssertTrue(explorePageFitsWindow, "before an add: breadcrumb \(element("explore.breadcrumb.0").frame), inspector \(element("explore.inspector").frame)")
        queueRow("old-installer.dmg")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attachScreenshot("E5-after-add")
        XCTAssertTrue(explorePageFitsWindow, "after an add: breadcrumb \(element("explore.breadcrumb.0").frame), inspector \(element("explore.inspector").frame)")
        XCTAssertTrue(element("sidebar.explore").isHittable, "sidebar intact after the add: \(element("sidebar.explore").frame)")
        // Pointer clicks land on the row under the pointer again.
        let second = listRow("notes-archive.zip")
        XCTAssertTrue(second.isHittable, "row \(second.frame) is hittable after the add")
        queueRow("notes-archive.zip")

        showQueue()
        XCTAssertTrue(element("queue.row.old-installer.dmg").waitForExistence(timeout: 5))
        XCTAssertTrue(element("queue.row.notes-archive.zip").exists)
        element("queue.trash").click()
        XCTAssertTrue(element("queue.confirm.trash").waitForExistence(timeout: 5))
        element("queue.confirm.trash").click()
        XCTAssertTrue(element("queue.report").waitForExistence(timeout: 15), "report shown")
        attachScreenshot("E5-report")

        XCTAssertFalse(fixture.exists("home/Downloads/old-installer.dmg"))
        XCTAssertFalse(fixture.exists("home/Downloads/notes-archive.zip"))
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)) ?? []
        XCTAssertTrue(trashed.contains { $0.hasSuffix("old-installer.dmg") }, "in .test-trash: \(trashed)")
        XCTAssertTrue(trashed.contains { $0.hasSuffix("notes-archive.zip") }, "in .test-trash: \(trashed)")
        XCTAssertFalse(element("queue.row.old-installer.dmg").exists, "queue updated")
        XCTAssertFalse(element("queue.row.notes-archive.zip").exists, "queue updated")

        // Tree and totals: Downloads is empty now and home shrank by both items.
        showExplore()
        let downloads = E2EBytes.string(fixture.allocatedBytes("home/Downloads"))
        XCTAssertTrue(eventually(timeout: 5) { headerSize == downloads }, "Downloads shows \(headerSize), expected \(downloads)")
        XCTAssertFalse(listRow("old-installer.dmg").exists)
        goBack(expecting: "Library")  // the empty Downloads folder now sits in the small-items row
        let home = E2EBytes.string(fixture.allocatedBytes("home"))
        XCTAssertTrue(eventually(timeout: 5) { headerSize == home }, "home shows \(headerSize), expected \(home)")
    }

    // MARK: E6 Permanent flow

    @MainActor
    func testE6PermanentCountdownStopThenRun() {
        launch()
        scanFixture()
        open("home", "Library", "Developer", "Xcode", "DerivedData")
        queueRow("App-1")
        queueNextRow()
        showQueue()
        XCTAssertTrue(element("queue.row.App-1").waitForExistence(timeout: 5))
        XCTAssertTrue(element("queue.row.App-2").exists)

        // First run: Stop during the countdown keeps both files.
        element("queue.deletePermanently").click()
        XCTAssertTrue(element("queue.confirm.permanent").waitForExistence(timeout: 5))
        element("queue.confirm.permanent").click()
        XCTAssertTrue(element("queue.countdown").waitForExistence(timeout: 3), "countdown visible")
        element("queue.countdown.stop").click()
        XCTAssertTrue(eventually(timeout: 3) { !element("queue.countdown").exists })
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        XCTAssertTrue(fixture.exists("home/Library/Developer/Xcode/DerivedData/App-1/build.o"), "Stop kept the files")
        XCTAssertTrue(fixture.exists("home/Library/Developer/Xcode/DerivedData/App-2/index.db"))
        XCTAssertFalse(element("queue.report").exists)

        // Second run: the countdown ends and both are gone for good (not in the fixture Trash).
        element("queue.deletePermanently").click()
        XCTAssertTrue(element("queue.confirm.permanent").waitForExistence(timeout: 5))
        element("queue.confirm.permanent").click()
        XCTAssertTrue(element("queue.countdown").waitForExistence(timeout: 3))
        XCTAssertTrue(element("queue.report").waitForExistence(timeout: 20), "report after the countdown")
        XCTAssertFalse(fixture.exists("home/Library/Developer/Xcode/DerivedData/App-1"))
        XCTAssertFalse(fixture.exists("home/Library/Developer/Xcode/DerivedData/App-2"))
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)) ?? []
        XCTAssertFalse(trashed.contains { $0.contains("App-") }, "permanent, not in the Trash: \(trashed)")
    }

    // MARK: E7 Protected item

    @MainActor
    func testE7ProtectedItemCannotBeQueued() {
        launch()
        scanFixture()
        open("home", "Library")
        let row = listRow("Keychains")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        // The inspector must describe Keychains itself, not the enclosing (also protected) folder.
        let inspector = element("explore.inspector")
        XCTAssertTrue(eventually(timeout: 5) {
            inspector.staticTexts.matching(NSPredicate(format: "value == 'Keychains' OR label == 'Keychains'")).count > 0
        }, "Keychains is selected")
        XCTAssertFalse(element("explore.inspector.addToCleanup").isEnabled, "Add to Cleanup disabled")
        let note = element("explore.inspector.note")
        XCTAssertTrue(note.waitForExistence(timeout: 3), "a reason is shown")
        XCTAssertFalse(text(of: note).isEmpty)
        app.typeKey(.delete, modifierFlags: .command)
        showQueue()
        XCTAssertTrue(element("queue.empty").waitForExistence(timeout: 3), "nothing was queued")
        XCTAssertFalse(element("queue.row.Keychains").exists)
    }

    // MARK: E8 Reclaim

    @MainActor
    func testE8ReclaimAddsOnlySafeItems() {
        launch()
        scanFixture()
        element("sidebar.reclaim").click()
        let derived = element("reclaim.category.xcode.deriveddata")
        XCTAssertTrue(derived.waitForExistence(timeout: 10))
        let downloads = element("reclaim.category.downloads.items")
        XCTAssertTrue(downloads.exists)
        XCTAssertTrue(element("reclaim.category.caches.user").exists)
        XCTAssertTrue(element("reclaim.category.logs.user").exists)
        // Risk badges head each group: DerivedData, caches and logs sit under Safe, Downloads under Review.
        let safe = badge("Safe"), review = badge("Review")
        XCTAssertTrue(safe.exists, "Safe badge")
        XCTAssertTrue(review.exists, "Review badge")
        XCTAssertTrue(derived.frame.minY > safe.frame.minY && derived.frame.minY < review.frame.minY, "DerivedData is in the Safe group")
        XCTAssertTrue(element("reclaim.category.logs.user").frame.minY < review.frame.minY, "logs are in the Safe group")
        XCTAssertTrue(downloads.frame.minY > review.frame.minY, "Downloads is in the Review group")
        attachScreenshot("E8-reclaim")

        element("reclaim.addSafe").click()
        XCTAssertTrue(element("reclaim.feedback").waitForExistence(timeout: 5))
        showQueue()
        for name in ["App-1", "App-2", "com.example.app", "old-session.log"] {
            XCTAssertTrue(element("queue.row.\(name)").waitForExistence(timeout: 5), "\(name) queued")
            XCTAssertEqual(element("queue.row.\(name).checkbox").value as? Int, 1, "\(name) ticked")
        }
        for name in ["old-installer.dmg", "notes-archive.zip", "Keychains", "report.pdf"] {
            XCTAssertFalse(element("queue.row.\(name)").exists, "\(name) is not safe and stays out")
        }
        // Exactly the four safe items: nothing else slipped in.
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'queue.row.' AND NOT (identifier ENDSWITH '.checkbox' OR identifier ENDSWITH '.remove' OR identifier ENDSWITH '.acknowledge')"
        ))
        XCTAssertEqual(rows.count, 4, "queue rows: \(rows.allElementsBoundByIndex.map(\.identifier))")
    }

    @MainActor
    private func badge(_ word: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@", word)).firstMatch
    }

    // MARK: E9 Live refresh

    @MainActor
    func testE9LiveRefreshShowsNewFileWithinFiveSeconds() throws {
        launch()
        scanFixture()
        open("home", "Downloads")
        XCTAssertTrue(listRow("notes-archive.zip").waitForExistence(timeout: 5))
        let before = headerSize
        try fixture.write("home/Downloads/fresh-download.bin", bytes: 5_000_000)
        let expected = E2EBytes.string(fixture.allocatedBytes("home/Downloads"))
        XCTAssertNotEqual(before, expected)
        let start = Date()
        let updated = eventually(timeout: 5) { headerSize == expected && tile("fresh-download.bin").exists }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(updated, "Downloads shows \(headerSize), expected \(expected) within 5 s")
        let note = XCTAttachment(string: String(format: "E9 live refresh: header and map updated after %.2f s", elapsed))
        note.lifetime = .keepAlways
        add(note)
        print(String(format: "E9 live refresh: header and map updated after %.2f s", elapsed))
        // PB-3: the list shows the new file too.
        XCTAssertTrue(listRow("fresh-download.bin").waitForExistence(timeout: 5), "list row for the new file")
    }

    // MARK: E10 Assistant

    @MainActor
    func testE10AssistantProposalLandsUnselected() throws {
        let fake = Self.fakeClaudePath
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fake), "build it first: swift build --package-path Packages/Kit --product fake-claude")
        launch(fakeClaude: fake)
        scanFixture()
        element("explore.assistantToggle").click()

        let open = element("assistant.consent.open")
        XCTAssertTrue(open.waitForExistence(timeout: 15), "consent card first")
        clickEvenIfCovered(open)
        XCTAssertTrue(element("assistant.consent.accept").waitForExistence(timeout: 5))
        clickEvenIfCovered(element("assistant.consent.accept"))
        let input = element("assistant.input")
        XCTAssertTrue(input.waitForExistence(timeout: 15), "ready after consent")

        let installer = fixture.url("home/Downloads/old-installer.dmg").path
        let keychain = fixture.url("home/Library/Keychains/login.keychain-db").path
        clickEvenIfCovered(input)
        input.typeText("Please suggest \(installer) and \(keychain)")
        clickEvenIfCovered(element("assistant.send"))

        let message = element("assistant.message")
        XCTAssertTrue(message.waitForExistence(timeout: 30), "streamed reply appears")
        XCTAssertTrue(eventually(timeout: 10) { !text(of: message).isEmpty })
        let card = element("assistant.proposal.0")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "proposal card")
        XCTAssertTrue(element("assistant.proposal.0.rejected").exists, "the keychain was refused")
        attachScreenshot("E10-assistant")

        clickEvenIfCovered(element("assistant.proposal.0.review"))
        let row = element("queue.row.old-installer.dmg")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "suggestion is in the queue")
        XCTAssertEqual(element("queue.row.old-installer.dmg.checkbox").value as? Int, 0, "assistant items wait unticked")
        XCTAssertFalse(element("queue.row.login.keychain-db").exists)
        XCTAssertTrue(fixture.exists("home/Downloads/old-installer.dmg"), "nothing was deleted")
    }

    /// PB-2: inside a folder, after an add and with the assistant open, the page still fits the
    /// window and the composer is visible and takes typing.
    @MainActor
    func testE10LayoutFitsWithAssistantInsideAFolder() throws {
        let fake = Self.fakeClaudePath
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fake), "build it first: swift build --package-path Packages/Kit --product fake-claude")
        launch(fakeClaude: fake)
        scanFixture()
        open("home", "Downloads")
        queueRow("old-installer.dmg")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        element("explore.assistantToggle").click()
        let consent = element("assistant.consent.open")
        XCTAssertTrue(consent.waitForExistence(timeout: 15), "consent card first")
        clickEvenIfCovered(consent)
        XCTAssertTrue(element("assistant.consent.accept").waitForExistence(timeout: 5))
        clickEvenIfCovered(element("assistant.consent.accept"))
        let input = element("assistant.input")
        XCTAssertTrue(input.waitForExistence(timeout: 15), "ready after consent")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attachScreenshot("PB2-assistant-in-folder")

        let window = app.windows["main"].frame
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(input.frame), "composer \(input.frame) inside the window \(window)")
        XCTAssertTrue(input.isHittable, "composer is hittable")
        XCTAssertTrue(explorePageFitsWindow, "with the assistant: breadcrumb \(element("explore.breadcrumb.0").frame), inspector \(element("explore.inspector").frame)")
        input.click()
        input.typeText("hello")
        XCTAssertTrue(eventually(timeout: 3) { text(of: input).contains("hello") }, "the composer took the typing: \(text(of: input))")
    }

    // MARK: E11 Assistant unavailable

    @MainActor
    func testE11MissingClaudeShowsSetupCard() {
        launch(fakeClaude: Self.missingFakeClaude)
        scanFixture()
        element("explore.assistantToggle").click()
        let setup = element("assistant.setup")
        XCTAssertTrue(setup.waitForExistence(timeout: 15), "setup card")
        if element("assistant.consent.open").exists {
            element("assistant.consent.open").click()
            element("assistant.consent.accept").click()
        }
        XCTAssertTrue(element("assistant.chooseBinary").waitForExistence(timeout: 15), "not installed card with Choose claude Binary")
        XCTAssertFalse(element("assistant.input").exists, "no composer without the CLI")
    }

    // MARK: E13 Quit guard

    /// A pending permanent deletion holds Cmd+Q with a confirmation; Stay keeps the app running
    /// and nothing is deleted while the alert is up.
    @MainActor
    func testE13QuitGuardDuringCountdown() {
        launch()
        scanFixture()
        open("home", "Downloads")
        queueRow("notes-archive.zip")
        showQueue()
        element("queue.deletePermanently").click()
        XCTAssertTrue(element("queue.confirm.permanent").waitForExistence(timeout: 5))
        element("queue.confirm.permanent").click()
        XCTAssertTrue(element("queue.countdown").waitForExistence(timeout: 3))

        app.typeKey("q", modifierFlags: .command)
        let stay = app.buttons.matching(identifier: "Stay").firstMatch
        XCTAssertTrue(stay.waitForExistence(timeout: 5), "quit confirmation shown")
        XCTAssertTrue(app.buttons.matching(identifier: "Quit Anyway").firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "E13-quit-guard"
        shot.lifetime = .keepAlways
        add(shot)
        // The alert says nothing has been deleted yet: that must stay true while it is open,
        // even past the end of the 5 s countdown (PB-5: the countdown holds under the alert).
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        XCTAssertTrue(fixture.exists("home/Downloads/notes-archive.zip"), "nothing deleted while the quit alert is open")
        XCTAssertFalse(element("queue.report").exists, "no run while the quit alert is open")
        pressDefaultAlertButton(stay)
        XCTAssertEqual(app.state, .runningForeground, "Stay keeps Lightwell open")
        // Stay resumes the countdown where it was; Stop then keeps the file.
        let stop = element("queue.countdown.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "the countdown resumes after Stay")
        stop.click()
        XCTAssertTrue(eventually(timeout: 3) { !element("queue.countdown").exists })
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(fixture.exists("home/Downloads/notes-archive.zip"), "Stop after Stay kept the file")
    }

    /// Quit Anyway during the countdown cancels it: the app quits and the file stays.
    @MainActor
    func testE13QuitAnywayDuringCountdownKeepsFiles() throws {
        launch()
        scanFixture()
        open("home", "Downloads")
        queueRow("notes-archive.zip")
        showQueue()
        element("queue.deletePermanently").click()
        XCTAssertTrue(element("queue.confirm.permanent").waitForExistence(timeout: 5))
        element("queue.confirm.permanent").click()
        XCTAssertTrue(element("queue.countdown").waitForExistence(timeout: 3))

        app.typeKey("q", modifierFlags: .command)
        let quit = app.buttons.matching(identifier: "Quit Anyway").firstMatch
        XCTAssertTrue(quit.waitForExistence(timeout: 5), "quit confirmation shown")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        XCTAssertTrue(fixture.exists("home/Downloads/notes-archive.zip"), "nothing deleted while the quit alert is open")
        // Quit Anyway has no keyboard equivalent, so it takes a pointer click. Never click through
        // another app's window (a system permission prompt can sit over the centered alert).
        guard quit.isHittable else {
            pressDefaultAlertButton(app.buttons.matching(identifier: "Stay").firstMatch)
            if element("queue.countdown.stop").waitForExistence(timeout: 3) { element("queue.countdown.stop").click() }
            throw XCTSkip("Quit Anyway is covered by another window (likely a system prompt); nothing was deleted while the alert was open")
        }
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Quit Anyway quits")
        XCTAssertTrue(fixture.exists("home/Downloads/notes-archive.zip"), "quitting cancelled the deletion")
    }

    /// PLAN 5.3 E13 as written: a non-empty queue asks before quitting. UI test mode skips that
    /// prompt unless `-LightwellUITestQuitPrompt YES` is set (PB-4).
    @MainActor
    func testE13QuitGuardWithQueuedItems() {
        launch(extraArguments: ["-LightwellUITestQuitPrompt", "YES"])
        scanFixture()
        open("home", "Downloads")
        queueRow("notes-archive.zip")
        showQueue()
        XCTAssertTrue(element("queue.row.notes-archive.zip").waitForExistence(timeout: 5))

        app.typeKey("q", modifierFlags: .command)
        let keep = app.buttons.matching(identifier: "Keep Queue").firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "quit confirmation for a non-empty queue")
        XCTAssertTrue(app.buttons.matching(identifier: "Quit Anyway").firstMatch.exists)
        pressDefaultAlertButton(keep)
        XCTAssertEqual(app.state, .runningForeground, "Keep Queue keeps Lightwell open")
        XCTAssertTrue(element("queue.row.notes-archive.zip").exists)
        XCTAssertTrue(fixture.exists("home/Downloads/notes-archive.zip"))
    }
}
