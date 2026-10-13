import CleanupKit
import Foundation
import RulesKit
import ScanKit
import Synchronization
import Testing
import TestSupport
@testable import AppCore

/// A tree that keeps changing somewhere else: every read of `generation` sees a newer one, the
/// way a live refresh of a whole-disk scan bumps it every few seconds for unrelated folders.
final class ChurningTree: RemovableTree, @unchecked Sendable {
    let inner: InMemoryTree
    private let counter = Atomic<UInt64>(0)

    init(_ inner: InMemoryTree) {
        self.inner = inner
    }

    var root: NodeID { inner.root }
    var generation: UInt64 { counter.wrappingAdd(1, ordering: .relaxed).newValue }
    func name(_ id: NodeID) -> String { inner.name(id) }
    func path(_ id: NodeID) -> String { inner.path(id) }
    func size(_ id: NodeID) -> UInt64 { inner.size(id) }
    func flags(_ id: NodeID) -> NodeFlags { inner.flags(id) }
    func parent(_ id: NodeID) -> NodeID? { inner.parent(id) }
    func children(_ id: NodeID) -> [NodeID] { inner.children(id) }
    func descendantCount(_ id: NodeID) -> UInt32 { inner.descendantCount(id) }
    func node(atPath path: String) -> NodeID? { inner.node(atPath: path) }
    func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 { inner.reclaimableBytes(id, ifAlsoRemoving: others) }
    func identity(_ id: NodeID) -> FileIdentity? { inner.identity(id) }
    func removeSubtree(_ id: NodeID) { inner.removeSubtree(id) }
}

/// Live bugs on a whole-disk scan (2026-10-13): Add to Cleanup sometimes did nothing while the
/// live refresh kept changing the tree.
@Suite("Cleanup under live refresh churn", .serialized)
@MainActor
struct LiveChurnTests {
    /// Adds 3,000 folders under `home/Big`, so adding it walks off the main actor.
    nonisolated static func addBigFolder(_ tree: InMemoryTree, under home: NodeID) -> NodeID {
        var inode: UInt64 = 90_000_000
        let big = tree.addDirectory("Big", under: home, identity: FileIdentity(device: 1, inode: inode))
        for index in 0..<3_000 {
            inode += 1
            let folder = tree.addDirectory("d\(index)", under: big, identity: FileIdentity(device: 1, inode: inode))
            inode += 1
            tree.addFile("f.bin", size: 4096, under: folder, identity: FileIdentity(device: 1, inode: inode))
        }
        _ = tree.size(tree.root)
        return big
    }

    /// A home fixture with `home/Big`, built off the main actor (building it there would stall the
    /// main-actor timers of suites running in parallel).
    static func bigFixture() async throws -> (HomeFixture, NodeID) {
        try await Task.detached {
            let fixture = try HomeFixture()
            let home = try #require(fixture.tree.node(atPath: fixture.path("home")))
            return (fixture, addBigFolder(fixture.tree, under: home))
        }.value
    }

    @Test func queueingALargeFolderSurvivesRefreshesElsewhere() async throws {
        let (fixture, big) = try await Self.bigFixture()
        defer { fixture.tearDown() }
        let tree = ChurningTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        #expect(app.session.cachedClassification(of: big) == nil, "not classified yet, so the add walks")

        let result = await app.model.cleanup.queue(tree.summary(of: big), source: .user)
        guard case .added = result else { Issue.record("refused while unrelated folders changed: \(result)"); return }
        #expect(app.model.cleanup.queue.map(\.path) == [tree.path(big)])
    }

    @Test func addRightAfterARootRescanIsNotRefused() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = EpochTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        // The refresher swapped in a full rescan; the session has not handled `.restructured` yet.
        tree.adopt(try InMemoryTree.snapshot(of: fixture.root))
        let path = fixture.path("home/Downloads/old-installer.dmg")
        let node = try #require(tree.node(atPath: path))

        let result = app.model.cleanup.add(tree.summary(of: node), source: .user)
        guard case .added = result else { Issue.record("refused right after a root rescan: \(result)"); return }
        #expect(app.model.cleanup.queue.first?.nodeID == node, "queued with the id of the current structure")
        let other = try #require(tree.node(atPath: fixture.path("home/Downloads/notes.txt")))
        let queued = await app.model.cleanup.queue(tree.summary(of: other), source: .user)
        guard case .added = queued else { Issue.record("refused right after a root rescan (async path): \(queued)"); return }
    }

    @Test func aChangeInsideTheItemDuringItsWalkIsWalkedAgain() async throws {
        let (fixture, big) = try await Self.bigFixture()
        defer { fixture.tearDown() }
        // While the first walk runs, a Photos library appears inside the folder.
        let tree = ChangingDuringWalkTree(fixture.tree, folder: big)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let result = await app.model.cleanup.queue(tree.summary(of: big), source: .user)
        guard case .added = result else { Issue.record("not added: \(result)"); return }
        #expect(tree.changed, "the change happened during the walk")
        let item = try #require(app.model.cleanup.queue.first)
        #expect(item.risk == .dangerous, "the result of the outdated walk was used")
        #expect(!item.isSelected)
        #expect(app.model.cleanup.nestedDangerousPaths(of: item).contains { $0.hasSuffix("/Holiday.photoslibrary") })
    }
}

/// Refusals that a second try can fix (the item kept changing while it was checked) are marked
/// retryable; refusals for items that are gone are not (the UI keeps the accurate text for them).
@Suite("Retryable Add refusals", .serialized)
@MainActor
struct RetryableRefusalTests {
    @Test func anItemThatKeptChangingDuringItsWalkIsRetryable() async throws {
        let (fixture, big) = try await LiveChurnTests.bigFixture()
        defer { fixture.tearDown() }
        let tree = GrowingFolderTree(fixture.tree, folder: big)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let result = await app.model.cleanup.queue(tree.summary(of: big), source: .user)
        #expect(result == .blocked(.changedSinceScan))
        #expect(app.model.cleanup.lastAddRetryable, "pressing Add again can work")
    }

    @Test func aVanishedItemIsNotRetryable() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let node = try fixture.node("home/Downloads/notes.txt")
        let summary = fixture.tree.summary(of: node)
        fixture.tree.markMissing(node)
        let result = await app.model.cleanup.queue(summary, source: .user)
        #expect(result == .blocked(.changedSinceScan))
        #expect(!app.model.cleanup.lastAddRetryable, "a missing item does not come back by trying again")
    }
}

/// A folder whose size changes on every read from the main actor, as if the live refresh kept
/// updating it while it was checked.
final class GrowingFolderTree: RemovableTree, @unchecked Sendable {
    let inner: InMemoryTree
    let folder: NodeID
    private let lock = NSLock()
    private var reads: UInt64 = 0

    init(_ inner: InMemoryTree, folder: NodeID) {
        self.inner = inner
        self.folder = folder
    }

    var root: NodeID { inner.root }
    var generation: UInt64 { inner.generation }
    func name(_ id: NodeID) -> String { inner.name(id) }
    func path(_ id: NodeID) -> String { inner.path(id) }
    func size(_ id: NodeID) -> UInt64 {
        guard id == folder, Thread.isMainThread else { return inner.size(id) }
        let extra = lock.withLock { () -> UInt64 in
            reads += 1
            return reads * 4096
        }
        return inner.size(id) + extra
    }
    func flags(_ id: NodeID) -> NodeFlags { inner.flags(id) }
    func parent(_ id: NodeID) -> NodeID? { inner.parent(id) }
    func children(_ id: NodeID) -> [NodeID] { inner.children(id) }
    func descendantCount(_ id: NodeID) -> UInt32 { inner.descendantCount(id) }
    func node(atPath path: String) -> NodeID? { inner.node(atPath: path) }
    func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 { inner.reclaimableBytes(id, ifAlsoRemoving: others) }
    func identity(_ id: NodeID) -> FileIdentity? { inner.identity(id) }
    func removeSubtree(_ id: NodeID) { inner.removeSubtree(id) }
}

/// Adds a Photos library inside `folder` during the Add walk, right after it listed `folder`.
final class ChangingDuringWalkTree: RemovableTree, @unchecked Sendable {
    let inner: InMemoryTree
    let folder: NodeID
    private let lock = NSLock()
    private var done = false
    private var listedFolder = false

    init(_ inner: InMemoryTree, folder: NodeID) {
        self.inner = inner
        self.folder = folder
    }

    var changed: Bool { lock.withLock { done } }

    var root: NodeID { inner.root }
    var generation: UInt64 { inner.generation }
    func name(_ id: NodeID) -> String { inner.name(id) }
    func path(_ id: NodeID) -> String { inner.path(id) }
    func size(_ id: NodeID) -> UInt64 { inner.size(id) }
    func flags(_ id: NodeID) -> NodeFlags { inner.flags(id) }
    func parent(_ id: NodeID) -> NodeID? { inner.parent(id) }
    func children(_ id: NodeID) -> [NodeID] {
        // Only during the walk behind Add to Cleanup (not the categories walk), and only after
        // that walk has listed the folder: the first walk can not see the library, only a second
        // walk (started because the item's stamp changed) can.
        if currentQueueLabel() == "com.alexluncan.lightwell.cleanup.walk" {
            let insertNow = lock.withLock { () -> Bool in
                if id == folder {
                    listedFolder = true
                    return false
                }
                guard listedFolder, !done else { return false }
                done = true
                return true
            }
            if insertNow {
                let library = inner.addDirectory("Holiday.photoslibrary", under: folder, flags: .package, identity: FileIdentity(device: 1, inode: 95_000_000))
                inner.addFile("db", size: 4096, under: library, identity: FileIdentity(device: 1, inode: 95_000_001))
                _ = inner.size(inner.root)
            }
        }
        return inner.children(id)
    }
    func descendantCount(_ id: NodeID) -> UInt32 { inner.descendantCount(id) }
    func node(atPath path: String) -> NodeID? { inner.node(atPath: path) }
    func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 { inner.reclaimableBytes(id, ifAlsoRemoving: others) }
    func identity(_ id: NodeID) -> FileIdentity? { inner.identity(id) }
    func removeSubtree(_ id: NodeID) { inner.removeSubtree(id) }
}
