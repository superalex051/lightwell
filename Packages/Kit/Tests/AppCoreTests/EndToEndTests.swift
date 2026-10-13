import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// The real stack on a fixture, wired exactly like UI test mode (PLAN 5.3): real Scanner,
/// RuleEngine with `<fixture>/home`, FixtureTrash and an executor limited to the fixture.
@Suite("End to end on a fixture: scan, explore, queue, trash", .serialized)
@MainActor
struct EndToEndTests {
    static func liveModel(_ fixture: HomeFixture) -> AppModel {
        AppModel.live(
            launchOptions: AppLaunchOptions(isUITestMode: true, fixtureRoot: fixture.root, fakeClaude: nil),
            defaults: UserDefaults(suiteName: "com.alexluncan.lightwell.tests.unused")!,
            assistantRoot: fixture.root.appendingPathComponent("app-files")
        )
    }

    @Test func scanExploreQueueTrash() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let oracle = try Oracle.walk(fixture.root)
        let model = Self.liveModel(fixture)
        defer { model.shutdown() }

        let folder = try #require(model.recentFolders.first)
        let session = model.startScan(.folder(folder))
        #expect(await waitUntil { session.state == .finished })
        #expect(await waitUntil { !session.isClassifying && !session.categories.isEmpty })
        let tree = try #require(session.tree)
        #expect(tree.size(tree.root) == oracle.totalBytes, "root size equals the oracle")

        // Explore: drill into home/Library/Developer/Xcode/DerivedData through the children.
        let canonical = ScanSessionModel.canonicalRoot(fixture.root)
        func child(_ parent: NodeID, _ name: String) throws -> NodeID {
            try #require(tree.children(parent).first { tree.name($0) == name }, "no \(name)")
        }
        var folderID = tree.root
        for name in ["home", "Library", "Developer", "Xcode", "DerivedData"] {
            folderID = try child(folderID, name)
            session.navigate(to: folderID)
        }
        #expect(tree.path(session.current) == canonical + "/home/Library/Developer/Xcode/DerivedData")
        #expect(session.breadcrumb.count == 6)
        #expect(session.category(covering: try child(folderID, "App-1"))?.ruleID == "xcode.deriveddata")
        session.goBack()
        session.goForward()
        #expect(session.current == folderID)

        // Queue: one safe rule item from Reclaim, one user item, a protected item refused.
        let keychains = try #require(tree.node(atPath: canonical + "/home/Library/Keychains"))
        #expect(!session.canQueue(keychains))
        guard case .blocked = model.cleanup.add(tree.summary(of: keychains), source: .user) else { Issue.record("Keychains queued"); return }
        model.cleanup.addSafeItems(from: session)
        let dmg = try #require(tree.node(atPath: canonical + "/home/Downloads/old-installer.dmg"))
        let summary = tree.summary(of: dmg)
        #expect(summary.identity != nil)
        model.cleanup.add(summary, source: .user)
        #expect(model.cleanup.queue.allSatisfy { $0.identity != nil && $0.isSelected })
        #expect(model.quitBlockers.queueHasItems)
        let queued = model.cleanup.queue
        let freed = queued.reduce(UInt64(0)) { $0 + $1.freesAbout }
        let before = tree.size(tree.root)

        // Trash: everything lands in <fixture>/.test-trash; the tree and totals follow.
        model.cleanup.requestRun(mode: .trash)
        #expect(await waitUntil { model.cleanup.lastReport != nil && !model.cleanup.isRunning })
        let report = try #require(model.cleanup.lastReport)
        #expect(report.failed.isEmpty, "\(report.failed.map(\.message))")
        #expect(report.succeeded.count == queued.count)
        for item in queued { #expect(!FileManager.default.fileExists(atPath: item.path)) }
        let trash = fixture.root.appendingPathComponent(FixtureTrash.folderName).path
        #expect(report.succeeded.allSatisfy { $0.trashedURL.map { ScanSessionModel.canonicalRoot($0).hasPrefix(ScanSessionModel.canonicalRoot(URL(fileURLWithPath: trash))) } ?? false })
        #expect(tree.size(tree.root) == before - freed)
        #expect(model.cleanup.queue.isEmpty)
        #expect(tree.path(session.current) == canonical + "/home/Library/Developer/Xcode/DerivedData")
        #expect(model.cleanup.recentlyTrashed.count == queued.count)
    }

    @Test func liveRefreshPicksUpANewFile() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let model = Self.liveModel(fixture)
        defer { model.shutdown() }
        let session = model.startScan(.folder(fixture.root))
        #expect(await waitUntil { session.state == .finished })
        let tree = try #require(session.tree)
        let before = tree.size(tree.root)
        let revision = session.treeRevision
        let started = Date()
        _ = try fixture.fx.file("home/Downloads/new-5mb.bin", size: 5_000_000)
        #expect(await waitUntil(timeout: 10) { session.treeRevision != revision && tree.size(tree.root) > before + 4_000_000 })
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 6, "refresh took \(elapsed) s")
        print("live refresh: 5 MB file visible after \(String(format: "%.2f", elapsed)) s")
        // Ending the session stops the refresher.
        model.closeSession(session.id)
        #expect(model.sessions.isEmpty)
    }

    @Test func navigationSurvivesReassignedNodeIDs() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = fixture.tree
        let session = ScanSessionModel(target: .folder(fixture.root), tree: tree, services: fixture.services())
        session.startScan()
        let home = try fixture.node("home")
        let downloads = try fixture.node("home/Downloads")
        let library = try fixture.node("home/Library")
        session.navigate(to: home)
        session.navigate(to: library)
        session.goBack()
        session.selection = downloads
        // Rebuild Library and Downloads so they get new node ids, as after a full root rescan.
        tree.removeSubtree(library)
        tree.removeSubtree(downloads)
        let newLibrary = tree.addDirectory("Library", under: home, identity: FileIdentity(device: 1, inode: 9_000_001))
        let newDownloads = tree.addDirectory("Downloads", under: home, identity: FileIdentity(device: 1, inode: 9_000_002))
        session.restructured()
        #expect(session.current == home)
        #expect(session.forwardStack == [newLibrary])
        #expect(session.selection == newDownloads)
        #expect(await waitUntil { !session.isClassifying })
    }

    @Test func mainActorStaysResponsiveDuringAScanOfManyFiles() async throws {
        // Built off the main actor: writing 30k files would otherwise stall other tests' timers.
        let fixture = try await Task.detached {
            try HomeFixture { fx in
                for folder in 0..<20 { try fx.manyFiles(in: "home/Projects/big\(folder)/node_modules/pkg", count: 1500, size: 4096) }
            }
        }.value
        defer { fixture.tearDown() }
        let model = Self.liveModel(fixture)
        defer { model.shutdown() }
        let clock = ContinuousClock()
        let heartbeat = Task { @MainActor () -> Duration in
            var worst = Duration.zero
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = clock.now
                worst = max(worst, now - last)
                last = now
            }
            return worst
        }
        let session = model.startScan(.folder(fixture.root))
        #expect(await waitUntil(timeout: 60) { session.state == .finished && !session.isClassifying && !session.categories.isEmpty })
        let handler = try #require(model.toolHandler)
        _ = await handler.handle(name: "get_largest_items", arguments: ["limit": 50], thread: UUID())
        _ = await handler.handle(name: "search_items", arguments: ["extension": "bin", "limit": 50], thread: UUID())
        heartbeat.cancel()
        let worst = await heartbeat.value
        let worstMs = Double(worst.components.seconds) * 1000 + Double(worst.components.attoseconds) / 1e15 - 2
        print("main actor during a \(session.tree.map { $0.descendantCount($0.root) } ?? 0)-item scan: worst stall \(String(format: "%.1f", worstMs)) ms")
        #if DEBUG
        #expect(worstMs < 100, "debug build")
        #else
        #expect(worstMs < 16)
        #endif
    }
}
