import Darwin
import Foundation
import ScanKit
import Testing
@testable import TestSupport

private func allocated(_ path: String) -> UInt64 {
    var st = stat()
    precondition(lstat(path, &st) == 0)
    return UInt64(st.st_blocks) * 512
}

@Suite("FixtureBuilder and Oracle")
struct FixtureBuilderTests {
    @Test func fixtureLivesUnderTmpAndIsRemoved() throws {
        let fx = try FixtureBuilder()
        let root = fx.root.path
        let sentinel = fx.sentinel.path
        #expect(root.hasPrefix(FixtureBuilder.fixtureArea.path + "/"))
        #expect(FileManager.default.fileExists(atPath: root))
        try fx.restrictedDir("locked")
        try fx.deepPath("deep", levels: 20)
        fx.tearDown()
        #expect(!FileManager.default.fileExists(atPath: root))
        #expect(!FileManager.default.fileExists(atPath: sentinel))
        fx.tearDown() // idempotent
    }

    @Test func rejectsEscapingPaths() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        #expect(throws: FixtureError.self) { try fx.file("../outside.bin", size: 1) }
        #expect(throws: FixtureError.self) { try fx.dir("/etc/nope") }
        #expect(throws: FixtureError.self) { try fx.url("a/../../b") }
    }

    @Test func exactSizesMatchOracle() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("a/one.bin", size: 1)
        try fx.file("a/b/two.bin", size: 10_000)
        try fx.file("c/three.bin", size: 1_048_576)
        try fx.dir("empty")
        let result = try Oracle.walk(fx.root)
        let expected = try ["a/one.bin", "a/b/two.bin", "c/three.bin"].map { allocated(try fx.path($0)) }.reduce(0, +)
        #expect(result.totalBytes == expected)
        #expect(result.fileCount == 3)
        #expect(result.directoryCount == 4)
        #expect(result.bytes(at: try fx.path("a")) == allocated(try fx.path("a/one.bin")) + allocated(try fx.path("a/b/two.bin")))
        #expect(result.bytes(at: try fx.path("empty")) == 0)
        #expect(try Data(contentsOf: fx.url("a/b/two.bin")).count == 10_000)
        #expect(fx.sentinelChanges().isEmpty)
    }

    @Test func hardLinksCountOnceAtSmallestPath() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("z/original.bin", size: 100_000)
        try fx.hardLink("a/link.bin", to: "z/original.bin")
        try fx.hardLink("z/same-dir.bin", to: "z/original.bin")
        let result = try Oracle.walk(fx.root)
        #expect(result.totalBytes == allocated(try fx.path("z/original.bin")))
        let primaries = result.entries.filter { $0.kind == .file && $0.isPrimary }
        #expect(primaries.map(\.path) == [try fx.path("a/link.bin")])
        #expect(result.bytes(at: try fx.path("z")) == 0)
    }

    @Test func clonesAreCreatedAndCountedFullyByOracle() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("src.bin", size: 4 * 1_048_576)
        try fx.clone("copy.bin", of: "src.bin")
        let result = try Oracle.walk(fx.root)
        let entries = result.entries.filter { $0.kind == .file }
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.identity.inode)).count == 2)
        #expect(result.totalBytes == 2 * allocated(try fx.path("src.bin")))
    }

    @Test func symlinksAreNeverFollowed() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("real/data.bin", size: 50_000)
        try fx.symlink("links/to-real", to: "../real")
        try fx.symlink("links/to-sentinel", to: fx.sentinel.path)
        try fx.symlink("links/loop", to: "loop")
        let result = try Oracle.walk(fx.root)
        #expect(result.symlinkCount == 3)
        #expect(result.totalBytes == allocated(try fx.path("real/data.bin")) + result.entries.filter { $0.kind == .symlink }.map(\.allocatedBytes).reduce(0, +))
        #expect(!result.entries.contains { $0.path.hasPrefix(fx.sentinel.path) || $0.path.contains("to-real/") })
    }

    @Test func sparseFileAllocatesLittle() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.sparseFile("sparse.img", logicalSize: 1 << 30)
        let entry = try #require(try Oracle.walk(fx.root).entries.first)
        #expect(entry.logicalBytes == 1 << 30)
        #expect(entry.allocatedBytes < 1 << 20)
    }

    @Test func packagesRestrictedAndUnicode() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.appBundle("Apps/Tool.app")
        try fx.package("Apps/Plug.bundle")
        try fx.restrictedDir("Private/locked", contentSize: 8192)
        for (index, name) in FixtureBuilder.unicodeNames.enumerated() {
            try fx.file("names/\(name)", size: 100 + index)
        }
        let result = try Oracle.walk(fx.root)
        #expect(result.restrictedPaths == [try fx.path("Private/locked")])
        #expect(result.bytes(at: try fx.path("Private")) == 0)
        #expect(FileManager.default.fileExists(atPath: try fx.path("Apps/Tool.app/Contents/Info.plist")))
        let names = Set(result.entries.map { ($0.path as NSString).lastPathComponent })
        for name in FixtureBuilder.unicodeNames {
            #expect(names.contains(name))
        }
    }

    @Test func manyFilesAndDeepPaths() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.manyFiles(in: "many", count: 1_000, size: 10)
        let deepest = try fx.deepPath("deep", levels: 300, fileSize: 4096)
        #expect(deepest.path.utf8.count > Int(PATH_MAX))
        let result = try Oracle.walk(fx.root)
        #expect(result.fileCount == 1_001)
        #expect(result.entries.contains { $0.path.hasSuffix("/d299/bottom.bin") })
    }

    @Test func lockedFilesAreClearedAndRemovedOnTeardown() throws {
        let fx = try FixtureBuilder()
        let locked = try fx.lockedFile("Library/locked.bin", size: 4096)
        var st = stat()
        #expect(lstat(locked.path, &st) == 0)
        #expect(st.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(unlink(locked.path) != 0) // immutable until cleared
        let root = fx.root.path
        fx.tearDown()
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test func staleFixturesAreSweptOnInit() throws {
        let area = FixtureBuilder.fixtureArea
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let stale = area.appendingPathComponent(UUID().uuidString)
        let staleSentinel = area.appendingPathComponent(stale.lastPathComponent + "-sentinel")
        let fresh = area.appendingPathComponent(UUID().uuidString)
        let notUUID = area.appendingPathComponent("keep-me-\(UUID().uuidString)")
        for dir in [stale, staleSentinel, fresh, notUUID] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("x.bin"))
        }
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        for dir in [stale, staleSentinel, notUUID] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: dir.path)
        }
        let recentButOld = Date().addingTimeInterval(-2 * 3600) // older than an hour, younger than a day
        try FileManager.default.setAttributes([.modificationDate: recentButOld], ofItemAtPath: fresh.path)
        defer {
            for dir in [stale, staleSentinel, fresh, notUUID] { try? FileManager.default.removeItem(at: dir) }
        }

        let fx = try FixtureBuilder()
        defer { fx.tearDown() }

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: staleSentinel.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: notUUID.path))
        #expect(FileManager.default.fileExists(atPath: fx.root.path))
    }

    @Test func oracleRefusesSymlinkedRoot() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("real/data.bin", size: 4096)
        let link = try fx.symlink("link-to-real", to: try fx.path("real"))
        #expect(throws: FixtureError.self) { try Oracle.walk(link) }
        #expect(try Oracle.walk(fx.url("real")).fileCount == 1)
    }

    @Test func sweepRefusesSymlinkedArea() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)

        // A private stand-in for TMPDIR whose lightwell-fixtures entry is a symlink to a decoy.
        let fakeTmp = try fx.dir("tmp")
        try fx.dir("decoy")
        let decoyVictim = try fx.dir("decoy/\(UUID().uuidString)")
        try fx.file("decoy/\(decoyVictim.lastPathComponent)/precious.bin", size: 100)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: decoyVictim.path)
        try fx.symlink("tmp/lightwell-fixtures", to: try fx.path("decoy"))

        FixtureBuilder.sweepStaleFixtures(area: fakeTmp.appendingPathComponent("lightwell-fixtures"))
        #expect(FileManager.default.fileExists(atPath: decoyVictim.appendingPathComponent("precious.bin").path))

        // Control: the same layout behind a real directory is swept.
        let realArea = try fx.dir("tmp2/lightwell-fixtures")
        let stale = try fx.dir("tmp2/lightwell-fixtures/\(UUID().uuidString)")
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: stale.path)
        FixtureBuilder.sweepStaleFixtures(area: realArea)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(fx.sentinelChanges().isEmpty)
    }
}
