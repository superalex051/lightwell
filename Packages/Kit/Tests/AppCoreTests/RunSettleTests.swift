import CleanupKit
import Foundation
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Live bug (2026-10-13): after a deletion on a whole-disk scan the space was freed but Cleanup
/// kept showing "Working..." with the main thread busy and no executor frames. This measures the
/// main-actor time between the executor finishing and `isRunning` clearing on a tree of about two
/// million nodes, with a few hundred items trashed at once.
@Suite("Cleanup run settles on a huge tree", .serialized)
@MainActor
struct RunSettleTests {
    nonisolated static let itemCount = 400
    nonisolated static let syntheticFolders = 2_000
    nonisolated static let filesPerFolder = 1_000

    /// A real scan of the fixture with about two million synthetic nodes grafted under
    /// `home/Synthetic` (an empty folder on disk; nothing there is ever touched).
    static func hugeTree(_ fixture: HomeFixture) async throws -> ScanTree {
        let root = ScanSessionModel.canonicalRoot(fixture.root)
        let scanner = Scanner(ScanOptions(root: URL(fileURLWithPath: root), workers: 4))
        var scanned: ScanTree?
        for await event in scanner.start() {
            if case .finished(let tree) = event { scanned = tree }
        }
        let tree = try #require(scanned)
        let synthetic = try #require(tree.node(atPath: root + "/home/Synthetic"))
        try await Task.detached {
            let builder = ScanTreeBuilder(rootPath: root + "/home/Synthetic")
            for folder in 0..<syntheticFolders {
                let dir = builder.addDirectory("d\(folder)", under: builder.root)
                for file in 0..<filesPerFolder { builder.addFile("f\(file).bin", size: 4096, under: dir) }
            }
            tree.replaceChildren(of: synthetic, with: builder.build())
            #expect(tree.statistics().nodes > 2_000_000)
        }.value
        return tree
    }

    @Test func workingClearsQuicklyAfterTheExecutorFinishes() async throws {
        let fixture = try await Task.detached {
            try HomeFixture { fx in
                for index in 0..<RunSettleTests.itemCount { _ = try fx.file("home/Library/Caches/app\(index)/blob.bin", size: 4096) }
                _ = try fx.dir("home/Synthetic")
            }
        }.value
        defer { fixture.tearDown() }
        let tree = try await Self.hugeTree(fixture)
        let model = AppModel(
            cleanup: CleanupModel(configuration: .fixture(root: fixture.root, home: fixture.home)),
            settings: AppSettings(assistantConsentAccepted: false),
            home: fixture.home
        )
        model.connect(assistantServices: nil, snapshots: .disabled, metadata: .none)
        let session = ScanSessionModel(target: .folder(fixture.root), tree: tree, services: fixture.services())
        model.adopt(session)
        #expect(await waitUntil(timeout: 120) { session.isFinished && !session.isClassifying && !session.categories.isEmpty })
        let caches = try #require(session.categories.first { $0.ruleID == "caches.user" })
        model.cleanup.add(category: caches, tree: tree)
        #expect(model.cleanup.queue.count >= Self.itemCount)

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
        await model.cleanup.run(mode: .trash)
        // Whatever follows a run in the background (categories, volume numbers) is part of the test.
        try await Task.sleep(for: .seconds(1))
        heartbeat.cancel()
        let worst = await heartbeat.value
        let settle = try #require(model.cleanup.lastRunSettleTime)
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        print(String(format: "run settle on a %d-node tree, %d items: executor end to isRunning false %.1f ms, worst main-actor stall %.1f ms",
                     tree.statistics().nodes, model.cleanup.lastReport?.succeeded.count ?? 0, ms(settle), ms(worst)))
        #expect(!model.cleanup.isRunning)
        #expect(model.cleanup.lastReport?.succeeded.count == model.cleanup.recentlyTrashed.count)
        #expect(model.cleanup.recentlyTrashed.count > Self.itemCount)
        #expect(ms(settle) < 50, "isRunning stayed set \(ms(settle)) ms after the executor finished")
        #expect(ms(worst) < 250, "the main actor stalled \(ms(worst)) ms around the run")
    }
}
