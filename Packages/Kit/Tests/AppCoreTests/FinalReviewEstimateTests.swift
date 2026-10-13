import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Task 9 item 3: "frees about" estimates are recomputed off the main actor.
@Suite("Estimates off the main actor", .serialized)
@MainActor
struct FinalReviewEstimateTests {
    // MARK: Item 3: estimates off the main actor

    @Test func tickingStaysQuickWithManyHardLinksAndClones() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = fixture.tree
        let projects = try fixture.node("home/Projects")
        // 20 package folders of 1,200 files: a third plain, a third hard links to the previous
        // folder's plain files, a third clones of them (a pnpm store and APFS copies in small).
        var folders: [NodeID] = []
        var previousPlain: [NodeID] = []
        for f in 0..<20 {
            let folder = tree.addDirectory("pkg\(f)", under: projects, identity: FileIdentity(device: 1, inode: 7_000_000 + UInt64(f)))
            var plain: [NodeID] = []
            for i in 0..<400 {
                plain.append(tree.addFile("f\(i)", size: 8192, under: folder))
                if previousPlain.isEmpty {
                    tree.addFile("l\(i)", size: 8192, under: folder)
                    tree.addFile("c\(i)", size: 8192, under: folder)
                } else {
                    tree.addHardLink("l\(i)", under: folder, to: previousPlain[i])
                    tree.addClone("c\(i)", under: folder, of: previousPlain[i], privateBytes: 512)
                }
            }
            previousPlain = plain
            folders.append(folder)
        }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let context = try #require(app.session.cleanupContext)
        let results = cleanup.add(nodes: folders, context: context, source: .user)
        #expect(results.allSatisfy { if case .added = $0 { true } else { false } }, "\(results)")
        await cleanup.estimatesSettled()

        // Reference: the same estimate refresh, timed as it used to run on the main actor.
        let clock = ContinuousClock()
        var reference = CleanupQueue(items: cleanup.queue)
        let onMain = clock.measure { reference.refreshEstimates(using: tree) }
        #expect(cleanup.queue.map(\.freesAbout) == reference.items.map(\.freesAbout))
        #expect(cleanup.queue.contains { $0.freesAbout < $0.bytes }, "shared bytes are not counted for a lone member")

        var worst = Duration.zero
        for item in cleanup.queue.prefix(6) {
            worst = max(worst, clock.measure { cleanup.toggle(item.id) })
            await cleanup.estimatesSettled()
            worst = max(worst, clock.measure { cleanup.toggle(item.id) })
            await cleanup.estimatesSettled()
        }
        print("estimates: refresh on the main actor took \(onMain); worst toggle now \(worst)")
        #expect(worst < .milliseconds(5), "a toggle never waits for the hard-link and clone walks")

        // Quick toggles while a refresh runs: the last state wins and the totals are exact.
        let ids = cleanup.queue.prefix(3).map(\.id)
        for id in ids { cleanup.toggle(id) }
        cleanup.toggle(ids[0])
        #expect(cleanup.isEstimating)
        await cleanup.estimatesSettled()
        #expect(!cleanup.isEstimating)
        var check = CleanupQueue(items: cleanup.queue)
        check.refreshEstimates(using: tree)
        #expect(cleanup.queue.map(\.freesAbout) == check.items.map(\.freesAbout))
        #expect(cleanup.queue.map(\.isSelected) == [true, false, false] + Array(repeating: true, count: 17))
    }
}
