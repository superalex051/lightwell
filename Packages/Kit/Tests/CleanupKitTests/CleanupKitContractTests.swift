import Foundation
import Testing
@testable import CleanupKit
import RulesKit
import ScanKit
import TestSupport

@Suite("CleanupQueue")
struct CleanupKitContractTests {
    func item(_ path: String, bytes: UInt64 = 10, risk: Risk = .safe, source: QueueSource = .user, selected: Bool = true) -> QueueItem {
        QueueItem(path: path, bytes: bytes, freesAbout: bytes, risk: risk, source: source, isSelected: selected)
    }

    @Test func queueRejectsDuplicatesAndChildren() {
        var queue = CleanupQueue()
        let parent = item("/fixture/a")
        guard case .added = queue.add(parent) else { Issue.record("parent not added"); return }
        #expect(queue.add(item("/fixture/a/b", bytes: 5)) == .coveredByParent("/fixture/a"))
        #expect(queue.add(parent) == .alreadyQueued(parent.id))
        #expect(queue.add(item("/fixture/a/")) == .alreadyQueued(parent.id))
        #expect(queue.totalBytes == 10)
        // A sibling with a shared name prefix is not a child.
        guard case .added = queue.add(item("/fixture/ab")) else { Issue.record("sibling not added"); return }
    }

    @Test func addingAParentAbsorbsQueuedChildren() {
        var queue = CleanupQueue()
        queue.add(item("/f/a/one", bytes: 1))
        queue.add(item("/f/a/two/three", bytes: 2))
        queue.add(item("/f/b", bytes: 4))
        let parent = item("/f/a", bytes: 100)
        #expect(queue.add(parent) == .added(parent.id))
        #expect(queue.items.map(\.path).sorted() == ["/f/a", "/f/b"])
        #expect(queue.totalBytes == 104)
    }

    @Test func assistantItemsArriveUnselected() {
        var queue = CleanupQueue()
        let proposal = item("/f/x", source: .assistant(thread: UUID(), reason: "old cache"), selected: true)
        queue.add(proposal)
        #expect(queue.items.first?.isSelected == false)
        #expect(queue.selected.isEmpty)
        queue.setSelected(proposal.id, true)
        #expect(queue.selected.count == 1)
    }

    @Test func dangerousAssistantProposalsAreRefused() {
        var queue = CleanupQueue()
        let thread = UUID()
        #expect(queue.add(item("/f/backup", risk: .dangerous, source: .assistant(thread: thread, reason: "big"))) == .needsUserChoice)
        #expect(queue.add(item("/f/never", risk: .never, source: .assistant(thread: thread, reason: "big"))) == .needsUserChoice)
        #expect(queue.items.isEmpty)

        let home = "/Users/lightwell-test-home"
        let policy = SafetyPolicy(home: home)
        let library = item(home + "/Pictures/Lib.photoslibrary", risk: .review, source: .assistant(thread: thread, reason: "r"))
        #expect(queue.add(library, checkedBy: policy) == .needsUserChoice)
        let mobileSync = home + "/Library/Application Support/MobileSync"
        #expect(queue.add(item(mobileSync, risk: .review, source: .assistant(thread: thread, reason: "r")), checkedBy: policy) == .needsUserChoice)
        // A folder with a never path inside is blocked for everyone.
        #expect(queue.add(item(home + "/.local", source: .user), checkedBy: policy) == .blocked(.userData))
        #expect(queue.add(item(home + "/Library/Application Support/Slack", source: .user), checkedBy: policy) != .needsUserChoice)
        // The user may queue the dangerous folder (the confirm sheet asks for the acknowledgement).
        guard case .added = queue.add(item(mobileSync, risk: .dangerous, source: .user), checkedBy: policy) else {
            Issue.record("user could not queue a dangerous folder"); return
        }
    }

    @Test func totalsAndRiskCounts() {
        var queue = CleanupQueue()
        queue.add(item("/f/a", bytes: 100, risk: .safe))
        queue.add(item("/f/b", bytes: 50, risk: .review))
        queue.add(item("/f/c", bytes: 25, risk: .dangerous))
        queue.add(item("/f/d", bytes: 5, risk: .review, selected: false))
        #expect(queue.totalBytes == 180)
        #expect(queue.selectedBytes == 175)
        #expect(queue.selectedFreesAbout == 175)
        #expect(queue.selectedCountByRisk == [.safe: 1, .review: 1, .dangerous: 1])
        #expect(queue.selectedNeedingAcknowledgement.map(\.path) == ["/f/c"])
    }

    @Test func applyRemovesSucceededItems() {
        var queue = CleanupQueue()
        let a = item("/f/a"), b = item("/f/b")
        queue.add(a)
        queue.add(b)
        queue.apply(DeletionReport(mode: .trash, succeeded: [DeletionSuccess(itemID: a.id, path: a.path, bytes: 10)],
                                   failed: [DeletionFailure(itemID: b.id, path: b.path, kind: .locked)], startedAt: .now, finishedAt: .now))
        #expect(queue.items.map(\.id) == [b.id])
    }

    @Test func policyAwareAddBlocksProtectedItems() {
        var queue = CleanupQueue()
        let policy = SafetyPolicy(home: "/Users/lightwell-test-home")
        #expect(queue.add(item("/Users/lightwell-test-home/Library/Keychains/x"), checkedBy: policy) == .blocked(.userData))
        #expect(queue.add(item("/System/Library"), checkedBy: policy) == .blocked(.systemPath))
        guard case .added = queue.add(item("/Users/lightwell-test-home/Library/Caches/com.x"), checkedBy: policy) else {
            Issue.record("cache not added"); return
        }
    }

    @Test func itemsFromTreeCarryIdentityAndEstimates() {
        let tree = InMemoryTree(rootPath: "/fx")
        let x = tree.addDirectory("x", under: tree.root)
        let y = tree.addDirectory("y", under: tree.root)
        let a = tree.addFile("a.bin", size: 100, under: x)
        tree.addFile("solo.bin", size: 7, under: x)
        tree.addHardLink("b.bin", under: y, to: a)

        let fromTree = QueueItem(node: x, in: tree, risk: .review, source: .user)
        #expect(fromTree.path == "/fx/x")
        #expect(fromTree.identity == tree.identity(x))
        #expect(fromTree.freesAbout == 7)  // the hard-linked file stays reachable through y
        let proposal = QueueItem(node: y, in: tree, risk: .review, source: .assistant(thread: UUID(), reason: "r"))
        #expect(proposal.isSelected == false)

        var queue = CleanupQueue()
        queue.add(fromTree)
        queue.add(QueueItem(node: y, in: tree, risk: .review, source: .user))
        queue.refreshEstimates(using: tree)
        // The shared inode is freed once, credited to the last selected member.
        #expect(queue.items.map(\.freesAbout) == [7, 100])
        #expect(queue.selectedFreesAbout == 107)
        queue.setSelected(queue.items[1].id, false)
        queue.refreshEstimates(using: tree)
        #expect(queue.items.map(\.freesAbout) == [7, 100])
        #expect(queue.selectedFreesAbout == 7)
    }

    @Test func queueItemsRoundTripThroughCodable() throws {
        var queue = CleanupQueue()
        queue.add(QueueItem(path: "/f/a", identity: FileIdentity(device: 1, inode: 2), bytes: 3, freesAbout: 3, risk: .safe, ruleID: "caches.user", source: .category("caches.user"), isSelected: true))
        let back = try JSONDecoder().decode(CleanupQueue.self, from: JSONEncoder().encode(queue))
        #expect(back == queue)
    }
}
