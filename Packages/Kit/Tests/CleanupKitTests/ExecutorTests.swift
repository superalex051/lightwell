import Darwin
import Foundation
import Testing
@testable import CleanupKit
import RulesKit
import ScanKit
import TestSupport

/// Every test works only inside its own fixture; `sentinelChanges()` proves nothing outside changed.
@Suite("CleanupExecutor")
struct ExecutorTests {
    @Test func trashMovesItemIntoFixtureTrash() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let file = try fx.file("Projects/a.bin", size: 4096)
        let item = queueItem(file)
        let (events, report) = await runAll(makeExecutor(fx), [item], mode: .trash)
        let r = try #require(report)
        #expect(r.failed.isEmpty)
        #expect(r.succeeded.count == 1)
        let trashed = try #require(r.succeeded.first?.trashedURL)
        #expect(exists(trashed))
        #expect(trashed.path.hasPrefix(fx.root.path + "/.test-trash/"))
        #expect(!exists(file))
        #expect(r.bytesMovedToTrash == 4096 && r.bytesFreedNow == 0)
        #expect(events.count == 3)
        #expect(events.first == .itemStarted(item.id))
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func permanentRemovesTreeWithoutFollowingSymlinks() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("proj/build/obj/a.o", size: 8192)
        try fx.file("proj/build/obj/deeper/b.o", size: 100)
        try fx.symlink("proj/build/to-sentinel", to: fx.sentinel.path)
        try fx.symlink("proj/build/to-file", to: fx.sentinel.appendingPathComponent("keep.bin").path)
        try fx.file("proj/keep/source.c", size: 10)
        try fx.symlink("proj/build/to-sibling", to: try fx.path("proj/keep"))
        let build = try fx.url("proj/build")
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(build)], mode: .permanent)
        let r = try #require(report)
        #expect(r.failed.isEmpty, "\(r.failed)")
        #expect(r.bytesFreedNow == 4096 && r.bytesMovedToTrash == 0)
        #expect(!exists(build))
        #expect(exists(try fx.url("proj/keep/source.c")))
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func deepTreePastPathMax() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.deepPath("deep", levels: 300)
        let deep = try fx.url("deep")
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(deep)], mode: .permanent)
        #expect(report?.failed.isEmpty == true, "\(report?.failed ?? [])")
        #expect(!exists(deep))
    }

    @Test func changedSinceScanIsRefused() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let file = try fx.file("a.bin", size: 4096)
        let item = queueItem(file)
        // Replace the file: same path, new inode.
        try FileManager.default.removeItem(at: file)
        try fx.file("a.bin", size: 4096)
        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), [item], mode: mode)
            let failure = try #require(report?.failed.first)
            #expect(failure.kind == .changedSinceScan)
            #expect(failure.block == .changedSinceScan)
            #expect(exists(file))
        }
    }

    @Test func missingIdentityIsRefused() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let file = try fx.file("a.bin", size: 4096)
        var item = queueItem(file)
        item.identity = nil
        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), [item], mode: mode)
            let failure = try #require(report?.failed.first)
            #expect(failure.kind == .blocked)
            #expect(failure.block == .notInScan)
            #expect(exists(file))
        }
    }

    @Test func lockedItemsFailAndKeepTheirFlag() async throws {
        let fx = try FixtureBuilder()
        defer { clearFixtureFlags(fx); fx.tearDown() }
        let locked = try fx.file("locked.bin", size: 4096)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        try fx.file("folder/plain.bin", size: 100)
        let inner = try fx.file("folder/inner-locked.bin", size: 100)
        #expect(chflags(inner.path, UInt32(UF_IMMUTABLE)) == 0)
        let folder = try fx.url("folder")

        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), [queueItem(locked)], mode: mode)
            #expect(report?.failed.first?.kind == .locked)
            #expect(exists(locked))
        }
        var info = stat()
        #expect(lstat(locked.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0)

        // Permanent: a locked file inside a folder stops the whole folder, nothing is deleted.
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(folder)], mode: .permanent)
        #expect(report?.failed.first?.kind == .locked)
        #expect(exists(try fx.url("folder/plain.bin")))
        #expect(exists(inner))
        #expect(lstat(inner.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func symlinkActsOnlyOnTheLink() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let target = fx.sentinel.appendingPathComponent("keep.bin")
        try fx.file("real/inside.bin", size: 100)

        // Trash mode: the links themselves go to the Trash and show up in Recently Trashed.
        let fileLink = try fx.symlink("file-link", to: target.path)
        let dirLink = try fx.symlink("dir-link", to: try fx.path("real"))
        let (_, trashed) = await runAll(makeExecutor(fx), [queueItem(fileLink), queueItem(dirLink)], mode: .trash)
        let t = try #require(trashed)
        #expect(t.failed.isEmpty, "\(t.failed)")
        #expect(!exists(fileLink) && !exists(dirLink))
        for success in t.succeeded {
            let moved = try #require(success.trashedURL)
            var info = stat()
            #expect(lstat(moved.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK, "the link itself was moved")
        }
        var recent = RecentlyTrashed()
        recent.record(t)
        #expect(recent.records.count == 2)
        #expect(exists(target))
        #expect(exists(try fx.url("real/inside.bin")))

        // Permanent mode: the links are unlinked, the targets stay.
        let fileLink2 = try fx.symlink("file-link-2", to: target.path)
        let dirLink2 = try fx.symlink("dir-link-2", to: try fx.path("real"))
        let (_, removed) = await runAll(makeExecutor(fx), [queueItem(fileLink2), queueItem(dirLink2)], mode: .permanent)
        let r = try #require(removed)
        #expect(r.failed.isEmpty, "\(r.failed)")
        #expect(r.succeeded.allSatisfy { $0.trashedURL == nil })
        #expect(!exists(fileLink2) && !exists(dirLink2))
        #expect(exists(target))
        #expect(exists(try fx.url("real/inside.bin")))
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func outsideAllowedRootIsRefused() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let outside = fx.sentinel.appendingPathComponent("keep.bin")
        let viaDotDot = URL(fileURLWithPath: fx.root.path + "/../" + fx.sentinel.lastPathComponent + "/keep.txt")
        try fx.symlink("escape", to: fx.sentinel.path)
        let viaLink = try fx.url("escape/nested")
        var rootItem = queueItem(fx.root)
        rootItem.path = fx.root.path
        let items = [queueItem(outside), queueItem(viaDotDot), queueItem(viaLink), rootItem]
        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), items, mode: mode)
            let r = try #require(report)
            #expect(r.succeeded.isEmpty)
            #expect(r.failed.count == 4)
            #expect(r.failed.allSatisfy { $0.kind == .outsideAllowedRoot }, "\(r.failed.map(\.kind))")
        }
        #expect(fx.sentinelChanges().isEmpty)
        #expect(exists(fx.root))
    }

    @Test func unresolvableAllowedRootRefusesEverything() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let file = try fx.file("a.bin", size: 10)
        let executor = CleanupExecutor(policy: SafetyPolicy(home: fx.root.path), trash: FixtureTrash(root: fx.root),
                                       allowedRoot: fx.root.appendingPathComponent("missing"), rules: [], runningApps: NoAppsRunning())
        let (_, report) = await runAll(executor, [queueItem(file)], mode: .permanent)
        #expect(report?.failed.first?.kind == .outsideAllowedRoot)
        #expect(exists(file))
    }

    @Test func safetyPolicyIsCheckedAgain() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        // The fixture root is the injected home, so these are protected home paths.
        let keychain = try fx.file("Library/Keychains/login.keychain-db", size: 100)
        let dotfile = try fx.file(".zshrc", size: 10)
        let documents = try fx.dir("Documents")
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(keychain), queueItem(dotfile), queueItem(documents)], mode: .permanent)
        let blocks = report?.failed.map(\.block)
        #expect(blocks == [.userData, .userData, .protectedRoot])
        #expect(exists(keychain) && exists(dotfile) && exists(documents))
        #expect(report?.failed.first?.message == BlockReason.userData.message)
    }

    @Test func riskIncreaseNeedsANewReview() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let library = try fx.package("Pictures/Old.photoslibrary")
        let (_, low) = await runAll(makeExecutor(fx), [queueItem(library, risk: .review)], mode: .trash)
        #expect(low?.failed.first?.kind == .riskIncreased)
        #expect(exists(library))
        let (_, acknowledged) = await runAll(makeExecutor(fx), [queueItem(library, risk: .dangerous)], mode: .trash)
        #expect(acknowledged?.succeeded.count == 1)
        #expect(!exists(library))
    }

    @Test func runningAppPreconditionStopsTheItem() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let file = try fx.file("Library/Developer/Xcode/DerivedData/App-abc/x.o", size: 100)
        let folder = try fx.url("Library/Developer/Xcode/DerivedData/App-abc")
        let rules = try RuleLoader.loadBundled()
        let busy = makeExecutor(fx, rules: rules, apps: AppsRunning(running: ["com.apple.dt.Xcode"]))
        let (_, blocked) = await runAll(busy, [queueItem(folder, risk: .safe, ruleID: "xcode.deriveddata")], mode: .trash)
        #expect(blocked?.failed.first?.kind == .appRunning)
        #expect(blocked?.failed.first?.detail == "com.apple.dt.Xcode")
        #expect(exists(file))
        let idle = makeExecutor(fx, rules: rules)
        let (_, done) = await runAll(idle, [queueItem(folder, risk: .safe, ruleID: "xcode.deriveddata")], mode: .trash)
        #expect(done?.succeeded.count == 1)
    }

    @Test func itemsAlreadyInTheTrash() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let old = try fx.file(".Trash/old.bin", size: 100)
        let (_, moved) = await runAll(makeExecutor(fx), [queueItem(old)], mode: .trash)
        #expect(moved?.failed.first?.kind == .alreadyInTrash)
        #expect(exists(old))
        let (_, deleted) = await runAll(makeExecutor(fx), [queueItem(old)], mode: .permanent)
        #expect(deleted?.succeeded.count == 1)
        #expect(!exists(old))
    }

    @Test func partialFailureReport() async throws {
        let fx = try FixtureBuilder()
        defer { clearFixtureFlags(fx); fx.tearDown() }
        let ok = try fx.file("ok.bin", size: 4096)
        let changed = try fx.file("changed.bin", size: 4096)
        let changedItem = queueItem(changed)
        try FileManager.default.removeItem(at: changed)
        try fx.file("changed.bin", size: 4096)
        let locked = try fx.file("locked.bin", size: 4096)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        let missing = try fx.file("missing.bin", size: 10)
        let missingItem = queueItem(missing)
        try FileManager.default.removeItem(at: missing)

        let items = [queueItem(ok, bytes: 1000), changedItem, queueItem(locked), missingItem]
        let (events, report) = await runAll(makeExecutor(fx), items, mode: .trash)
        let r = try #require(report)
        #expect(r.succeeded.map(\.itemID) == [items[0].id])
        #expect(r.failed.map(\.kind) == [.changedSinceScan, .locked, .notFound])
        #expect(r.bytesFreed == 1000)
        #expect(events.filter { if case .itemFailed = $0 { true } else { false } }.count == 3)
        for failure in r.failed { #expect(!failure.message.isEmpty) }
    }

    @Test func cancelStopsBetweenItems() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let files = try (0..<3).map { try fx.file("f\($0).bin", size: 100) }
        let box = ExecutorBox()
        let trash = CancellingTrash(inner: FixtureTrash(root: fx.root), box: box)
        let executor = makeExecutor(fx, trash: trash)
        box.set(executor)
        let (_, report) = await runAll(executor, files.map { queueItem($0) }, mode: .trash)
        let r = try #require(report)
        #expect(r.succeeded.count == 1)
        #expect(r.failed.map(\.kind) == [.cancelled, .cancelled])
        #expect(exists(files[1]) && exists(files[2]))
    }

    @Test func failureKindsHaveMessages() {
        for kind in DeletionFailureKind.allCases {
            #expect(!kind.message.isEmpty)
            #expect(!kind.message.contains("\u{2014}") && !kind.message.contains("\u{2013}"))
        }
    }
}

/// Lets a trash double reach the executor that uses it.
final class ExecutorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var executor: CleanupExecutor?
    func set(_ e: CleanupExecutor) { lock.withLock { executor = e } }
    func cancel() { lock.withLock { executor }?.cancel() }
}

/// Trashes normally and asks the executor to stop after the first item.
struct CancellingTrash: TrashProviding {
    let inner: FixtureTrash
    let box: ExecutorBox
    func trash(_ url: URL) throws -> URL? {
        defer { box.cancel() }
        return try inner.trash(url)
    }
}
