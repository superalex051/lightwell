import CleanupKit
import Foundation
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Fix round 1: a full rescan of the scan root waits for the rate limit, the session shows when
/// it will run, Refresh Now runs it at once, and when it lands nothing the person was looking at
/// moves: the folder, the selection, the history, and the queue's rows (order, ids, texts).
@Suite("Postponed full refresh", .serialized)
@MainActor
struct FullRefreshTests {
    @Test func pendingFullRefreshIsShownAndRefreshNowKeepsEverythingInPlace() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let model = AppModel.live(
            launchOptions: AppLaunchOptions(isUITestMode: true, fixtureRoot: fixture.root, fakeClaude: nil, uiTestDroppedEvents: true),
            defaults: UserDefaults(suiteName: "com.alexluncan.lightwell.tests.unused")!,
            assistantRoot: fixture.root.appendingPathComponent("app-files")
        )
        defer { model.shutdown() }
        let session = model.startScan(.folder(fixture.root))
        #expect(await waitUntil { session.state == .finished && !session.isClassifying && !session.categories.isEmpty })
        let tree = try #require(session.tree as? ScanTree)
        let canonical = ScanSessionModel.canonicalRoot(fixture.root)

        // The injected drop asks for a full rescan; it waits, and the session says until when.
        #expect(await waitUntil(timeout: 10) { session.fullRefreshPendingAt != nil })
        let at = try #require(session.fullRefreshPendingAt)
        #expect(at.timeIntervalSinceNow > 60, "runs later, not now")

        // Explore position, selection and history, and a queue with a category row and a user row.
        let home = try #require(tree.node(atPath: canonical + "/home"))
        let downloads = try #require(tree.node(atPath: canonical + "/home/Downloads"))
        session.navigate(to: home)
        session.navigate(to: downloads)
        session.goBack()
        let dmg = try #require(tree.node(atPath: canonical + "/home/Downloads/old-installer.dmg"))
        session.selection = dmg
        let category = try #require(session.categories.first { $0.ruleID == "xcode.deriveddata" })
        model.cleanup.add(category: category, tree: tree)
        model.cleanup.add(tree.summary(of: dmg), source: .user)
        let rowsBefore = model.cleanup.queue.map { [$0.id.uuidString, $0.path, session.sourceTitle(of: $0) ?? "", session.explanation(of: $0) ?? ""] }
        #expect(rowsBefore.count >= 2)
        let epoch = tree.structureEpoch

        session.refreshEverythingNow()
        #expect(session.fullRefreshPendingAt == nil)
        // The session has handled the restructure once its scan context names the new epoch.
        #expect(await waitUntil(timeout: 15) { tree.structureEpoch == epoch + 1 && session.cleanupContext?.expectedEpoch == epoch + 1 })
        #expect(await waitUntil(timeout: 15) { !session.categories.isEmpty })

        #expect(tree.path(session.current) == canonical + "/home", "Explore stays in the same folder")
        #expect(session.selection.map { tree.path($0) } == canonical + "/home/Downloads/old-installer.dmg")
        #expect(session.forwardStack.map { tree.path($0) } == [canonical + "/home/Downloads"])
        let rowsAfter = model.cleanup.queue.map { [$0.id.uuidString, $0.path, session.sourceTitle(of: $0) ?? "", session.explanation(of: $0) ?? ""] }
        #expect(rowsAfter == rowsBefore, "queue rows changed across the full refresh")
        #expect(model.cleanup.queue.allSatisfy { item in item.nodeID.map { tree.path($0) } == item.path }, "rows point at the new node ids")
        #expect(session.fullRefreshPendingAt == nil)
    }
}
