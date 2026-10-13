import CleanupKit
import Foundation
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

@Suite("Cleanup store with the executor on a fixture", .serialized)
@MainActor
struct CleanupModelTests {
    @Test func addingCopiesIdentityAndRiskFromTheRules() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree

        let derived = try fixture.node("home/Library/Developer/Xcode/DerivedData/App-1")
        let result = cleanup.add(tree.summary(of: derived), source: .user)
        guard case .added = result else { Issue.record("not added: \(result)"); return }
        let item = try #require(cleanup.queue.first)
        #expect(item.identity == tree.identity(derived))
        #expect(item.identity != nil)
        #expect(item.risk == .safe)
        #expect(item.ruleID == "xcode.deriveddata")
        #expect(item.isSelected)

        let notes = try fixture.node("home/Downloads/notes.txt")
        cleanup.add(tree.summary(of: notes), source: .user)
        #expect(cleanup.queue.last?.risk == .review)

        // Adding a child of a queued folder is covered; the parent absorbs queued children.
        let child = try fixture.node("home/Library/Developer/Xcode/DerivedData/App-1/build.o")
        #expect(cleanup.add(tree.summary(of: child), source: .user) == .coveredByParent(fixture.path("home/Library/Developer/Xcode/DerivedData/App-1")))
    }

    @Test func protectedItemsAreRefused() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        let session = app.session

        let keychains = try fixture.node("home/Library/Keychains")
        guard case .blocked = cleanup.add(tree.summary(of: keychains), source: .user) else { Issue.record("Keychains queued"); return }
        #expect(session.addBlockReason(for: keychains) != nil, "Add to Cleanup is disabled with a reason")
        #expect(cleanup.add(tree.summary(of: tree.root), source: .user) == .blocked(.scanRoot))
        #expect(session.addBlockReason(for: tree.root) == .scanRoot)
        let home = try fixture.node("home")
        guard case .blocked = cleanup.add(tree.summary(of: home), source: .user) else { Issue.record("home queued"); return }
        let outside = try fixture.node("outside.bin")
        guard case .blocked = cleanup.add(tree.summary(of: outside), source: .user) else { Issue.record("outside the home queued"); return }
        #expect(session.addBlockReason(for: try fixture.node("home/Downloads/notes.txt")) == nil)
        #expect(cleanup.queue.isEmpty)
    }

    @Test func dangerousItemsNeedTheUserAndAnAcknowledgement() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        let old = try fixture.node("home/Documents/Old")

        #expect(cleanup.add(tree.summary(of: old), source: .assistant(thread: UUID(), reason: "old")) == .needsUserChoice)
        guard case .added(let id) = cleanup.add(tree.summary(of: old), source: .user) else { Issue.record("user could not queue"); return }
        let item = try #require(cleanup.queue.first)
        #expect(item.risk == .dangerous)
        #expect(!item.isSelected, "dangerous items are never ticked automatically")
        cleanup.setSelected(id, true)
        #expect(cleanup.queue.first?.isSelected == false, "and can not be ticked before the acknowledgement")
        #expect(!cleanup.canRun)
        #expect(cleanup.nestedDangerousPaths(of: item) == [fixture.path("home/Documents/Old/Family.photoslibrary")])

        // Without the acknowledgement nothing runs.
        await cleanup.run(mode: .trash)
        #expect(cleanup.lastReport == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/Documents/Old/Family.photoslibrary/originals/a.jpg")))

        cleanup.acknowledge(id)
        cleanup.setSelected(id, true)
        #expect(cleanup.removalSet.map(\.id) == [id])
        #expect(cleanup.canRun)
        await cleanup.run(mode: .trash)
        #expect(cleanup.lastReport?.succeeded.count == 1, "\(String(describing: cleanup.lastReport?.failed))")
        #expect(!FileManager.default.fileExists(atPath: fixture.path("home/Documents/Old")))
    }

    @Test func acknowledgingAnAssistantItemMakesItTheUsers() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        let notes = try fixture.node("home/Downloads/notes.txt")
        guard case .added(let id) = cleanup.add(tree.summary(of: notes), source: .assistant(thread: UUID(), reason: "old notes")) else { Issue.record("not added"); return }
        cleanup.acknowledge(id)
        #expect(cleanup.queue.first?.source == .user)
        cleanup.acknowledge(id, false)
        #expect(cleanup.queue.first?.isSelected == false)
    }

    @Test func categoryItemsAndSafeItemsStartSelected() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        cleanup.addSafeItems(from: app.session)
        let paths = Set(cleanup.queue.map(\.path))
        #expect(paths.contains(fixture.path("home/Library/Developer/Xcode/DerivedData/App-1")))
        #expect(paths.contains(fixture.path("home/Library/Caches/com.example.app")))
        #expect(cleanup.queue.allSatisfy { $0.isSelected && $0.risk == .safe })
        #expect(cleanup.queue.allSatisfy { if case .category = $0.source { true } else { false } })
    }

    @Test func trashRunMovesIntoTheFixtureTrashAndUpdatesTheTree() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let session = app.session
        let tree = fixture.tree
        let derived = try fixture.node("home/Library/Developer/Xcode/DerivedData")
        let app1 = try fixture.node("home/Library/Developer/Xcode/DerivedData/App-1")
        let dmg = try fixture.node("home/Downloads/old-installer.dmg")
        session.navigate(to: app1)
        let before = tree.size(tree.root)
        let freed = tree.size(app1) + tree.size(dmg)

        cleanup.add(tree.summary(of: app1), source: .user)
        cleanup.add(tree.summary(of: dmg), source: .user)
        let revision = session.treeRevision
        cleanup.requestRun(mode: .trash)
        #expect(await waitUntil { cleanup.lastReport != nil && !cleanup.isRunning })

        let report = try #require(cleanup.lastReport)
        #expect(report.succeeded.count == 2, "\(report.failed)")
        #expect(report.bytesMovedToTrash == freed)
        let trash = fixture.root.appendingPathComponent(FixtureTrash.folderName)
        let trashed = report.succeeded.compactMap(\.trashedURL)
        #expect(trashed.count == 2)
        #expect(trashed.allSatisfy { $0.path.hasPrefix(trash.path) && FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: fixture.path("home/Downloads/old-installer.dmg")))
        #expect(cleanup.queue.isEmpty)
        #expect(cleanup.recentlyTrashed.count == 2)
        #expect(tree.size(tree.root) == before - freed)
        #expect(session.current == derived, "navigation moved to the surviving parent")
        #expect(session.treeRevision != revision)

        cleanup.deleteRecentlyTrashedPermanently()
        #expect(await waitUntil { cleanup.recentlyTrashed.isEmpty && !cleanup.isRunning })
        #expect(trashed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func permanentRunWaitsForTheCountdownAndStopAborts() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        let notes = try fixture.node("home/Downloads/notes.txt")
        cleanup.add(tree.summary(of: notes), source: .user)

        cleanup.requestRun(mode: .permanent)
        #expect(cleanup.countdownRemaining == CleanupModel.countdownSeconds)
        #expect(!cleanup.canRun)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(cleanup.countdownRemaining == CleanupModel.countdownSeconds - 1)
        cleanup.stopCountdown()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(cleanup.countdownRemaining == nil)
        #expect(cleanup.lastReport == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/Downloads/notes.txt")))

        cleanup.requestRun(mode: .permanent)
        #expect(await waitUntil(timeout: 10) { cleanup.lastReport != nil && !cleanup.isRunning }, "countdown \(String(describing: cleanup.countdownRemaining)) running \(cleanup.isRunning) canRun \(cleanup.canRun) queue \(cleanup.queue.count)")
        #expect(cleanup.lastReport?.mode == .permanent)
        #expect(cleanup.lastReport?.succeeded.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("home/Downloads/notes.txt")))
        #expect(cleanup.recentlyTrashed.isEmpty)
    }

    @Test func executorStaysInsideItsAllowedRoot() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = fixture.tree
        // The allowed root is only Downloads: anything else is refused even though it was queued.
        let cleanup = CleanupModel(configuration: .fixture(root: fixture.root.appendingPathComponent("home/Downloads"), home: fixture.home))
        let engine = RuleEngine(home: fixture.home, rules: .bundled, policy: SafetyPolicy(home: fixture.home, scanRoot: fixture.root.path), metadata: LiveFileMetadata())
        let context = CleanupScanContext(tree: tree, engine: engine, volume: nil)
        cleanup.scanContext = { _ in context }
        cleanup.scanRoots = { [fixture.root.path] }
        let caches = try fixture.node("home/Library/Caches/com.example.app")
        let notes = try fixture.node("home/Downloads/notes.txt")
        cleanup.add(node: caches, context: context, source: .user)
        cleanup.add(node: notes, context: context, source: .user)
        await cleanup.run(mode: .permanent)
        let report = try #require(cleanup.lastReport)
        #expect(report.succeeded.map(\.path) == [fixture.path("home/Downloads/notes.txt")])
        #expect(report.failed.map(\.path) == [fixture.path("home/Library/Caches/com.example.app")])
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/Library/Caches/com.example.app/cache.bin")))
        #expect(cleanup.queue.map(\.path) == [fixture.path("home/Library/Caches/com.example.app")], "failed items stay queued")
    }

    @Test func changedItemsAreRefusedByIdentity() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        let notes = try fixture.node("home/Downloads/notes.txt")
        cleanup.add(tree.summary(of: notes), source: .user)
        // Replace the file after the scan: same path, new inode.
        try FileManager.default.removeItem(atPath: fixture.path("home/Downloads/notes.txt"))
        _ = try fixture.fx.file("home/Downloads/notes.txt", size: 4096)
        await cleanup.run(mode: .trash)
        let report = try #require(cleanup.lastReport)
        #expect(report.succeeded.isEmpty)
        #expect(report.failed.first?.kind == .changedSinceScan)
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/Downloads/notes.txt")))
    }
}
