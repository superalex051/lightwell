import Foundation
import ScanKit
import Testing
@testable import TestSupport

@Suite("InMemoryTree")
struct InMemoryTreeTests {
    private func sample() -> InMemoryTree {
        InMemoryTree(rootPath: "/fx", entries: [
            .dir("Library", [
                .dir("Caches", [.file("a.bin", 300), .file("b.bin", 100)]),
                .restricted("Mail"),
            ]),
            .package("Tool.app", [.file("Contents", 50)]),
            .file("big.mov", 1_000),
            .symlink("link"),
        ])
    }

    @Test func sizesAggregateAndChildrenSortBySize() throws {
        let tree = sample()
        #expect(tree.size(tree.root) == 1_450)
        #expect(tree.children(tree.root).map(tree.name) == ["big.mov", "Library", "Tool.app", "link"])
        let caches = try #require(tree.node(atPath: "/fx/Library/Caches"))
        #expect(tree.size(caches) == 400)
        #expect(tree.path(caches) == "/fx/Library/Caches")
        #expect(tree.descendantCount(tree.root) == 9)
        #expect(tree.flags(try #require(tree.node(atPath: "/fx/Tool.app"))).contains(.package))
        #expect(tree.flags(try #require(tree.node(atPath: "/fx/Library/Mail"))).contains(.restricted))
        #expect(tree.node(atPath: "/fx/missing") == nil)
        #expect(tree.node(atPath: "/fx") == tree.root)
        #expect(tree.summary(of: caches).items == 2)
    }

    @Test func removeSubtreeUpdatesAncestorsAndGeneration() throws {
        let tree = sample()
        let before = tree.generation
        let caches = try #require(tree.node(atPath: "/fx/Library/Caches"))
        tree.removeSubtree(caches)
        #expect(tree.generation > before)
        #expect(tree.size(tree.root) == 1_050)
        #expect(tree.node(atPath: "/fx/Library/Caches") == nil)
        #expect(tree.size(caches) == 0)
    }

    @Test func hardLinksCountOnceAndFreeOnlyWithAllLinks() throws {
        let tree = InMemoryTree(rootPath: "/fx")
        let z = tree.addDirectory("z", under: tree.root)
        let a = tree.addDirectory("a", under: tree.root)
        let original = tree.addFile("orig.bin", size: 500, under: z)
        let link = tree.addHardLink("link.bin", under: a, to: original)
        #expect(tree.size(tree.root) == 500)
        #expect(tree.size(a) == 500) // "/fx/a/link.bin" sorts first, so it is primary
        #expect(tree.flags(original).contains(.hardLinkSecondary))
        #expect(tree.reclaimableBytes(a, ifAlsoRemoving: []) == 0)
        #expect(tree.reclaimableBytes(a, ifAlsoRemoving: [z]) == 500)
        tree.removeSubtree(a)
        #expect(tree.size(z) == 500)
        #expect(!tree.flags(original).contains(.hardLinkSecondary))
        _ = link
    }

    @Test func clonesShareBytesOnce() throws {
        let tree = InMemoryTree(rootPath: "/fx")
        let source = tree.addFile("a.bin", size: 4_000, under: tree.root)
        let clone = tree.addClone("b.bin", under: tree.root, of: source, privateBytes: 100)
        #expect(tree.size(tree.root) == 4_100)
        #expect(tree.reclaimableBytes(clone, ifAlsoRemoving: []) == 100)
        #expect(tree.reclaimableBytes(clone, ifAlsoRemoving: [source]) == 4_100)

        let counted = InMemoryTree(rootPath: "/fx", countClonesOnce: false)
        let s2 = counted.addFile("a.bin", size: 4_000, under: counted.root)
        counted.addClone("b.bin", under: counted.root, of: s2)
        #expect(counted.size(counted.root) == 8_000)
    }

    @Test func snapshotOfDiskMatchesOracle() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.file("Library/Caches/x.bin", size: 70_000)
        try fx.hardLink("Library/Caches/y.bin", to: "Library/Caches/x.bin")
        try fx.appBundle("Applications/Demo.app")
        try fx.restrictedDir("Library/Keychains")
        try fx.symlink("shortcut", to: "Library")
        let oracle = try Oracle.walk(fx.root)
        let tree = try InMemoryTree.snapshot(of: fx.root)
        #expect(tree.size(tree.root) == oracle.totalBytes)
        let app = try #require(tree.node(atPath: try fx.path("Applications/Demo.app")))
        #expect(tree.flags(app).contains(.package))
        #expect(tree.size(app) == oracle.bytes(at: try fx.path("Applications/Demo.app")))
        let keychains = try #require(tree.node(atPath: try fx.path("Library/Keychains")))
        #expect(tree.flags(keychains).contains(.restricted))
        #expect(tree.identity(try #require(tree.node(atPath: try fx.path("Library/Caches/x.bin")))) != nil)
    }

    @Test func samplesAreReachable() throws {
        #expect(try Samples.all().contains("02-mcp-partial.jsonl"))
        #expect(try !Samples.lines("01-basic-stream-json.jsonl").isEmpty)
    }

    @Test func snapshotOfDeepFixtureIsIterative() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.deepPath("deep", levels: 300, fileSize: 8192)
        let oracle = try Oracle.walk(fx.root)
        let tree = try InMemoryTree.snapshot(of: fx.root)
        #expect(tree.size(tree.root) == oracle.totalBytes)
        #expect(tree.descendantCount(tree.root) == UInt32(oracle.entries.count))
    }
}

