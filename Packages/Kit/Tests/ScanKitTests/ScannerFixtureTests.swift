import Darwin
import Foundation
import Testing
import TestSupport
@testable import ScanKit

/// PLAN 5.1 "Scanner fixtures": every case compares the scanner with the oracle walk exactly.
@Suite("Scanner fixtures")
struct ScannerFixtureTests {
    @Test func nestedDirectoriesAndExactSizes() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/b/c/one.bin", size: 4096)
        try fx.file("a/two.bin", size: 10_000)
        try fx.file("a/b/three.bin", size: 1_000_000)
        try fx.file("top.bin", size: 1)
        try fx.dir("empty")
        try fx.dir("a/b/empty too")
        let tree = try await scanTree(fx.root)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        let empty = try #require(tree.node(atPath: try fx.path("empty")))
        #expect(tree.size(empty) == 0)
        #expect(tree.flags(empty).contains(.directory))
        #expect(tree.children(empty).isEmpty)
        // Children sorted largest first.
        let sizes = tree.children(tree.root).map { tree.size($0) }
        #expect(sizes == sizes.sorted(by: >))
        #expect(tree.name(tree.root) == fx.root.lastPathComponent)
        #expect(tree.path(tree.root) == fx.root.path)
        #expect(tree.parent(tree.root) == nil)
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func tenThousandFilesInOneDirectory() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.manyFiles(in: "many", count: 10_000, size: 1)
        let tree = try await scanTree(fx.root)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        let many = try #require(tree.node(atPath: try fx.path("many")))
        #expect(tree.children(many).count == 10_000)
        // Large directories use the lazy name index.
        let file = try #require(tree.node(atPath: try fx.path("many/file-05000.bin")))
        #expect(tree.name(file) == "file-05000.bin")
        #expect(tree.node(atPath: try fx.path("many/file-99999.bin")) == nil)
    }

    @Test func threeHundredLevelDeepPath() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let deepest = try fx.deepPath("deep", levels: 300, fileSize: 4096)
        #expect(deepest.path.utf8.count > Int(PATH_MAX))
        let tree = try await scanTree(fx.root)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        let bottom = try #require(tree.node(atPath: deepest.path + "/bottom.bin"))
        #expect(tree.ancestry(of: bottom).count == 303)
    }

    @Test func hardLinksCountOnceAtTheSmallestPath() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let original = try fx.file("a/orig.bin", size: 64 * 1024)
        try fx.hardLink("a/same-dir.bin", to: "a/orig.bin")
        try fx.hardLink("b/other.bin", to: "a/orig.bin")
        try fx.file("b/plain.bin", size: 8192)
        let tree = try await scanTree(fx.root)
        let oracle = try Oracle.walk(fx.root)
        expectMatchesOracle(tree, oracle)

        let alloc = try #require(oracle.entries.first { $0.path == original.path }).allocatedBytes
        let orig = try #require(tree.node(atPath: original.path))
        let sameDir = try #require(tree.node(atPath: try fx.path("a/same-dir.bin")))
        let other = try #require(tree.node(atPath: try fx.path("b/other.bin")))
        #expect(tree.size(orig) == alloc)
        #expect(tree.flags(orig).contains(.hardLink))
        #expect(!tree.flags(orig).contains(.hardLinkSecondary))
        #expect(tree.flags(sameDir).contains(.hardLinkSecondary))
        #expect(tree.size(sameDir) == 0)
        #expect(tree.sizeInLinks(sameDir) == alloc)
        // Freed only when every link goes.
        #expect(tree.reclaimableBytes(orig, ifAlsoRemoving: []) == 0)
        #expect(tree.reclaimableBytes(orig, ifAlsoRemoving: [sameDir]) == 0)
        #expect(tree.reclaimableBytes(orig, ifAlsoRemoving: [sameDir, other]) == alloc)
        let folderA = try #require(tree.node(atPath: try fx.path("a")))
        let folderB = try #require(tree.node(atPath: try fx.path("b")))
        #expect(tree.reclaimableBytes(folderA, ifAlsoRemoving: []) == 0)
        #expect(tree.reclaimableBytes(folderA, ifAlsoRemoving: [folderB]) == alloc)
        #expect(tree.reclaimableBytes(tree.root, ifAlsoRemoving: []) == tree.size(tree.root))

        // Removing the primary promotes the next smallest path.
        let total = tree.size(tree.root)
        tree.removeSubtree(orig)
        #expect(tree.size(sameDir) == alloc)
        #expect(!tree.flags(sameDir).contains(.hardLinkSecondary))
        #expect(tree.size(tree.root) == total)
    }

    @Test func deletedPrimaryPromotesSecondaryOnRescan() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/first.bin", size: 32 * 1024)
        try fx.hardLink("z/second.bin", to: "a/first.bin")
        let before = try await scanTree(fx.root)
        let second = try #require(before.node(atPath: try fx.path("z/second.bin")))
        #expect(before.flags(second).contains(.hardLinkSecondary))
        unlink(try fx.path("a/first.bin"))
        let after = try await scanTree(fx.root)
        expectMatchesOracle(after, try Oracle.walk(fx.root))
        let promoted = try #require(after.node(atPath: try fx.path("z/second.bin")))
        #expect(!after.flags(promoted).contains(.hardLinkSecondary))
        #expect(after.size(promoted) > 0)
    }

    @Test func apfsClonesCountOnceAndShowAsShared() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let size = 4 * 1024 * 1024
        try fx.file("src.bin", size: size)
        do {
            try fx.clone("copy1.bin", of: "src.bin")
            try fx.clone("dir/copy2.bin", of: "src.bin")
        } catch {
            Issue.record("volume does not support clones: \(error)")
            return
        }
        // Like the oracle (and du) when clones are counted in full.
        let full = try await scanTree(fx.root, countClonesOnce: false)
        let oracle = try Oracle.walk(fx.root)
        expectMatchesOracle(full, oracle)

        let deduped = try await scanTree(fx.root, countClonesOnce: true)
        let alloc = try #require(oracle.entries.first { $0.path.hasSuffix("/src.bin") }).allocatedBytes
        #expect(deduped.size(deduped.root) == alloc)
        let src = try #require(deduped.node(atPath: try fx.path("src.bin")))
        let copy1 = try #require(deduped.node(atPath: try fx.path("copy1.bin")))
        let copy2 = try #require(deduped.node(atPath: try fx.path("dir/copy2.bin")))
        for id in [src, copy1, copy2] {
            #expect(deduped.flags(id).contains(.cloned))
            #expect(deduped.sizeInLinks(id) == alloc)
        }
        // The smallest path carries the shared bytes.
        #expect(deduped.size(copy1) == alloc)
        #expect(deduped.size(src) == 0)
        // Removing one clone frees only its private bytes; removing all frees the shared bytes.
        #expect(deduped.reclaimableBytes(src, ifAlsoRemoving: []) == 0)
        #expect(deduped.reclaimableBytes(src, ifAlsoRemoving: [copy1, copy2]) == alloc)
        #expect(full.reclaimableBytes(full.node(atPath: try fx.path("src.bin"))!, ifAlsoRemoving: []) == 0)
        #expect(deduped.statistics().cloneFamilies == 1)
    }

    @Test func symlinksAreNeverFollowed() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("real/data.bin", size: 16 * 1024)
        try fx.symlink("outside", to: fx.sentinel.path)
        try fx.symlink("loop-a", to: "loop-b")
        try fx.symlink("loop-b", to: "loop-a")
        try fx.symlink("real/up", to: "..")
        try fx.symlink("to-real", to: "real")
        let tree = try await scanTree(fx.root)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        for name in ["outside", "loop-a", "loop-b", "real/up", "to-real"] {
            let id = try #require(tree.node(atPath: try fx.path(name)))
            #expect(tree.flags(id).contains(.symlink))
            #expect(!tree.flags(id).contains(.directory))
            #expect(tree.children(id).isEmpty)
        }
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func sparseFileCountsAllocatedBytes() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.sparseFile("sparse.bin", logicalSize: 1 << 30)
        let allocated = try await scanTree(fx.root)
        expectMatchesOracle(allocated, try Oracle.walk(fx.root))
        let id = try #require(allocated.node(atPath: try fx.path("sparse.bin")))
        #expect(allocated.size(id) < 1 << 20)
        let logical = try await scanTree(fx.root, sizeMode: .logical)
        let logicalID = try #require(logical.node(atPath: try fx.path("sparse.bin")))
        #expect(logical.size(logicalID) == 1 << 30)
        #expect(logical.sizeMode == .logical)
    }

    @Test func packagesAreFlagged() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.appBundle("Tool.app")
        try fx.package("Plug.bundle")
        try fx.package("Kit.framework")
        try fx.file("plain.folder/inside.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        for name in ["Tool.app", "Plug.bundle", "Kit.framework"] {
            let id = try #require(tree.node(atPath: try fx.path(name)))
            #expect(tree.flags(id).contains(.package), "\(name)")
            #expect(ItemKind(flags: tree.flags(id)) == .package)
            #expect(tree.size(id) > 0)
        }
        let plain = try #require(tree.node(atPath: try fx.path("plain.folder")))
        #expect(!tree.flags(plain).contains(.package))
    }

    @Test func unreadableDirectoryIsRestricted() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.restrictedDir("locked", contentSize: 64 * 1024)
        try fx.file("open/visible.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let oracle = try Oracle.walk(fx.root)
        #expect(oracle.restrictedPaths == [try fx.path("locked")])
        expectMatchesOracle(tree, oracle)
        let locked = try #require(tree.node(atPath: try fx.path("locked")))
        #expect(tree.flags(locked).contains(.restricted))
        #expect(tree.size(locked) == 0)
        #expect(tree.children(locked).isEmpty)
        #expect(tree.statistics().restricted == 1)
    }

    @Test func unicodeNames() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        for name in FixtureBuilder.unicodeNames {
            try fx.file("u/\(name)", size: 5000)
        }
        try fx.file("\u{1F4C1} folder/inner\nname.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        expectMatchesOracle(tree, try Oracle.walk(fx.root))
        for name in FixtureBuilder.unicodeNames {
            let id = try #require(tree.node(atPath: try fx.path("u/\(name)")))
            #expect(Array(tree.name(id).utf8) == Array(name.utf8))
        }
    }

    @Test func excludedPathsAreSkipped() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("keep/a.bin", size: 8192)
        try fx.file("skip/b.bin", size: 64 * 1024)
        try fx.file("keep/skip-me.bin", size: 4096)
        let tree = try await scanTree(fx.root, excluded: [try fx.path("skip"), try fx.path("keep/skip-me.bin")])
        #expect(tree.node(atPath: try fx.path("skip")) == nil)
        #expect(tree.node(atPath: try fx.path("keep/skip-me.bin")) == nil)
        let keep = try #require(tree.node(atPath: try fx.path("keep")))
        #expect(tree.size(tree.root) == tree.size(keep))
    }

    @Test func workerCountDoesNotChangeTheTree() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        for folder in 0..<20 {
            for file in 0..<25 {
                try fx.file("f\(folder)/sub\(file % 3)/x\(file).bin", size: (file + 1) * 1000)
            }
        }
        try fx.hardLink("f1/link.bin", to: "f0/sub0/x0.bin")
        _ = try? fx.clone("f2/clone.bin", of: "f0/sub1/x1.bin")
        try fx.deepPath("f3/deep", levels: 40)
        let one = try await scanTree(fx.root, workers: 1, countClonesOnce: true)
        let many = try await scanTree(fx.root, workers: 32, countClonesOnce: true)
        #expect(fingerprint(one) == fingerprint(many))
    }

    /// Creates `folders` x `perFolder` empty directories quickly.
    private func makeManyDirectories(_ fx: FixtureBuilder, folders: Int, perFolder: Int) throws {
        for folder in 0..<folders {
            let base = try fx.dir("d\(folder)").path
            for index in 0..<perFolder {
                mkdir(base + "/e\(index)", 0o755)
            }
        }
    }

    @Test func progressIsMonotonicAndEndsAtOne() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try makeManyDirectories(fx, folders: 60, perFolder: 100)
        let scanner = Scanner(ScanOptions(root: fx.root, workers: 1))
        var fractions: [Double] = []
        var finished = false
        for await event in scanner.start() {
            switch event {
            case .progress(let progress): fractions.append(progress.fraction ?? 0)
            case .finished: finished = true
            case .failed(let error): Issue.record("failed: \(error)")
            }
        }
        #expect(finished)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1.0)
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func cancelStopsWithin200Milliseconds() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try makeManyDirectories(fx, folders: 200, perFolder: 100)
        let scanner = Scanner(ScanOptions(root: fx.root, workers: 1))
        let clock = ContinuousClock()
        var cancelledAt: ContinuousClock.Instant?
        var stopped: Duration?
        var finishedFirst = false
        for await event in scanner.start() {
            switch event {
            case .progress:
                if cancelledAt == nil {
                    cancelledAt = clock.now
                    scanner.cancel()
                }
            case .failed(let error):
                #expect(error == .cancelled)
                if let cancelledAt { stopped = clock.now - cancelledAt }
            case .finished:
                finishedFirst = true
            }
        }
        #expect(!finishedFirst, "scan finished before it could be cancelled")
        let elapsed = try #require(stopped)
        #expect(elapsed < .milliseconds(200), "cancel took \(elapsed)")
    }

    @Test func watchdogGivesUpOnStuckFolders() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("ok/a.bin", size: 8192)
        try fx.file("stuck/b.bin", size: 8192)
        var config = try EngineConfig.resolve(ScanOptions(root: fx.root, workers: 2)).get()
        config.watchdogTimeout = .milliseconds(300)
        let stuckPath = Array(try fx.path("stuck").utf8)
        config.beforeOpen = { path in
            if path == stuckPath { Thread.sleep(forTimeInterval: 1.5) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let tree = try Scanner(ScanOptions(root: fx.root)).run(config: config).get()
        #expect(clock.now - start < .milliseconds(1200))
        let stuck = try #require(tree.node(atPath: try fx.path("stuck")))
        #expect(tree.flags(stuck).contains(.notResponding))
        #expect(!tree.flags(stuck).contains(.restricted))
        #expect(tree.size(stuck) == 0)
        #expect(tree.children(stuck).isEmpty)
        #expect(tree.unresponsiveFolders == [stuck])
        let ok = try #require(tree.node(atPath: try fx.path("ok/a.bin")))
        #expect(tree.size(ok) > 0)
        // The late return of the stuck call changes nothing.
        let total = tree.size(tree.root)
        try await Task.sleep(for: .milliseconds(1700))
        #expect(tree.size(tree.root) == total)
        #expect(tree.children(stuck).isEmpty)
    }

    @Test func watchdogFailsWhenNothingResponds() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        var config = try EngineConfig.resolve(ScanOptions(root: fx.root, workers: 1)).get()
        config.watchdogTimeout = .milliseconds(200)
        config.beforeOpen = { _ in Thread.sleep(forTimeInterval: 0.8) }
        let result = Scanner(ScanOptions(root: fx.root)).run(config: config)
        #expect(throws: ScanError.notResponding(path: fx.root.path)) { try result.get() }
    }

    @Test func loneCloneInAFolderScanFreesOnlyPrivateBytes() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("elsewhere/original.bin", size: 2 * 1024 * 1024)
        do {
            try fx.clone("scanned/duplicate.bin", of: "elsewhere/original.bin")
        } catch {
            Issue.record("volume does not support clones: \(error)")
            return
        }
        let tree = try await scanTree(try fx.url("scanned"), countClonesOnce: true)
        let duplicate = try #require(tree.node(atPath: try fx.path("scanned/duplicate.bin")))
        #expect(tree.flags(duplicate).contains(.cloned))
        #expect(tree.size(duplicate) >= 2 * 1024 * 1024)
        // Every block is shared with the original outside the scan: nothing would be freed.
        #expect(tree.reclaimableBytes(duplicate, ifAlsoRemoving: []) == 0)
        #expect(tree.reclaimableBytes(tree.root, ifAlsoRemoving: []) == 0)
    }

    @Test func secondStartIsCancelledToo() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try makeManyDirectories(fx, folders: 100, perFolder: 100)
        let scanner = Scanner(ScanOptions(root: fx.root, workers: 1))
        let first = scanner.start()
        let second = scanner.start()
        try await Task.sleep(for: .milliseconds(30))
        scanner.cancel()
        func outcome(_ stream: AsyncStream<ScanEvent>) async -> String {
            var last = "none"
            for await event in stream {
                switch event {
                case .finished: last = "finished"
                case .failed(let error): last = "\(error)"
                case .progress: break
                }
            }
            return last
        }
        #expect(await outcome(first) == "cancelled")
        #expect(await outcome(second) == "cancelled")
    }

    @Test func cancelBeforeStartFailsImmediately() async {
        let scanner = Scanner(ScanOptions(root: URL(fileURLWithPath: NSTemporaryDirectory())))
        scanner.cancel()
        var events: [String] = []
        for await event in scanner.start() {
            if case .failed(let error) = event { events.append("\(error)") }
        }
        #expect(events == ["cancelled"])
    }

    @Test func rootErrors() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let file = try fx.file("file.bin", size: 10)
        try fx.restrictedDir("locked")
        func failure(_ url: URL) async -> ScanError? {
            for await event in Scanner(ScanOptions(root: url)).start() {
                if case .failed(let error) = event { return error }
            }
            return nil
        }
        let missing = try fx.url("missing")
        #expect(await failure(missing) == .rootNotFound(path: missing.path))
        #expect(await failure(file) == .rootNotReadable(path: file.path, errno: ENOTDIR))
        let locked = try fx.url("locked")
        #expect(await failure(locked) == .rootNotReadable(path: locked.path, errno: EACCES))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTWELL_TEST_HDIUTIL"] == "1"))
    func diskImageMountPointIsALeaf() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let image = try fx.path("image.dmg")
        let mount = try fx.dir("mnt")
        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run(["create", "-size", "8m", "-fs", "HFS+", "-volname", "LightwellTest", image]) == 0)
        #expect(try run(["attach", "-nobrowse", "-mountpoint", mount.path, image]) == 0)
        defer { _ = try? run(["detach", mount.path, "-force"]) }
        try Data(repeating: 1, count: 100_000).write(to: mount.appendingPathComponent("inside.bin"))
        try fx.file("outside.bin", size: 4096)
        let tree = try await scanTree(fx.root)
        let id = try #require(tree.node(atPath: mount.path))
        #expect(tree.flags(id).contains(.mountPoint))
        #expect(tree.size(id) == 0)
        #expect(tree.children(id).isEmpty)
    }
}
