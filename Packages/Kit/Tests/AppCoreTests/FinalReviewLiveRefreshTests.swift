import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Task 9 item 2: live-refresh categorization is coalesced and the classification cache is kept per path.
@Suite("Live refresh categorization", .serialized)
@MainActor
struct FinalReviewLiveRefreshTests {
    /// Adds `count` small folders under home/Projects, so one categorization walk takes a while.
    static func widen(_ fixture: HomeFixture, count: Int) throws {
        let projects = try fixture.node("home/Projects")
        for index in 0..<count {
            let folder = fixture.tree.addDirectory("bulk\(index)", under: projects)
            fixture.tree.addFile("f.txt", size: 10, under: folder)
        }
    }

    static func addCacheFolder(_ fixture: HomeFixture, _ index: Int) throws -> NodeID {
        let caches = try fixture.node("home/Library/Caches")
        let folder = fixture.tree.addDirectory("com.example.burst\(index)", under: caches, identity: FileIdentity(device: 1, inode: 8_000_000 + UInt64(index)))
        fixture.tree.addFile("blob", size: 4096, under: folder)
        return folder
    }

    // MARK: Item 2: live-refresh categorization

    @Test func rapidLiveRefreshesRunAtMostOneWalk() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        try Self.widen(fixture, count: 30_000)
        let app = try await AppHarness(fixture: fixture)
        let session = app.session
        let tree = fixture.tree
        let engine = try #require(session.engine)
        session.refreshClassifyInterval = .zero
        let cachesPath = fixture.path("home/Library/Caches")
        let before = session.walkStats.snapshot

        // A burst that arrives before any task runs: one walk, for the newest state.
        var newest: NodeID = tree.root
        for index in 0..<10 {
            newest = try Self.addCacheFolder(fixture, index)
            session.liveTreeChanged(paths: [cachesPath], generation: tree.generation)
        }
        #expect(await waitUntil(timeout: 60) { !session.isClassifying })
        let afterBurst = session.walkStats.snapshot
        #expect(afterBurst.started - before.started == 1, "ten refreshes, one walk")
        #expect(session.categories.contains { $0.nodes.contains(newest) }, "the newest folder is categorized")

        // Refreshes while a walk runs: the running walk stops early, and two never run at once.
        for index in 10..<16 {
            _ = await waitUntil(timeout: 30) { session.walkStats.snapshot.running == 1 || !session.isClassifying }
            newest = try Self.addCacheFolder(fixture, index)
            session.liveTreeChanged(paths: [cachesPath], generation: tree.generation)
        }
        #expect(await waitUntil(timeout: 60) { !session.isClassifying })
        let stats = session.walkStats.snapshot
        #expect(stats.maxRunning == 1, "at most one categorization walk at a time")
        #expect(stats.running == 0)
        #expect(stats.stoppedEarly > afterBurst.stoppedEarly, "a newer refresh cancels the running walk")
        print("live refresh walks: \(stats.started - before.started) started, \(stats.stoppedEarly - before.stoppedEarly) stopped early, max \(stats.maxRunning) at once")

        // The final result is the categorization of the final tree.
        #expect(session.categories == engine.categories(in: tree))
        #expect(session.categories.contains { $0.nodes.contains(newest) })
    }

    @Test func liveRefreshWalksAreThrottled() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let session = app.session
        let tree = fixture.tree
        let cachesPath = fixture.path("home/Library/Caches")
        session.refreshClassifyInterval = .seconds(30)
        let before = session.walkStats.snapshot.started

        let first = try Self.addCacheFolder(fixture, 0)
        session.liveTreeChanged(paths: [cachesPath], generation: tree.generation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.walkStats.snapshot.started == before, "a walk ran moments ago: the refresh waits")
        #expect(session.isClassifying)

        // A newer refresh replaces the waiting one; once the interval allows it, one walk runs.
        session.refreshClassifyInterval = .zero
        let second = try Self.addCacheFolder(fixture, 1)
        session.liveTreeChanged(paths: [cachesPath], generation: tree.generation)
        #expect(await waitUntil { !session.isClassifying })
        #expect(session.walkStats.snapshot.started == before + 1)
        #expect(session.categories.contains { $0.nodes.contains(first) } && session.categories.contains { $0.nodes.contains(second) })
    }

    @Test func aRefreshRightAfterARestructureIsNotThrottled() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let session = app.session
        let tree = fixture.tree
        session.refreshClassifyInterval = .seconds(30)
        // A full root rescan clears the categories and asks for a walk now; the refresher's
        // `.updated` event follows at once. The categories must not wait for the interval.
        session.restructured()
        #expect(session.categories.isEmpty)
        let added = try Self.addCacheFolder(fixture, 0)
        session.liveTreeChanged(paths: [fixture.path("home/Library/Caches")], generation: tree.generation)
        #expect(await waitUntil(timeout: 10) { !session.isClassifying })
        #expect(!session.categories.isEmpty)
        #expect(session.categories.contains { $0.nodes.contains(added) })
    }

    @Test func liveRefreshKeepsClassificationsOutsideTheChangedPaths() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let session = app.session
        let tree = fixture.tree
        let derived = try fixture.node("home/Library/Developer/Xcode/DerivedData/App-1")
        let downloads = try fixture.node("home/Downloads")
        let notes = try fixture.node("home/Downloads/notes.txt")
        let home = try fixture.node("home")
        for node in [derived, downloads, notes, home] { _ = session.classification(of: node) }
        #expect([derived, downloads, notes, home].allSatisfy { session.cachedClassification(of: $0) != nil })
        let resets = session.cacheResets

        tree.addFile("new.bin", size: 4096, under: downloads)
        session.liveTreeChanged(paths: [tree.path(downloads)], generation: tree.generation)
        #expect(session.cachedClassification(of: derived) != nil, "an entry outside the change is kept")
        #expect(session.cachedClassification(of: downloads) == nil, "the changed folder is dropped")
        #expect(session.cachedClassification(of: notes) == nil, "its contents are dropped")
        #expect(session.cachedClassification(of: home) == nil, "its ancestors are dropped")
        #expect(session.cacheResets == resets, "no full reset")

        // A change nobody reported drops everything (fail safe).
        _ = session.classification(of: downloads)
        tree.addFile("other.bin", size: 1, under: downloads)
        #expect(session.cachedClassification(of: derived) == nil)
        #expect(session.cacheResets == resets + 1)
    }

    @Test func pathsOverlapMatchesAncestorsAndDescendantsOnly() {
        #expect(ScanSessionModel.pathsOverlap("/a/b", "/a/b"))
        #expect(ScanSessionModel.pathsOverlap("/a", "/a/b/c"))
        #expect(ScanSessionModel.pathsOverlap("/a/b/c", "/a"))
        #expect(ScanSessionModel.pathsOverlap("/a/b", "/"))
        #expect(!ScanSessionModel.pathsOverlap("/a/bc", "/a/b"))
        #expect(!ScanSessionModel.pathsOverlap("/a/x", "/a/y"))
    }
}
