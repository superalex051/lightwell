import Foundation
import Testing
import TestSupport
@testable import ScanKit

/// WS2 query API: largest, paged children, search, node(atPath:), summaries.
@Suite("Queries")
struct QueryTests {
    private func sample() -> ScanTree {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        let library = builder.addDirectory("Library", under: builder.root)
        let caches = builder.addDirectory("Caches", under: library)
        builder.addFile("cache-a.db", size: 4000, under: caches)
        builder.addFile("cache-b.db", size: 9000, under: caches)
        let app = builder.addDirectory("Big.app", under: builder.root)
        builder.addFile("binary", size: 50_000, under: app)
        builder.addFile("small", size: 10, under: app)
        let movies = builder.addDirectory("Movies", under: builder.root)
        builder.addFile("Holiday.MOV", size: 70_000, under: movies)
        builder.addFile("clip.mov", size: 20_000, under: movies)
        builder.addFile("notes.txt", size: 30, under: builder.root)
        builder.addFile("Caf\u{E9} menu.txt", size: 300, under: builder.root)
        return builder.build()
    }

    @Test func largestTreatsPackagesAsOneItem() {
        let tree = sample()
        let items = tree.largest(under: tree.root, limit: 3)
        #expect(items.map(\.name) == ["Holiday.MOV", "Big.app", "clip.mov"])
        #expect(items[1].kind == .package)
        #expect(items[1].bytes == 50_010)
        #expect(items.allSatisfy { $0.freesAbout == $0.bytes })
        let big = tree.largest(under: tree.root, limit: 10, minBytes: 9000)
        #expect(big.map(\.name) == ["Holiday.MOV", "Big.app", "clip.mov", "cache-b.db"])
    }

    @Test func largestSkipsPlaceholderFolders() {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        builder.addDirectory("locked", under: builder.root, flags: .restricted)
        builder.addDirectory("Volume", under: builder.root, flags: .mountPoint)
        builder.addDirectory("Users", under: builder.root, flags: .firmlinkSkipped)
        builder.addDirectory("share", under: builder.root, flags: .notResponding)
        builder.addDirectory("empty", under: builder.root)
        builder.addFile("zero.txt", size: 0, under: builder.root)
        builder.addFile("data.bin", size: 4096, under: builder.root)
        let tree = builder.build()
        #expect(tree.largest(under: tree.root, limit: 10).map(\.name) == ["data.bin", "zero.txt"])
    }

    @Test func largestDescendsPlaceholderFoldersThatKeptChildren() {
        // A folder whose refresh timed out keeps its earlier children.
        let builder = ScanTreeBuilder(rootPath: "/fx")
        let share = builder.addDirectory("share", under: builder.root, flags: .notResponding)
        builder.addFile("kept.mov", size: 90_000, under: share)
        let partial = builder.addDirectory("partial", under: builder.root, flags: .restricted)
        builder.addFile("listed.bin", size: 50_000, under: partial)
        builder.addFile("other.bin", size: 10_000, under: builder.root)
        let tree = builder.build()
        #expect(tree.largest(under: tree.root, limit: 10).map(\.name) == ["kept.mov", "listed.bin", "other.bin"])
    }

    @Test func largestMatchesTheGenericPath() throws {
        let tree = sample()
        let fake = InMemoryTree(rootPath: "/fx", entries: [
            .dir("Library", [.dir("Caches", [.file("cache-a.db", 4000), .file("cache-b.db", 9000)])]),
            .package("Big.app", [.file("binary", 50_000), .file("small", 10)]),
            .dir("Movies", [.file("Holiday.MOV", 70_000), .file("clip.mov", 20_000)]),
            .file("notes.txt", 30), .file("Caf\u{E9} menu.txt", 300),
        ])
        #expect(tree.largest(under: tree.root, limit: 5).map(\.path) == fake.largest(under: fake.root, limit: 5).map(\.path))
        #expect(tree.search("mov", under: tree.root, limit: 10).map(\.path) == fake.search("mov", under: fake.root, limit: 10).map(\.path))
    }

    @Test func searchIsCaseInsensitiveAndIncludesFolders() {
        let tree = sample()
        #expect(tree.search("mov", under: tree.root, limit: 10).map(\.name) == ["Movies", "Holiday.MOV", "clip.mov"])
        #expect(tree.search("CACHE", under: tree.root, limit: 10).map(\.name) == ["Caches", "cache-b.db", "cache-a.db"])
        #expect(tree.search("cache", under: tree.root, limit: 1).map(\.name) == ["Caches"])
        #expect(tree.search("caf\u{E9}", under: tree.root, limit: 10).map(\.name) == ["Caf\u{E9} menu.txt"])
        #expect(tree.search("CAFE\u{301}", under: tree.root, limit: 10).map(\.name) == ["Caf\u{E9} menu.txt"])
        #expect(tree.search("zzz", under: tree.root, limit: 10).isEmpty)
        #expect(tree.search("", under: tree.root, limit: 10).isEmpty)
        let library = tree.node(atPath: "/fx/Library")!
        #expect(tree.search("db", under: library, limit: 10, minBytes: 5000).map(\.name) == ["cache-b.db"])
    }

    @Test func pagedChildrenAreStableAndDetectStaleCursors() throws {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        var files: [NodeID] = []
        for index in 0..<25 {
            files.append(builder.addFile("f\(index)", size: UInt64(1000 - index), under: builder.root))
        }
        let tree = builder.build()
        let first = try tree.children(of: tree.root, limit: 10)
        #expect(first.total == 25)
        #expect(first.items.map(\.name) == (0..<10).map { "f\($0)" })
        let cursor = try #require(first.next)
        #expect(PageCursor(token: cursor.token) == cursor)
        let second = try tree.children(of: tree.root, limit: 10, after: cursor)
        #expect(second.items.map(\.name) == (10..<20).map { "f\($0)" })
        let third = try tree.children(of: tree.root, limit: 10, after: second.next)
        #expect(third.items.count == 5)
        #expect(third.next == nil)

        // A mutation invalidates outstanding cursors.
        let stale = try #require(second.next)
        tree.removeSubtree(files[0])
        #expect(throws: QueryError.staleCursor(cursorGeneration: stale.generation, treeGeneration: tree.generation)) {
            try tree.children(of: tree.root, limit: 10, after: stale)
        }
        #expect(throws: QueryError.cursorMismatch) {
            try tree.children(of: files[3], limit: 10, after: PageCursor(parent: tree.root, generation: tree.generation, offset: 0))
        }
        #expect(PageCursor(token: "nonsense") == nil)
    }

    @Test func summaryBuilderHook() {
        let tree = sample()
        let movies = tree.node(atPath: "/fx/Movies")!
        let builder = ItemSummaryBuilder { _, _ in 42 }
        #expect(tree.summary(of: movies, using: builder).freesAbout == 42)
        let summary = tree.summary(of: movies)
        #expect(summary.freesAbout == 90_000)
        #expect(summary.items == 2)
        #expect(summary.kind == .directory)
        #expect(summary.path == "/fx/Movies")
        #expect(tree.largest(under: tree.root, limit: 1, builder: builder).first?.freesAbout == 42)
    }

    /// WS2 acceptance: queries on a 1M-node tree take under 50 ms (optimized builds; debug
    /// builds only check that they finish).
    @Test func queriesOnAMillionNodes() throws {
        let builder = ScanTreeBuilder(rootPath: "/big")
        var folder = builder.root
        var level1 = builder.root
        for index in 0..<1_000_000 {
            if index % 1000 == 0 {
                level1 = builder.addDirectory("group-\(index / 1000)", under: builder.root)
            }
            if index % 50 == 0 {
                folder = builder.addDirectory("folder-\(index / 50)", under: level1)
                continue
            }
            builder.addFile("item-\(index).bin", size: UInt64((index * 7919) % 100_000), under: folder)
        }
        let tree = builder.build()
        #expect(tree.descendantCount(tree.root) >= 1_000_000)
        let clock = ContinuousClock()
        var worst: Duration = .zero
        func measure<T>(_ body: () throws -> T) rethrows -> T {
            let start = clock.now
            let result = try body()
            worst = max(worst, clock.now - start)
            return result
        }
        #expect(measure { tree.largest(under: tree.root, limit: 50) }.count == 50)
        #expect(measure { tree.search("item-123456.", under: tree.root, limit: 50) }.count == 1)
        #expect(try measure { try tree.children(of: tree.root, limit: 100) }.items.count == 100)
        #expect(measure { tree.node(atPath: "/big/group-999/folder-19999/item-999999.bin") } != nil)
        #if DEBUG
        #expect(worst < .seconds(10), "worst query \(worst)")
        #else
        #expect(worst < .milliseconds(50), "worst query \(worst)")
        #endif
        print("queriesOnAMillionNodes worst query: \(worst)")
    }
}
