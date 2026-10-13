import CoreServices
import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ScanKit

/// Live bug (2026-10-13): on a whole-disk scan the refresher re-scanned `/` over and over. The
/// FSEvents stream was delivered on the queue that also ran the refresh work, so while a refresh
/// ran (seconds to minutes) no events were read, fseventsd dropped them (`UserDropped`), and every
/// drop queued another full rescan of the root. These tests pin the fixes: event intake never
/// waits for refresh work, full rescans of the root are rate limited (and announced), smaller
/// rescans and plain changes keep landing meanwhile, and a steady trickle of events can not
/// postpone a batch forever.
@Suite("TreeRefresher under load", .serialized)
struct RefresherLoadTests {
    /// A clock the test moves by hand (seconds).
    final class ManualClock: Sendable {
        private let value = Mutex<TimeInterval>(1_000)
        var now: TimeInterval { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    static let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs)
    static let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

    static func pendingAnnouncements(_ log: RefresherTests.EventLog) -> [Date?] {
        log.all.compactMap { if case .fullRescanPending(let at) = $0 { return .some(at) } else { return nil } }
    }

    @Test func eventIntakeContinuesWhileARefreshRuns() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("slow/inner/a.bin", size: 4096)
        try fx.file("other/b.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let slowPath = Array(try fx.path("slow").utf8)
        final class Gate: Sendable {
            let entered = Atomic<Bool>(false)
            let released = Atomic<Bool>(false)
        }
        let gate = Gate()
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 0.01, openHook: { path in
            guard path == slowPath else { return }
            gate.entered.store(true, ordering: .releasing)
            let deadline = Date().addingTimeInterval(10)
            while !gate.released.load(ordering: .acquiring) && Date() < deadline { usleep(10_000) }
        })
        defer {
            gate.released.store(true, ordering: .releasing)
            refresher.stop()
        }
        refresher.simulate(path: try fx.path("slow"), flags: Self.mustScan)
        // The refresh is now stuck inside `slow`.
        #expect(await waitUntil(timeout: .seconds(5)) { gate.entered.load(ordering: .acquiring) } != nil)
        let before = refresher.handledEvents.load(ordering: .acquiring)
        refresher.simulate(path: try fx.path("other"), flags: 0)
        let handled = await waitUntil(timeout: .seconds(2)) {
            refresher.handledEvents.load(ordering: .acquiring) > before
        }
        #expect(handled != nil, "an event waited for the running refresh instead of being taken in")
        gate.released.store(true, ordering: .releasing)
    }

    @Test func rootRescansAreRateLimitedCoalescedAndAnnounced() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("x/y/z.bin", size: 4096)
        try fx.file("w/v.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let epoch = tree.structureEpoch
        let clock = ManualClock()
        let refresher = TreeRefresher(
            tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 100, clock: { clock.now }
        )
        let log = RefresherTests.EventLog()
        log.start(refresher)
        defer { refresher.stop() }

        // Right after the scan: the full rescan waits (and says until when), plain changes land.
        try fx.file("w/new.bin", size: 4096)
        refresher.simulate(path: "/", flags: Self.dropped)
        refresher.simulate(path: try fx.path("w"), flags: 0)
        refresher.processNow()
        #expect(tree.structureEpoch == epoch, "the root was rescanned right after the scan")
        #expect(tree.node(atPath: try fx.path("w/new.bin")) != nil)
        #expect(await waitUntil(timeout: .seconds(2)) { Self.pendingAnnouncements(log).first??.timeIntervalSinceNow ?? 0 > 90 } != nil,
                "the pending rescan is announced with its time")

        // More drops before the interval is up change nothing.
        clock.advance(50)
        refresher.simulate(path: "/", flags: Self.dropped)
        refresher.processNow()
        #expect(tree.structureEpoch == epoch)

        // Once it is up, one rescan runs and the announcement is withdrawn.
        clock.advance(51)
        refresher.processNow()
        #expect(tree.structureEpoch == epoch + 1)
        #expect(await waitUntil(timeout: .seconds(2)) { Self.pendingAnnouncements(log).last == .some(nil) } != nil)

        // Drops right after it are coalesced into one later rescan.
        for _ in 0..<3 {
            refresher.simulate(path: "/", flags: Self.dropped)
            refresher.processNow()
        }
        #expect(tree.structureEpoch == epoch + 1)
        clock.advance(101)
        refresher.processNow()
        refresher.processNow()
        #expect(tree.structureEpoch == epoch + 2, "drops were not coalesced")
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
    }

    @Test func aPostponedRootRescanRunsByItself() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("x/y/z.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let epoch = tree.structureEpoch
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 0.5)
        defer { refresher.stop() }
        refresher.simulate(path: "/", flags: Self.dropped)
        refresher.processNow()
        #expect(await waitUntil(timeout: .seconds(10)) { tree.structureEpoch == epoch + 1 } != nil, "the postponed root rescan never ran")
    }

    @Test func refreshNowBypassesTheRateLimit() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("x/y/z.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let epoch = tree.structureEpoch
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 1_000)
        defer { refresher.stop() }
        refresher.injectDroppedEvents()
        refresher.processNow()
        #expect(tree.structureEpoch == epoch)
        refresher.rescanRootNow()
        #expect(await waitUntil(timeout: .seconds(10)) { tree.structureEpoch == epoch + 1 } != nil)
    }

    @Test func mustScanSubDirsUnderAPostponedRootRescanStillRefreshes() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/b/c/old.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let epoch = tree.structureEpoch
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 1_000)
        defer { refresher.stop() }
        try fx.file("a/b/c/new.bin", size: 8192)
        refresher.simulate(path: "/", flags: Self.dropped)
        refresher.simulate(path: try fx.path("a"), flags: Self.mustScan)
        refresher.processNow()
        #expect(tree.structureEpoch == epoch, "the root rescan is still postponed")
        #expect(tree.node(atPath: try fx.path("a/b/c/new.bin")) != nil, "the small subtree was not rescanned")
    }

    @Test func largeSubtreeRescansStayRateLimitedUnderAPostponedRootRescan() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        for index in 0..<6 { try fx.file("big/d\(index)/f.bin", size: 4096) }
        try fx.file("small/a.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let epoch = tree.structureEpoch
        // `big` holds 12 items, over the lowered threshold; `small` does not.
        let refresher = TreeRefresher(
            tree: tree, root: fx.root, latency: 1, idleDelay: 3, minimumRootRescanInterval: 1_000, largeSubtreeNodes: 5
        )
        defer { refresher.stop() }
        try fx.file("big/d0/deep/new.bin", size: 8192)
        let generation = tree.generation
        refresher.simulate(path: "/", flags: Self.dropped)
        for _ in 0..<3 {
            refresher.simulate(path: try fx.path("big"), flags: Self.mustScan)
            refresher.processNow()
        }
        #expect(tree.structureEpoch == epoch)
        #expect(tree.node(atPath: try fx.path("big/d0/deep/new.bin")) == nil, "the large subtree was rescanned at once")
        #expect(tree.generation == generation)
    }

    @Test func eventsAfterTheBatchCapDoNotPileUpBatches() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("slow/a.bin", size: 4096)
        try fx.file("busy/b.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let slowPath = Array(try fx.path("slow").utf8)
        final class Gate: Sendable {
            let entered = Atomic<Bool>(false)
            let released = Atomic<Bool>(false)
        }
        let gate = Gate()
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 0.05, maximumBatchDelay: 0.1, openHook: { path in
            guard path == slowPath, !gate.released.load(ordering: .acquiring) else { return }
            gate.entered.store(true, ordering: .releasing)
            let deadline = Date().addingTimeInterval(10)
            while !gate.released.load(ordering: .acquiring) && Date() < deadline { usleep(10_000) }
        })
        defer {
            gate.released.store(true, ordering: .releasing)
            refresher.stop()
        }
        // A batch gets stuck in a slow listing, well past the cap, while events keep coming.
        refresher.simulate(path: try fx.path("slow"), flags: 0)
        #expect(await waitUntil(timeout: .seconds(5)) { gate.entered.load(ordering: .acquiring) } != nil)
        let busy = try fx.path("busy")
        for _ in 0..<200 {
            refresher.simulate(path: busy, flags: 0)
            usleep(2_000)
        }
        usleep(300_000)
        gate.released.store(true, ordering: .releasing)
        try await Task.sleep(for: .seconds(1))
        let runs = refresher.processRuns.load(ordering: .acquiring)
        #expect(runs <= 4, "\(runs) batches were queued for one stuck batch")
    }

    /// The harness's SIGBUS: every trace call used to wrap the stored sink in one more
    /// reabstraction thunk, and releasing the 10,000-deep chain overflowed a thread's stack.
    @Test func manyTraceLinesThenDeinitOnAnOrdinaryThreadStack() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        final class Count: Sendable { let value = Atomic<Int>(0) }
        let count = Count()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                do {
                    let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 3)
                    refresher.setTrace { _ in count.value.wrappingAdd(1, ordering: .relaxed) }
                    for index in 0..<10_000 { refresher.trace("line \(index)") }
                }
                done.resume()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(count.value.load(ordering: .relaxed) == 10_000)
    }

    @Test func aSteadyTrickleOfEventsStillGetsProcessed() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("busy/a.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let refresher = TreeRefresher(tree: tree, root: fx.root, latency: 1, idleDelay: 1, maximumBatchDelay: 2)
        defer { refresher.stop() }
        try fx.file("busy/new.bin", size: 8192)
        let busy = try fx.path("busy")
        // An event every 0.2 s: the 1 s quiet spell never comes.
        let trickle = Task.detached {
            while !Task.isCancelled {
                refresher.simulate(path: busy, flags: 0)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { trickle.cancel() }
        let landed = await waitUntil(timeout: .seconds(6)) { tree.node(atPath: try! fx.path("busy/new.bin")) != nil }
        #expect(landed != nil, "the batch waited for a quiet spell that never came")
    }
}
