import Darwin
import Foundation
import Testing
@testable import CleanupKit
import RulesKit
import ScanKit
import TestSupport

@Suite("Trash and recently trashed")
struct TrashTests {
    /// The only test that touches the real Trash: it trashes its own uniquely named fixture file
    /// and then deletes exactly that file from the Trash through the resulting URL.
    @Test func realTrashRoundTripCleansUpAfterItself() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let name = "lightwell-roundtrip-\(UUID().uuidString).bin"
        let file = try fx.file(name, size: 4096)
        let executor = CleanupExecutor(policy: SafetyPolicy(home: fx.root.path), trash: SystemTrash(),
                                       allowedRoot: fx.root, rules: [], runningApps: NoAppsRunning())
        let (_, report) = await runAll(executor, [queueItem(file)], mode: .trash)
        let r = try #require(report)
        #expect(r.failed.isEmpty, "\(r.failed)")
        let trashed = try #require(r.succeeded.first?.trashedURL)
        defer {
            // Safety net: remove only our own file, only if it is still in a Trash folder.
            if trashed.lastPathComponent.hasPrefix("lightwell-roundtrip-"),
               trashed.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }),
               exists(trashed) {
                unlink(trashed.path)
            }
        }
        #expect(!exists(file))
        #expect(trashed.lastPathComponent.hasPrefix("lightwell-roundtrip-"))
        #expect(trashed.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" })

        var recent = RecentlyTrashed()
        recent.record(r)
        #expect(recent.records.count == 1)
        let removal = recent.deletePermanently(Set(recent.records.map(\.id)))
        #expect(removal.failed.isEmpty, "\(removal.failed)")
        #expect(removal.succeeded.count == 1)
        #expect(!exists(trashed))
        #expect(recent.records.isEmpty)
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func recentlyTrashedDeletesOnlyChosenItems() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let a = try fx.file("a.bin", size: 4096)
        let b = try fx.file("b/inner.bin", size: 100)
        let folder = try fx.url("b")
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(a), queueItem(folder)], mode: .trash)
        let r = try #require(report)
        var recent = RecentlyTrashed()
        recent.record(r, date: Date(timeIntervalSince1970: 0))
        #expect(recent.records.count == 2)
        #expect(recent.records.allSatisfy { $0.identity != nil })
        #expect(recent.totalBytes == 8192)
        _ = b

        let first = recent.records[0]
        // Without the injected test double, a folder named like it is not a Trash.
        let refused = recent.deletePermanently([first.id], allowedRoot: fx.root)
        #expect(refused.failed.map(\.kind) == [.notInTrash])
        #expect(exists(first.trashedURL))
        let removal = recent.deletePermanently([first.id], allowedRoot: fx.root, testTrash: FixtureTrash(root: fx.root))
        #expect(removal.succeeded.map(\.itemID) == [first.id])
        #expect(!exists(first.trashedURL))
        #expect(recent.records.count == 1)
        #expect(exists(recent.records[0].trashedURL))
    }

    @Test func recentlyTrashedRevalidates() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        // Replaced since it was trashed.
        let swapped = try fx.file(".test-trash/swapped.bin", size: 10)
        let staleIdentity = identity(of: swapped)
        try FileManager.default.removeItem(at: swapped)
        try fx.file(".test-trash/swapped.bin", size: 10)
        // Not inside a Trash folder.
        let loose = try fx.file("loose.bin", size: 10)
        // Gone already.
        let gone = fx.root.appendingPathComponent(".test-trash/gone.bin")
        // Outside the allowed root.
        let outside = fx.sentinel.appendingPathComponent("keep.bin")

        var recent = RecentlyTrashed(records: [
            TrashedRecord(originalPath: "/x/swapped.bin", trashedURL: swapped, bytes: 10, date: .now, identity: staleIdentity),
            TrashedRecord(originalPath: "/x/loose.bin", trashedURL: loose, bytes: 10, date: .now, identity: identity(of: loose)),
            TrashedRecord(originalPath: "/x/gone.bin", trashedURL: gone, bytes: 10, date: .now, identity: nil),
            TrashedRecord(originalPath: "/x/keep.bin", trashedURL: outside, bytes: 10, date: .now, identity: identity(of: outside)),
        ])
        let report = recent.deletePermanently(Set(recent.records.map(\.id)), allowedRoot: fx.root, testTrash: FixtureTrash(root: fx.root))
        #expect(report.succeeded.isEmpty)
        #expect(report.failed.map(\.kind) == [.changedSinceScan, .notInTrash, .notFound, .outsideAllowedRoot])
        #expect(exists(swapped) && exists(loose) && exists(outside))
        #expect(recent.records.count == 3)
        #expect(fx.sentinelChanges().isEmpty)

        try FileManager.default.removeItem(at: loose)
        recent.pruneMissing()
        #expect(recent.records.count == 2)
    }

    @Test func fixtureTrashNeverOverwrites() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let trash = FixtureTrash(root: fx.root)
        let one = try trash.trash(try fx.file("same.bin", size: 10))
        let two = try trash.trash(try fx.file("same.bin", size: 10))
        let first = try #require(one)
        let second = try #require(two)
        #expect(first != second)
        #expect(exists(first) && exists(second))
    }
}
