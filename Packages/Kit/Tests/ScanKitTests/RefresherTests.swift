import CoreServices
import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ScanKit

/// PLAN 5.1 "Refresh": FSEvents-driven updates inside a fixture.
@Suite("TreeRefresher", .serialized)
struct RefresherTests {
    /// Collects refresher events in the background.
    final class EventLog: Sendable {
        let events = Mutex<[RefreshEvent]>([])
        func start(_ refresher: TreeRefresher) {
            let stream = refresher.events
            Task.detached { [self] in
                for await event in stream { events.withLock { $0.append(event) } }
            }
        }
        var all: [RefreshEvent] { events.withLock { $0 } }
    }

    @Test func createDeleteRenameAndMoveOutAreReflectedWithinFiveSeconds() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("scan/a/one.bin", size: 4096)
        try fx.file("scan/b/two.bin", size: 8192)
        try fx.file("scan/moveme/inner.bin", size: 16_384)
        try fx.dir("outside")
        let root = try fx.url("scan")
        let tree = try await scanTree(root)
        let refresher = TreeRefresher(tree: tree, root: root)
        let log = EventLog()
        log.start(refresher)
        refresher.start()
        defer { refresher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let budget: Duration = .seconds(5)
        var timings: [String: Duration] = [:]

        // Create.
        try fx.file("scan/a/new.bin", size: 100_000)
        let created = await waitUntil(timeout: budget) { tree.node(atPath: try! fx.path("scan/a/new.bin")) != nil }
        timings["create"] = created
        #expect(created != nil, "create not reflected")

        // Delete.
        unlink(try fx.path("scan/b/two.bin"))
        let deleted = await waitUntil(timeout: budget) { tree.node(atPath: try! fx.path("scan/b/two.bin")) == nil }
        timings["delete"] = deleted
        #expect(deleted != nil, "delete not reflected")

        // Rename a file and a folder (the folder keeps its node and subtree).
        let movemeID = try #require(tree.node(atPath: try fx.path("scan/moveme")))
        rename(try fx.path("scan/a/one.bin"), try fx.path("scan/a/renamed.bin"))
        rename(try fx.path("scan/moveme"), try fx.path("scan/moved"))
        let renamed = await waitUntil(timeout: budget) {
            tree.node(atPath: try! fx.path("scan/a/renamed.bin")) != nil && tree.node(atPath: try! fx.path("scan/moved")) != nil
        }
        timings["rename"] = renamed
        #expect(renamed != nil, "rename not reflected")
        #expect(tree.node(atPath: try fx.path("scan/a/one.bin")) == nil)
        #expect(tree.node(atPath: try fx.path("scan/moved")) == movemeID)

        // Move out of the scanned root.
        rename(try fx.path("scan/moved"), try fx.path("outside/moved"))
        let movedOut = await waitUntil(timeout: budget) { tree.node(atPath: try! fx.path("scan/moved")) == nil }
        timings["moveOut"] = movedOut
        #expect(movedOut != nil, "move-out not reflected")

        // New folder with content is scanned fully.
        try fx.file("scan/fresh/deep/er/file.bin", size: 40_000)
        let fresh = await waitUntil(timeout: budget) { tree.node(atPath: try! fx.path("scan/fresh/deep/er/file.bin")) != nil }
        timings["newFolder"] = fresh
        #expect(fresh != nil, "new folder not reflected")

        expectMatchesOracle(tree, try Oracle.walk(root))
        #expect(log.all.contains { if case .updated = $0 { return true } else { return false } })
        print("refresh timings: \(timings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
    }

    @Test func mustScanSubDirsTriggersSubtreeRescan() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/b/c/old.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        // Not started: only synthetic events reach it.
        let refresher = TreeRefresher(tree: tree, root: fx.root)
        defer { refresher.stop() }
        try fx.file("a/b/c/new.bin", size: 8192)

        // A plain event on `a` re-lists only `a`, so the deep change stays unseen.
        refresher.simulate(path: try fx.path("a"), flags: 0)
        refresher.processNow()
        #expect(tree.node(atPath: try fx.path("a/b/c/new.bin")) == nil)

        refresher.simulate(path: try fx.path("a"), flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
        refresher.processNow()
        #expect(tree.node(atPath: try fx.path("a/b/c/new.bin")) != nil)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
    }

    @Test func droppedEventsRescanTheRoot() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("x/y/z.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        // No rate limit here (RefresherLoadTests covers it).
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 0)
        defer { refresher.stop() }
        try fx.file("x/y/added.bin", size: 4096)
        refresher.simulate(path: "/", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped))
        refresher.processNow()
        #expect(tree.node(atPath: try fx.path("x/y/added.bin")) != nil)
    }

    @Test func rootChangedMarksTheScanStale() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let tree = try await scanTree(fx.root)
        let refresher = TreeRefresher(tree: tree, root: fx.root)
        let log = EventLog()
        log.start(refresher)
        refresher.simulate(path: fx.root.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged))
        refresher.processNow()
        let seen = await waitUntil(timeout: .seconds(2)) { log.all.contains(.stale(reason: .rootChanged)) }
        #expect(seen != nil)
        refresher.stop()
    }

    @Test func unchangedFoldersAndSuppressedPathsKeepTheGeneration() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("keep/a.bin", size: 4096)
        try fx.file("gone/b.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let refresher = TreeRefresher(tree: tree, root: fx.root)
        defer { refresher.stop() }
        let generation = tree.generation
        refresher.simulate(path: try fx.path("keep"), flags: 0)
        refresher.processNow()
        #expect(tree.generation == generation)

        // Our own deletion: the tree is updated first, the event is then ignored.
        let gone = try #require(tree.node(atPath: try fx.path("gone/b.bin")))
        tree.removeSubtree(gone)
        refresher.suppress([try fx.path("gone/b.bin"), try fx.path("gone")])
        unlink(try fx.path("gone/b.bin"))
        let afterRemoval = tree.generation
        refresher.simulate(path: try fx.path("gone"), flags: 0)
        refresher.processNow()
        #expect(tree.generation == afterRemoval)
    }

    @Test func excludedFoldersStayExcluded() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("keep/a.bin", size: 4096)
        try fx.file("skip/big.bin", size: 64 * 1024)
        let skip = try fx.path("skip")
        let tree = try await scanTree(fx.root, excluded: [skip])
        #expect(tree.node(atPath: skip) == nil)
        let refresher = TreeRefresher(tree: tree, root: fx.root)
        defer { refresher.stop() }
        // A change in the parent of the excluded folder, and inside it.
        try fx.file("new.bin", size: 4096)
        try fx.file("skip/more.bin", size: 4096)
        refresher.simulate(path: fx.root.path, flags: 0)
        refresher.simulate(path: skip, flags: 0)
        refresher.processNow()
        #expect(tree.node(atPath: try fx.path("new.bin")) != nil)
        #expect(tree.node(atPath: skip) == nil)
        // A full rescan of the root honors the exclusion too.
        refresher.simulate(path: fx.root.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
        refresher.processNow()
        #expect(tree.node(atPath: skip) == nil)
        #expect(tree.node(atPath: try fx.path("keep/a.bin")) != nil)
    }

    @Test func fullRootRescanSwapsInTheNewTree() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        for index in 0..<50 { try fx.file("d\(index % 5)/f\(index).bin", size: 4096) }
        let tree = try await scanTree(fx.root)
        let slots = tree.nodeCapacity
        let epoch = tree.structureEpoch
        // No rate limit here (RefresherLoadTests covers it).
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 0)
        let log = EventLog()
        log.start(refresher)
        defer { refresher.stop() }
        try fx.file("d0/added.bin", size: 8192)
        for _ in 0..<3 {
            refresher.simulate(path: "/", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
            refresher.processNow()
        }
        #expect(tree.structureEpoch == epoch + 3)
        // Swapped, not grafted: the arena does not grow with each full rescan.
        #expect(tree.nodeCapacity <= slots + 1)
        #expect(tree.node(atPath: try fx.path("d0/added.bin")) != nil)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        // Each swap is signalled distinctly, so holders re-resolve their node ids.
        let restructured = await waitUntil(timeout: .seconds(2)) {
            log.all.filter { if case .restructured = $0 { return true } else { return false } }.count == 3
        }
        #expect(restructured != nil)
        #expect(log.all.contains(.restructured(epoch: epoch + 3)))
    }

    @Test func stopReturnsQuicklyDuringASlowRescan() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/b/c.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let slowPath = Array(try fx.path("a").utf8)
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 0.01, openHook: { path in
            if path == slowPath { Thread.sleep(forTimeInterval: 3) }
        })
        refresher.simulate(path: try fx.path("a"), flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
        // Let the rescan start and block inside the slow folder.
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        refresher.stop()
        let elapsed = clock.now - start
        #expect(elapsed < .milliseconds(50), "stop took \(elapsed)")
    }

    @Test func stuckListingIsFlaggedNotResponding() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("share/x.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let sharePath = Array(try fx.path("share").utf8)
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, listingTimeout: 0.2, openHook: { path in
            if path == sharePath { Thread.sleep(forTimeInterval: 1) }
        })
        defer { refresher.stop() }
        refresher.simulate(path: try fx.path("share"), flags: 0)
        refresher.processNow()
        let share = try #require(tree.node(atPath: try fx.path("share")))
        #expect(tree.flags(share).contains(.notResponding))
        #expect(tree.unresponsiveFolders.contains(share))
    }

    @Test func refreshHandsHardLinkAndCloneBytesOver() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/primary.bin", size: 32 * 1024)
        try fx.hardLink("b/secondary.bin", to: "a/primary.bin")
        try fx.file("c/src.bin", size: 64 * 1024)
        var clones = true
        do { try fx.clone("c/0-copy.bin", of: "c/src.bin") } catch { clones = false }
        let tree = try await scanTree(fx.root, countClonesOnce: true)
        let secondary = try #require(tree.node(atPath: try fx.path("b/secondary.bin")))
        #expect(tree.flags(secondary).contains(.hardLinkSecondary))
        let refresher = TreeRefresher(tree: tree, root: fx.root)
        defer { refresher.stop() }

        unlink(try fx.path("a/primary.bin"))
        if clones { unlink(try fx.path("c/0-copy.bin")) }
        refresher.simulate(path: try fx.path("a"), flags: 0)
        refresher.simulate(path: try fx.path("c"), flags: 0)
        refresher.processNow()
        #expect(tree.node(atPath: try fx.path("a/primary.bin")) == nil)
        #expect(!tree.flags(secondary).contains(.hardLinkSecondary))
        #expect(tree.size(secondary) > 0)
        if clones {
            let src = try #require(tree.node(atPath: try fx.path("c/src.bin")))
            #expect(tree.size(src) >= 64 * 1024)
        }
        // Like the oracle (which counts every clone in full) now that no clone is left.
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
    }

    @Test func unresponsiveFoldersTrackRefreshStallsAndClear() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("old/a.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let stallPath = Array(try fx.path("fresh/slow").utf8)
        final class Counter: Sendable { let value = Atomic<Int>(0) }
        let stalls = Counter()
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, listingTimeout: 0.3, openHook: { path in
            // Only the first visit stalls.
            if path == stallPath, stalls.value.wrappingAdd(1, ordering: .relaxed).oldValue == 0 { Thread.sleep(forTimeInterval: 1) }
        })
        defer { refresher.stop() }
        try fx.file("fresh/fast/b.bin", size: 4096)
        try fx.file("fresh/slow/c.bin", size: 4096)
        // The new folder is scanned by a refresh subscan, in which `slow` stalls.
        refresher.simulate(path: fx.root.path, flags: 0)
        refresher.processNow()
        let slow = try #require(tree.node(atPath: try fx.path("fresh/slow")))
        #expect(tree.flags(slow).contains(.notResponding))
        #expect(tree.unresponsiveFolders == [slow])
        // Flagging again does not duplicate it.
        tree.markNotResponding(slow)
        #expect(tree.unresponsiveFolders == [slow])
        // A later refresh that lists it clears the flag and the entry.
        refresher.simulate(path: try fx.path("fresh/slow"), flags: 0)
        refresher.processNow()
        #expect(!tree.flags(slow).contains(.notResponding))
        #expect(tree.unresponsiveFolders.isEmpty)
        #expect(tree.node(atPath: try fx.path("fresh/slow/c.bin")) != nil)
    }
}
