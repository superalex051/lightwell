import CleanupKit
import Dispatch
import Foundation
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Label of the dispatch queue the caller runs on ("com.apple.root...cooperative" on Swift's
/// cooperative pool).
func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// A Trash that records which queue each move runs on.
final class LabelRecordingTrash: TrashProviding, @unchecked Sendable {
    let inner: FixtureTrash
    private let lock = NSLock()
    private var recorded: [String] = []

    init(_ inner: FixtureTrash) { self.inner = inner }

    var labels: [String] { lock.withLock { recorded } }

    func trash(_ url: URL) throws -> URL? {
        let label = currentQueueLabel()
        lock.withLock { recorded.append(label) }
        return try inner.trash(url)
    }
}

/// A tree that records the queue of every off-main read (the walks).
final class LabelRecordingTree: RemovableTree, @unchecked Sendable {
    let inner: InMemoryTree
    private let lock = NSLock()
    private var recorded = Set<String>()

    init(_ inner: InMemoryTree) { self.inner = inner }

    var labels: Set<String> { lock.withLock { recorded } }

    private func note() {
        guard !Thread.isMainThread else { return }
        let label = currentQueueLabel()
        lock.withLock { _ = recorded.insert(label) }
    }

    var root: NodeID { inner.root }
    var generation: UInt64 { inner.generation }
    func name(_ id: NodeID) -> String { inner.name(id) }
    func path(_ id: NodeID) -> String { inner.path(id) }
    func size(_ id: NodeID) -> UInt64 { inner.size(id) }
    func flags(_ id: NodeID) -> NodeFlags { inner.flags(id) }
    func parent(_ id: NodeID) -> NodeID? { inner.parent(id) }
    func children(_ id: NodeID) -> [NodeID] {
        note()
        return inner.children(id)
    }
    func descendantCount(_ id: NodeID) -> UInt32 { inner.descendantCount(id) }
    func node(atPath path: String) -> NodeID? { inner.node(atPath: path) }
    func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 { inner.reclaimableBytes(id, ifAlsoRemoving: others) }
    func identity(_ id: NodeID) -> FileIdentity? { inner.identity(id) }
    func removeSubtree(_ id: NodeID) { inner.removeSubtree(id) }
}

/// Work the person waits for (a cleanup run, the walk behind Add to Cleanup) runs on its own
/// dispatch queue, never on Swift's cooperative pool, where long walks of a whole-disk tree can
/// hold every thread (before the fix both waited 8.0 s with the pool busy). Checked by the queue
/// the work runs on, so the result does not depend on how busy the test process is.
@Suite("Cleanup work runs off the cooperative pool", .serialized)
@MainActor
struct CleanupQueueLabelTests {
    @Test func aCleanupRunWorksOnItsOwnQueue() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let trash = LabelRecordingTrash(FixtureTrash(root: fixture.root))
        let model = AppModel(
            cleanup: CleanupModel(configuration: CleanupConfiguration(home: fixture.home, trash: trash, allowedRoot: fixture.root, testTrash: trash.inner)),
            settings: AppSettings(assistantConsentAccepted: false),
            home: fixture.home
        )
        model.connect(assistantServices: nil, snapshots: .disabled, metadata: .none)
        let session = ScanSessionModel(target: .folder(fixture.root), tree: fixture.tree, services: fixture.services())
        model.adopt(session)
        #expect(await waitUntil { session.isFinished })
        let node = try fixture.node("home/Downloads/old-installer.dmg")
        guard case .added = model.cleanup.add(fixture.tree.summary(of: node), source: .user) else { Issue.record("not queued"); return }
        await model.cleanup.run(mode: .trash)
        #expect(model.cleanup.lastReport?.succeeded.count == 1)
        #expect(trash.labels == ["com.alexluncan.lightwell.cleanup.run"], "the run worked on \(trash.labels)")
    }

    @Test func addingALargeFolderWalksOnItsOwnQueue() async throws {
        let (fixture, big) = try await LiveChurnTests.bigFixture()
        defer { fixture.tearDown() }
        let tree = LabelRecordingTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        #expect(app.session.cachedClassification(of: big) == nil, "not classified yet, so the add walks")
        let before = tree.labels
        let result = await app.model.cleanup.queue(tree.summary(of: big), source: .user)
        guard case .added = result else { Issue.record("not added: \(result)"); return }
        let walk = tree.labels.subtracting(before)
        #expect(walk.contains("com.alexluncan.lightwell.cleanup.walk"), "the walk ran on \(walk)")
        #expect(!walk.contains { $0.contains("cooperative") }, "the walk ran on the cooperative pool: \(walk)")
    }
}
