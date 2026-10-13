import XCTest

/// Live bug (2026-10-13): on the Cleanup page the queue list jumped by itself and scrolled with
/// lag while the live refresh kept changing the scanned tree; the worst case was a full rescan of
/// the scan root being swapped in (every node id changes). A long queue is scrolled down, then a
/// full refresh lands (dropped events injected, then Refresh Now) and plain refreshes follow: the
/// rows must stay where they are in the list. A guard test: on this small fixture it also passes
/// with the rows' old category-based badge (the unit test CleanupPageChurnTests pins that part).
final class CleanupStabilityTests: E2ETestCase {
    static let cacheCount = 60

    override func setUpWithError() throws {
        try super.setUpWithError()
        for index in 0..<Self.cacheCount {
            try fixture.write(String(format: "home/Library/Caches/com.example.cache%02d/data.bin", index), bytes: 8192)
        }
    }

    @MainActor
    func testQueueKeepsItsScrollPositionThroughAFullRefresh() throws {
        launch(extraArguments: ["-LightwellUITestDroppedEvents", "YES"])
        scanFixture()
        element("sidebar.reclaim").click()
        XCTAssertTrue(element("reclaim.addSafe").waitForExistence(timeout: 10))
        element("reclaim.addSafe").click()
        showQueue()
        let last = element(String(format: "queue.row.com.example.cache%02d", Self.cacheCount - 1))
        XCTAssertTrue(last.waitForExistence(timeout: 10), "the long queue is shown")
        // The injected drop postpones a full refresh, and the toolbar says so.
        let refreshNow = element("session.refreshNow")
        XCTAssertTrue(refreshNow.waitForExistence(timeout: 15), "the pending full refresh is shown")

        // Scroll well down the list.
        let first = element("queue.row.com.example.cache00")
        let scrollArea = app.scrollViews.containing(.any, identifier: "queue.row.com.example.cache00").firstMatch
        XCTAssertTrue(scrollArea.exists)
        scrollArea.scroll(byDeltaX: 0, deltaY: -1500)
        XCTAssertTrue(eventually(timeout: 3) { first.frame.minY < scrollArea.frame.minY }, "the list scrolled")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let anchor = element(String(format: "queue.row.com.example.cache%02d", Self.cacheCount / 2))
        /// Where the anchor row sits inside the visible part of the list.
        func offset() -> CGFloat { anchor.frame.minY - scrollArea.frame.minY }
        let before = offset()

        // The full refresh: every node id changes underneath the queue.
        refreshNow.click()
        XCTAssertTrue(eventually(timeout: 15) { !refreshNow.exists }, "the pending refresh goes once it runs")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        var drift: [CGFloat] = [offset() - before]

        // Then plain refreshes: each burst is followed by a quiet spell, so a refresh lands.
        for round in 0..<2 {
            try fixture.write("home/Downloads/churn-\(round).bin", bytes: 200_000 * (round + 1))
            RunLoop.current.run(until: Date().addingTimeInterval(4.5))
            drift.append(offset() - before)
        }
        attachScreenshot("cleanup-after-full-refresh")
        XCTAssertTrue(anchor.exists, "the row is still in the queue")
        XCTAssertTrue(drift.allSatisfy { abs($0) <= 1 }, "rows moved in the list: \(drift)")
    }
}
