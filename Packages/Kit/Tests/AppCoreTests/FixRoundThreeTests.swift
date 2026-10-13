import Dispatch
import Foundation
import ScanKit
import Synchronization
import Testing
import TestSupport
@testable import AppCore

@Suite("Process rendezvous and late classification", .serialized)
@MainActor
struct FixRoundThreeTests {
    /// Exit and stdout EOF arrive on two threads at once, in either order: exactly one delivery.
    @Test nonisolated func rendezvousDeliversExactlyOnce() {
        let iterations = 5_000
        let deliveries = Mutex([Int](repeating: 0, count: iterations))
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let rendezvous = ProcessRendezvous { _, _, _ in deliveries.withLock { $0[index] += 1 } }
            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            for side in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    start.wait()
                    if side == 0 { rendezvous.exited(0) } else { rendezvous.output(Data("a\n".utf8)) }
                    group.leave()
                }
            }
            start.signal()
            start.signal()
            group.wait()
            // Late extra signals never deliver again.
            rendezvous.exited(1)
            rendezvous.failed()
        }
        let counts = deliveries.withLock { $0 }
        #expect(counts.allSatisfy { $0 == 1 }, "\(counts.filter { $0 != 1 }.count) runs delivered other than once")
    }

    @Test nonisolated func rendezvousReportsTimeoutAndFailure() {
        let seen = Mutex<[(Int32, Bool)]>([])
        let timed = ProcessRendezvous { _, status, timedOut in seen.withLock { $0.append((status, timedOut)) } }
        timed.markTimedOut()
        timed.exited(15)
        timed.output(Data())
        let failed = ProcessRendezvous { _, status, timedOut in seen.withLock { $0.append((status, timedOut)) } }
        failed.failed()
        let result = seen.withLock { $0 }
        #expect(result.count == 2)
        #expect(result.first?.0 == 15 && result.first?.1 == true)
        #expect(result.last?.0 == -1)
    }

    /// The real tmutil, several runs at once: no crash, a count or nil.
    @Test nonisolated func tmutilRunsConcurrentlyWithoutCrashing() async {
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<6 { group.addTask { await SnapshotCounter.tmutil("/") } }
            for await value in group { #expect(value == nil || value! >= 0) }
        }
    }

    @Test func classifiedDangerousLargeFolderBuildsItsListOffTheMainActor() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = fixture.tree
        let home = try fixture.node("home")
        var inode: UInt64 = 80_000_000
        let big = tree.addDirectory("Big", under: home, identity: FileIdentity(device: 1, inode: inode))
        for index in 0..<3_000 {
            inode += 1
            tree.addDirectory("d\(index)", under: big, identity: FileIdentity(device: 1, inode: inode))
        }
        inode += 1
        let library = tree.addDirectory("Holiday.photoslibrary", under: big, flags: .package, identity: FileIdentity(device: 1, inode: inode))
        _ = tree.size(tree.root)
        let app = try await AppHarness(fixture: fixture)
        let session = app.session
        let revision = session.classificationRevision
        session.selection = big
        #expect(await waitUntil { session.classificationRevision != revision })
        #expect(session.cachedClassification(of: big)?.risk == .dangerous)
        let result = await app.model.cleanup.queue(tree.summary(of: big), source: .user)
        guard case .added = result else { Issue.record("not added: \(result)"); return }
        let item = try #require(app.model.cleanup.queue.first)
        #expect(app.model.cleanup.nestedDangerousPaths(of: item) == [tree.path(library)])
    }

    @Test func staleWalkForAnOldTreeRestartsTheShownFolder() async throws {
        // A large folder on disk, so both snapshots hold it at the same node id.
        let fixture = try HomeFixture { fx in
            for index in 0..<2_500 { _ = try fx.dir("home/Big/d\(index)") }
        }
        defer { fixture.tearDown() }
        let tree = EpochTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let session = app.session
        let big = try #require(tree.node(atPath: fixture.path("home/Big")))
        #expect(tree.descendantCount(big) > ScanSessionModel.synchronousClassificationLimit)
        session.selection = big
        // A restructure lands while that walk is in flight: same id, new structure epoch.
        tree.adopt(try InMemoryTree.snapshot(of: fixture.root))
        session.restructured()
        #expect(session.selection == big)
        #expect(await waitUntil(timeout: 20) { session.cachedClassification(of: big) != nil }, "the shown folder is classified again for the new structure")
    }
}
