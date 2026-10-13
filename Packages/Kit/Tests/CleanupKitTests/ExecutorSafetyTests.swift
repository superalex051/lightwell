import Darwin
import Foundation
import Testing
@testable import CleanupKit
import RulesKit
import ScanKit
import TestSupport

/// Fix round 1: mount points, protected items nested in folders, assistant limits, permissions.
@Suite("CleanupExecutor safety")
struct ExecutorSafetyTests {
    // MARK: Mount points

    @Test func deviceComparisonDetectsMountPoints() {
        var parent = stat()
        parent.st_dev = 16_777_230
        parent.st_ino = 2
        var item = stat()
        item.st_dev = 16_777_230
        item.st_ino = 99
        #expect(!FileOperations.isMountPoint(item: item, parent: parent))
        item.st_dev = 16_777_244
        item.st_ino = 2
        #expect(FileOperations.isMountPoint(item: item, parent: parent))
    }

    static var hdiutilEnabled: Bool { ProcessInfo.processInfo.environment["LIGHTWELL_TEST_HDIUTIL"] == "1" }

    @discardableResult
    static func hdiutil(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Mounts a small disk image inside the fixture and queues the mount point itself.
    @Test(.enabled(if: hdiutilEnabled, "set LIGHTWELL_TEST_HDIUTIL=1 to mount a disk image"))
    func mountedVolumeIsNeverEntered() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let image = try fx.url("disk.dmg")
        let mount = try fx.dir("Projects/mnt")
        #expect(try Self.hdiutil(["create", "-size", "8m", "-fs", "APFS", "-volname", "LightwellTest", "-quiet", image.path]) == 0)
        #expect(try Self.hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", mount.path, image.path]) == 0)
        defer { _ = try? Self.hdiutil(["detach", mount.path, "-force"]) }
        let inside = mount.appendingPathComponent("on-the-other-volume.bin")
        try Data(repeating: 7, count: 4096).write(to: inside)

        for mode in [DeletionMode.permanent, .trash] {
            let (_, report) = await runAll(makeExecutor(fx), [queueItem(mount)], mode: mode)
            #expect(report?.failed.first?.kind == .mountPoint)
            #expect(exists(inside))
            #expect(exists(mount))
        }
        // The folder holding the mount point is refused in both modes too.
        let parent = try fx.url("Projects")
        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), [queueItem(parent)], mode: mode)
            #expect(report?.failed.first?.kind == .containsOtherVolume)
            #expect(exists(inside))
        }
        #expect(fx.sentinelChanges().isEmpty)
    }

    /// Fix round 2: a device change below the item is refused by the pre-walk (both modes).
    @Test func injectedDeviceChangeBelowTheItemIsRefused() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("outer/inner/mnt/x.bin", size: 10)
        let opened = try FileOperations.open(path: try fx.path("outer"), allowedRoot: .some(FileOperations.canonicalRoot(fx.root))).get()
        let clean = FileOperations.findProtectedDirectory(in: opened, allowDangerous: false, isCancelled: { false })
        #expect(clean == nil)
        let problem = FileOperations.findProtectedDirectory(in: opened, allowDangerous: false, isCancelled: { false }) { name, info in
            if name == "mnt" { info.st_dev &+= 1 }
        }
        #expect(problem?.kind == .containsOtherVolume)
        #expect(problem?.detail?.hasSuffix("/outer/inner/mnt") == true)
    }

    /// Fix round 2: the pre-walk fails closed on a folder it cannot read (both modes).
    @Test func unreadableSubfolderRefusesTheItem() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let keep = try fx.file("proj/a.txt", size: 10)
        let hidden = try fx.restrictedDir("proj/private")
        let project = try fx.url("proj")
        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), [queueItem(project)], mode: mode)
            let failure = try #require(report?.failed.first)
            #expect(failure.kind == .unreadableSubfolder)
            #expect(failure.detail?.hasSuffix("/proj/private") == true)
            #expect(failure.message.contains("Full Disk Access"))
            #expect(exists(keep) && exists(hidden) && exists(project))
        }
    }

    // MARK: Protected items

    @Test func dangerousPatternInsideANeverFolderStaysBlocked() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let library = try fx.package("Library/Mobile Documents/com~apple~CloudDocs/Lib.photoslibrary")
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(library, risk: .dangerous)], mode: .trash)
        #expect(report?.failed.first?.block == .cloudSynced)
        #expect(exists(library))
    }

    @Test func dotFolderContentsAreProtected() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let share = try fx.dir(".local/share")
        try fx.file(".local/share/claude/versions/1", size: 10)
        let credentials = try fx.file(".aws/credentials", size: 10)
        let cache = try fx.file(".npm/_cacache/index-v5/x", size: 10)
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(share), queueItem(credentials), queueItem(try fx.url(".npm/_cacache"))], mode: .permanent)
        let r = try #require(report)
        #expect(r.failed.map(\.block) == [.userData, .userData])
        #expect(exists(share) && exists(credentials))
        #expect(!exists(cache))
    }

    @Test func foldersHoldingProtectedItemsAreRefused() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let mobileSync = try fx.dir("Library/Application Support/MobileSync")
        try fx.file("Library/Application Support/MobileSync/Backup/00008101/Manifest.db", size: 10)
        let google = try fx.dir("Library/Application Support/Google")
        try fx.file("Library/Application Support/Google/Chrome/Default/History", size: 10)
        let old = try fx.dir("Documents/Old")
        try fx.file("Documents/Old/Trip.photoslibrary/database/Photos.sqlite", size: 10)
        let stuff = try fx.dir("Ext/Stuff")
        try fx.file("Ext/Stuff/Backups.backupdb/mac/2026-01-01/x", size: 10)
        let items = [queueItem(mobileSync), queueItem(google), queueItem(old), queueItem(stuff)]
        for mode in [DeletionMode.trash, .permanent] {
            let (_, report) = await runAll(makeExecutor(fx), items, mode: mode)
            let r = try #require(report)
            #expect(r.succeeded.isEmpty)
            #expect(r.failed.map(\.kind) == [.containsProtected, .containsProtected, .containsProtected, .containsProtected])
            #expect(r.failed[3].block == .backup)
            #expect(r.failed[2].detail?.hasSuffix("/Documents/Old/Trip.photoslibrary") == true)
            #expect(!r.failed[0].message.isEmpty)
        }
        #expect(exists(mobileSync) && exists(google) && exists(old) && exists(stuff))

        // With the user's dangerous acknowledgement, dangerous contents may go; never contents may not.
        let acknowledged = [queueItem(mobileSync, risk: .dangerous), queueItem(old, risk: .dangerous), queueItem(stuff, risk: .dangerous)]
        let (_, report) = await runAll(makeExecutor(fx), acknowledged, mode: .trash)
        let r = try #require(report)
        #expect(r.succeeded.count == 2)
        #expect(r.failed.map(\.kind) == [.containsProtected])
        #expect(!exists(mobileSync) && !exists(old) && exists(stuff))
    }

    @Test func assistantAndNeverItemsAreRefused() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let library = try fx.package("Pictures/Lib.photoslibrary")
        let plain = try fx.file("Projects/a.bin", size: 10)
        let thread = UUID()
        let items = [
            queueItem(library, risk: .dangerous, source: .assistant(thread: thread, reason: "big")),
            queueItem(plain, risk: .dangerous, source: .assistant(thread: thread, reason: "big")),
            queueItem(plain, risk: .never),
        ]
        let (_, report) = await runAll(makeExecutor(fx), items, mode: .trash)
        let r = try #require(report)
        #expect(r.failed.map(\.kind) == [.needsUserChoice, .needsUserChoice, .blocked])
        #expect(exists(library) && exists(plain))
    }

    @Test func readOnlySubfolderIsRefusedBeforeAnythingIsDeleted() async throws {
        let fx = try FixtureBuilder()
        let sub = try fx.dir("mod/pkg@v1")
        defer {
            chmod(sub.path, 0o755)
            fx.tearDown()
        }
        let first = try fx.file("mod/aaa-first.txt", size: 10)
        let inner = try fx.file("mod/pkg@v1/go.mod", size: 10)
        #expect(chmod(sub.path, 0o555) == 0)
        let (_, report) = await runAll(makeExecutor(fx), [queueItem(try fx.url("mod"))], mode: .permanent)
        #expect(report?.failed.first?.kind == .permissionDenied)
        #expect(exists(first) && exists(inner))
    }

    // MARK: Pre-walk speed

    @Test func preWalkOfTwentyThousandFoldersIsFast() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let root = try fx.dir("big")
        var created = 0
        for i in 0..<200 {
            let parent = root.path + "/d\(i)"
            if mkdir(parent, 0o755) == 0 { created += 1 }
            for j in 0..<100 where mkdir(parent + "/s\(j)", 0o755) == 0 { created += 1 }
        }
        #expect(created == 20_200)
        let opened = try FileOperations.open(path: root.path, allowedRoot: .some(FileOperations.canonicalRoot(fx.root))).get()
        let clock = ContinuousClock()
        var problem: FileProblem?
        let elapsed = clock.measure {
            problem = FileOperations.findProtectedDirectory(in: opened, allowDangerous: false, isCancelled: { false })
        }
        print("pre-walk of 20200 folders: \(elapsed)")
        #expect(problem == nil)
        #expect(elapsed < .seconds(2))

        // The same walk stops at a nested Photos library.
        try fx.dir("big/d150/s50/Trip.photoslibrary")
        let found = FileOperations.findProtectedDirectory(in: opened, allowDangerous: false, isCancelled: { false })
        #expect(found?.kind == .containsProtected)
        // And it can be cancelled.
        let cancelled = FileOperations.findProtectedDirectory(in: opened, allowDangerous: true, isCancelled: { true })
        #expect(cancelled?.kind == .cancelled)
    }
}
