import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Node ids that outlive a rescan, cached classification, "Queue It Myself", and other review items.
@Suite("Rescans, cached classification and user choices", .serialized)
@MainActor
struct FixRoundOneTests {
    /// A fixture whose second snapshot has every node id shifted (a folder sorted before `home`).
    static func shiftedSnapshot(_ fixture: HomeFixture) throws -> InMemoryTree {
        _ = try fixture.fx.file("Aaa/first/early.bin", size: 4096)
        return try InMemoryTree.snapshot(of: fixture.root)
    }

    @Test func restructureBetweenToolSnapshotAndQueueNeverQueuesAnotherPath() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = EpochTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let path = fixture.path("home/Library/Developer/Xcode/DerivedData/App-1")
        let staleNode = try #require(tree.node(atPath: path))
        // The tool took its snapshot here; then a full root rescan reassigns every id.
        tree.adopt(try Self.shiftedSnapshot(fixture))
        #expect(tree.path(staleNode) != path, "the old id names another item now")
        let proposal = ToolProposal(node: staleNode, tree: tree, path: path, risk: .safe, ruleID: "xcode.deriveddata", reason: "Xcode rebuilds it.")
        let thread = UUID()

        // Before the session has seen the restructure: refused with a clear reason, nothing queued.
        #expect(app.model.enqueue([proposal], thread: thread) == [.blocked(.changedSinceScan)])
        #expect(app.model.cleanup.queue.isEmpty)

        // After it: resolved by path, so the reason stays with the item it was written for.
        app.session.restructured()
        let results = app.model.enqueue([proposal], thread: thread)
        guard case .added = results.first else { Issue.record("not queued: \(results)"); return }
        let item = try #require(app.model.cleanup.queue.first)
        #expect(item.path == path)
        #expect(item.nodeID == tree.node(atPath: path))
        if case .assistant(_, let reason) = item.source { #expect(reason == "Xcode rebuilds it.") }
    }

    @Test func staleCategoryNodesAreNeverQueued() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = EpochTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let category = try #require(app.session.category(ruleID: "xcode.deriveddata"))
        tree.adopt(try Self.shiftedSnapshot(fixture))
        let results = app.model.cleanup.add(category: category, tree: tree)
        #expect(results.allSatisfy { $0 == .blocked(.changedSinceScan) })
        #expect(app.model.cleanup.queue.isEmpty)
    }

    @Test func nestedDangerousListSurvivesARescan() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = EpochTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let cleanup = app.model.cleanup
        let old = try #require(tree.node(atPath: fixture.path("home/Documents/Old")))
        cleanup.add(tree.summary(of: old), source: .user)
        let item = try #require(cleanup.queue.first)
        let expected = [fixture.path("home/Documents/Old/Family.photoslibrary")]
        #expect(cleanup.nestedDangerousPaths(of: item) == expected)

        tree.adopt(try Self.shiftedSnapshot(fixture))
        app.session.restructured()
        let after = try #require(cleanup.queue.first)
        #expect(after.nodeID == tree.node(atPath: fixture.path("home/Documents/Old")), "queue node ids re-resolved by path")
        #expect(cleanup.nestedDangerousPaths(of: after) == expected, "the acknowledgement still lists the nested library")
    }

    @Test func queueItMyselfAddsAUserItemThatNeedsTheAcknowledgement() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        app.model.assistant.newThread()
        let thread = try #require(app.model.assistant.active)
        let result = try app.decode(ProposeDeletionResult.self, await app.call(.proposeDeletion, [
            "items": [["path": "~/Pictures/Trip.photoslibrary", "reason": "big library"]],
            "summary": "Photos",
        ], thread: thread))
        #expect(result.rejected.map(\.code) == ["needs_user_choice"], "the model still sees the rejection")
        #expect(app.model.cleanup.queue.isEmpty)

        let card = try #require(app.model.assistant.items.compactMap { item -> ProposalBatch? in
            if case .proposal(let batch) = item.kind { batch } else { nil }
        }.first)
        let rejected = try #require(card.rejected.first)
        #expect(rejected.userMayQueue)
        #expect(!app.model.isQueued(rejected))
        guard case .added(let id) = app.model.queueItMyself(rejected) else { Issue.record("not queued"); return }
        let item = try #require(app.model.cleanup.queue.first)
        #expect(item.source == .user)
        #expect(item.risk == .dangerous)
        #expect(!item.isSelected)
        #expect(!app.model.cleanup.mayRemove(item))
        #expect(app.model.isQueued(rejected))
        app.model.cleanup.acknowledge(id)
        app.model.cleanup.setSelected(id, true)
        #expect(app.model.cleanup.removalSet.map(\.id) == [id])

        let protected = RejectedProposal(path: "~/Library/Keychains", block: .userData, message: "", code: "protected", fullPath: fixture.path("home/Library/Keychains"))
        #expect(!protected.userMayQueue)
        #expect(app.model.queueItMyself(protected) == .blocked(.notInScan))
    }

    @Test func selectingALargeFolderStaysWithinTheBudget() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = fixture.tree
        let home = try fixture.node("home")
        var inode: UInt64 = 50_000_000
        let big = tree.addDirectory("Big", under: home, identity: FileIdentity(device: 1, inode: inode))
        for index in 0..<4_000 {
            inode += 1
            let folder = tree.addDirectory("d\(index)", under: big, identity: FileIdentity(device: 1, inode: inode))
            inode += 1
            tree.addFile("f.bin", size: 4096, under: folder, identity: FileIdentity(device: 1, inode: inode))
        }
        inode += 1
        let library = tree.addDirectory("Holiday.photoslibrary", under: big, flags: .package, identity: FileIdentity(device: 1, inode: inode))
        inode += 1
        tree.addFile("db", size: 4096, under: library, identity: FileIdentity(device: 1, inode: inode))
        _ = tree.size(tree.root)
        let app = try await AppHarness(fixture: fixture)
        let session = app.session
        #expect(tree.descendantCount(big) > ScanSessionModel.synchronousClassificationLimit)

        let clock = ContinuousClock()
        let revision = session.classificationRevision
        let selectTime = clock.measure {
            session.selection = big
            _ = session.canQueue(big)
            _ = session.addBlockReason(for: big)
        }
        let ms = Double(selectTime.components.attoseconds) / 1e15
        print("selecting a folder of \(tree.descendantCount(big)) items: \(String(format: "%.2f", ms)) ms on the main actor")
        #expect(ms < 16, "the nested walk runs off the main actor")
        #expect(await waitUntil { session.classificationRevision != revision })
        #expect(session.cachedClassification(of: big)?.risk == .dangerous, "the nested library arrived off the main actor")

        // Queue rows read the stored list: no walk per render or countdown tick.
        app.model.cleanup.add(tree.summary(of: big), source: .user)
        let item = try #require(app.model.cleanup.queue.first)
        let rowTime = clock.measure { for _ in 0..<1_000 { _ = app.model.cleanup.nestedDangerousPaths(of: item) } }
        #expect(Double(rowTime.components.attoseconds) / 1e15 < 16)
        #expect(app.model.cleanup.nestedDangerousPaths(of: item) == [tree.path(library)])
    }

    @Test func sendIsRefusedBeforeConsent() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture, assistant: try AssistantModelTests.services(fixture))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        await assistant.waitForRecheck()
        #expect(assistant.availability == .needsConsent)
        assistant.send("Please suggest ~/Downloads/old-installer.dmg")
        #expect(!assistant.isResponding)
        #expect(assistant.items.isEmpty)
        #expect(app.model.cleanup.queue.isEmpty)
    }

    @Test func freeNowCoversOnlyThisRunsTrashItems() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        cleanup.add(tree.summary(of: try fixture.node("home/Downloads/notes.txt")), source: .user)
        await cleanup.run(mode: .trash)
        cleanup.add(tree.summary(of: try fixture.node("home/Downloads/old-installer.dmg")), source: .user)
        await cleanup.run(mode: .trash)
        let report = try #require(cleanup.lastReport)
        #expect(cleanup.recentlyTrashed.count == 2)
        let fromRun = cleanup.trashedRecords(from: report)
        #expect(fromRun.map { ($0.originalPath as NSString).lastPathComponent } == ["old-installer.dmg"])
    }
}
