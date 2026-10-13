import Foundation
import Testing
import TestSupport
@testable import ScanKit

/// PLAN 5.1 "Tree": mutations, generation, reclaimable estimates, stride and footprint.
@Suite("ScanTree")
struct ScanTreeTests {
    /// /fx
    ///   Library/Caches/{a.bin 4000, b.bin 6000}
    ///   Movies/big.mov 100000
    ///   notes.txt 10
    private func sampleTree() -> (ScanTree, [String: NodeID]) {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        var ids: [String: NodeID] = [:]
        ids["Library"] = builder.addDirectory("Library", under: builder.root)
        ids["Caches"] = builder.addDirectory("Caches", under: ids["Library"]!)
        ids["a"] = builder.addFile("a.bin", size: 4000, under: ids["Caches"]!)
        ids["b"] = builder.addFile("b.bin", size: 6000, under: ids["Caches"]!)
        ids["Movies"] = builder.addDirectory("Movies", under: builder.root)
        ids["big"] = builder.addFile("big.mov", size: 100_000, under: ids["Movies"]!)
        ids["notes"] = builder.addFile("notes.txt", size: 10, under: builder.root)
        return (builder.build(), ids)
    }

    @Test func nodeStrideIsAtMost32Bytes() {
        #expect(MemoryLayout<Node>.stride <= 32)
    }

    @Test func builderAggregatesAndSorts() throws {
        let (tree, ids) = sampleTree()
        #expect(tree.size(tree.root) == 110_010)
        #expect(tree.size(ids["Caches"]!) == 10_000)
        #expect(tree.descendantCount(tree.root) == 7)
        #expect(tree.children(tree.root) == [ids["Movies"]!, ids["Library"]!, ids["notes"]!])
        #expect(tree.children(ids["Caches"]!) == [ids["b"]!, ids["a"]!])
        #expect(tree.path(ids["a"]!) == "/fx/Library/Caches/a.bin")
        #expect(tree.node(atPath: "/fx/Library/Caches/a.bin") == ids["a"])
        #expect(tree.node(atPath: "/fx/Library/Caches/") == ids["Caches"])
        #expect(tree.node(atPath: "/fx") == tree.root)
        #expect(tree.node(atPath: "/fxx/Library") == nil)
        #expect(tree.node(atPath: "/other") == nil)
        #expect(tree.parent(ids["a"]!) == ids["Caches"])
        #expect(tree.ancestry(of: ids["a"]!) == [tree.root, ids["Library"]!, ids["Caches"]!, ids["a"]!])
    }

    @Test func slashRootPaths() throws {
        let builder = ScanTreeBuilder(rootPath: "/")
        let users = builder.addDirectory("Users", under: builder.root)
        let file = builder.addFile("x.bin", size: 5, under: users)
        let tree = builder.build()
        #expect(tree.name(tree.root) == "/")
        #expect(tree.path(file) == "/Users/x.bin")
        #expect(tree.node(atPath: "/Users/x.bin") == file)
        #expect(tree.node(atPath: "/") == tree.root)
    }

    @Test func removeSubtreeUpdatesAncestorsAndGeneration() throws {
        let (tree, ids) = sampleTree()
        let before = tree.generation
        tree.removeSubtree(ids["b"]!)
        #expect(tree.generation > before)
        #expect(tree.size(ids["Caches"]!) == 4000)
        #expect(tree.size(ids["Library"]!) == 4000)
        #expect(tree.size(tree.root) == 104_010)
        #expect(tree.descendantCount(tree.root) == 6)
        #expect(tree.children(ids["Caches"]!) == [ids["a"]!])
        #expect(tree.node(atPath: "/fx/Library/Caches/b.bin") == nil)
        #expect(tree.size(ids["b"]!) == 0)
        tree.removeSubtree(ids["Library"]!)
        #expect(tree.size(tree.root) == 100_010)
        #expect(tree.descendantCount(tree.root) == 3)
        // Removing the root or a removed node is a no-op.
        let generation = tree.generation
        tree.removeSubtree(tree.root)
        tree.removeSubtree(ids["Library"]!)
        #expect(tree.generation == generation)
    }

    @Test func removalResortsAncestors() throws {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        let a = builder.addDirectory("a", under: builder.root)
        let b = builder.addDirectory("b", under: builder.root)
        let a1 = builder.addFile("1", size: 600, under: a)
        builder.addFile("2", size: 100, under: a)
        builder.addFile("3", size: 500, under: b)
        let tree = builder.build()
        #expect(tree.children(tree.root) == [a, b])
        tree.removeSubtree(a1)
        #expect(tree.children(tree.root) == [b, a])
    }

    @Test func markMissingZeroesSizeAndUpdatesAncestors() throws {
        let (tree, ids) = sampleTree()
        let before = tree.generation
        tree.markMissing(ids["Caches"]!)
        #expect(tree.generation > before)
        #expect(tree.flags(ids["Caches"]!).contains(.missing))
        #expect(tree.size(ids["Caches"]!) == 0)
        #expect(tree.size(ids["a"]!) == 0)
        #expect(tree.size(ids["Library"]!) == 0)
        #expect(tree.size(tree.root) == 100_010)
        // Removing a missing subtree afterwards keeps totals consistent.
        tree.removeSubtree(ids["Caches"]!)
        #expect(tree.size(tree.root) == 100_010)
        #expect(tree.descendantCount(tree.root) == 4)
    }

    @Test func replaceChildrenSplicesAFreshScan() throws {
        let (tree, ids) = sampleTree()
        let fresh = ScanTreeBuilder(rootPath: "/fx/Library/Caches")
        let sub = fresh.addDirectory("sub", under: fresh.root)
        fresh.addFile("new.bin", size: 7000, under: sub)
        fresh.addFile("c.bin", size: 1, under: fresh.root)
        let before = tree.generation
        tree.replaceChildren(of: ids["Caches"]!, with: fresh.build())
        #expect(tree.generation > before)
        #expect(tree.size(ids["Caches"]!) == 7001)
        #expect(tree.size(ids["Library"]!) == 7001)
        #expect(tree.size(tree.root) == 107_011)
        #expect(tree.descendantCount(ids["Caches"]!) == 3)
        #expect(tree.descendantCount(tree.root) == 8)
        #expect(tree.node(atPath: "/fx/Library/Caches/a.bin") == nil)
        let newFile = try #require(tree.node(atPath: "/fx/Library/Caches/sub/new.bin"))
        #expect(tree.size(newFile) == 7000)
        #expect(tree.parent(tree.parent(newFile)!) == ids["Caches"])
    }

    @Test func reclaimableWithPartialHardLinkAndCloneSets() throws {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        let a = builder.addDirectory("a", under: builder.root)
        let b = builder.addDirectory("b", under: builder.root)
        // Hard-linked inode with 3 links, all in the tree.
        let h1 = builder.addFile("h1", size: 8000, under: a, inode: 77, linkCount: 3)
        let h2 = builder.addFile("h2", size: 8000, under: a, inode: 77, linkCount: 3)
        let h3 = builder.addFile("h3", size: 8000, under: b, inode: 77, linkCount: 3)
        // Inode with 2 links, only one in the tree: never freed.
        let lone = builder.addFile("lone", size: 5000, under: b, inode: 88, linkCount: 2)
        // Clone family: 10240 bytes each (20 units of 512), 1024 private each.
        let c1 = builder.addFile("c1", size: 10_240, under: a, cloneID: 5, privateBytes: 1024)
        let c2 = builder.addFile("c2", size: 10_240, under: b, cloneID: 5, privateBytes: 1024)
        let tree = builder.build()

        // Accounting: inode once (8000), lone 5000, clones 1024 + 1024 + shared 9216 once.
        #expect(tree.size(tree.root) == 8000 + 5000 + 11_264)
        #expect(tree.size(h1) == 8000)
        #expect(tree.flags(h2).contains(.hardLinkSecondary))
        #expect(tree.size(c1) == 10_240)
        #expect(tree.size(c2) == 1024)

        #expect(tree.reclaimableBytes(h1, ifAlsoRemoving: []) == 0)
        #expect(tree.reclaimableBytes(h1, ifAlsoRemoving: [h2]) == 0)
        #expect(tree.reclaimableBytes(h1, ifAlsoRemoving: [h2, h3]) == 8000)
        #expect(tree.reclaimableBytes(lone, ifAlsoRemoving: []) == 0)
        #expect(tree.reclaimableBytes(c1, ifAlsoRemoving: []) == 1024)
        #expect(tree.reclaimableBytes(c2, ifAlsoRemoving: []) == 1024)
        #expect(tree.reclaimableBytes(c2, ifAlsoRemoving: [c1]) == 10_240)
        // Folder a: h1+h2 (not freed, h3 lives in b), c1 private.
        #expect(tree.reclaimableBytes(a, ifAlsoRemoving: []) == 1024)
        #expect(tree.reclaimableBytes(a, ifAlsoRemoving: [h3]) == 8000 + 1024)
        #expect(tree.reclaimableBytes(a, ifAlsoRemoving: [b]) == 8000 + 10_240)
        // Everything except the lone link (its other link is outside the tree).
        #expect(tree.reclaimableBytes(tree.root, ifAlsoRemoving: []) == 8000 + 11_264)

        // Removing the clone primary hands the shared bytes to the other member.
        tree.removeSubtree(c1)
        #expect(tree.size(c2) == 10_240)
        #expect(tree.size(tree.root) == 8000 + 5000 + 10_240)
        // c2 is now the family's only member in the tree: its shared bytes are still held by
        // the removed clone's extents elsewhere as far as the tree knows, so only private bytes.
        #expect(tree.reclaimableBytes(c2, ifAlsoRemoving: []) == 1024)
    }

    @Test func loneCloneFreesOnlyItsPrivateBytes() {
        // The other member of the family lives outside the scanned folder.
        let builder = ScanTreeBuilder(rootPath: "/fx")
        let folder = builder.addDirectory("Downloads", under: builder.root)
        let copy = builder.addFile("copy.mov", size: 40_960, under: folder, cloneID: 9, privateBytes: 4096)
        builder.addFile("plain.bin", size: 8192, under: folder)
        let tree = builder.build()
        #expect(tree.size(copy) == 40_960)
        #expect(tree.flags(copy).contains(.cloned))
        #expect(tree.sizeInLinks(copy) == 40_960)
        #expect(tree.reclaimableBytes(copy, ifAlsoRemoving: []) == 4096)
        #expect(tree.reclaimableBytes(folder, ifAlsoRemoving: []) == 4096 + 8192)
        #expect(tree.reclaimableBytes(tree.root, ifAlsoRemoving: []) == 4096 + 8192)
    }

    @Test func markMissingHandsSharedBytesToRemainingMembers() {
        let builder = ScanTreeBuilder(rootPath: "/fx")
        let a = builder.addFile("a-link", size: 8192, under: builder.root, inode: 5, linkCount: 2)
        let b = builder.addFile("b-link", size: 8192, under: builder.root, inode: 5, linkCount: 2)
        let c1 = builder.addFile("c1", size: 10_240, under: builder.root, cloneID: 3, privateBytes: 1024)
        let c2 = builder.addFile("c2", size: 10_240, under: builder.root, cloneID: 3, privateBytes: 1024)
        let tree = builder.build()
        #expect(tree.size(a) == 8192)
        #expect(tree.size(b) == 0)
        #expect(tree.size(c1) == 10_240)
        #expect(tree.size(c2) == 1024)
        tree.markMissing(a)
        #expect(tree.size(a) == 0)
        #expect(tree.size(b) == 8192)
        #expect(!tree.flags(b).contains(.hardLinkSecondary))
        tree.markMissing(c1)
        #expect(tree.size(c1) == 0)
        #expect(tree.size(c2) == 10_240)
        #expect(tree.size(tree.root) == 8192 + 10_240)
    }

    @Test func devicesAreInheritedAndOnlyChangesRecorded() {
        let builder = ScanTreeBuilder(rootPath: "/", device: 1)
        let users = builder.addDirectory("Users", under: builder.root, device: 7)
        let home = builder.addDirectory("someone", under: users)
        var files: [NodeID] = []
        for index in 0..<200 {
            files.append(builder.addFile("f\(index)", size: 4096, under: home, inode: UInt64(10_000 + index)))
        }
        let system = builder.addFile("kernel", size: 4096, under: builder.root, inode: 42)
        let tree = builder.build()
        #expect(tree.deviceExceptions.count == 1)
        #expect(tree.identity(files[150]) == FileIdentity(device: 7, inode: 10_150))
        #expect(tree.identity(home)?.device == 7)
        #expect(tree.identity(system) == FileIdentity(device: 1, inode: 42))
        #expect(tree.identity(tree.root)?.device == 1)
    }

    @Test func countClonesOnceOffCountsEveryClone() {
        let builder = ScanTreeBuilder(rootPath: "/fx", countClonesOnce: false)
        let c1 = builder.addFile("c1", size: 10_240, under: builder.root, cloneID: 5, privateBytes: 0)
        builder.addFile("c2", size: 10_240, under: builder.root, cloneID: 5, privateBytes: 0)
        let tree = builder.build()
        #expect(tree.size(tree.root) == 20_480)
        #expect(tree.flags(c1).contains(.cloned))
        #expect(tree.reclaimableBytes(c1, ifAlsoRemoving: []) == 0)
    }

    @Test func identityAndDeviceExceptions() {
        let builder = ScanTreeBuilder(rootPath: "/fx", device: 9)
        let file = builder.addFile("f", size: 1, under: builder.root, inode: 1234)
        let tree = builder.build()
        #expect(tree.identity(file) == FileIdentity(device: 9, inode: 1234))
        #expect(tree.summary(of: file).identity == FileIdentity(device: 9, inode: 1234))
    }

    @Test func emptyRootTree() {
        let tree = ScanTree(emptyRootAt: "/tmp")
        #expect(tree.path(tree.root) == "/tmp")
        #expect(tree.children(tree.root).isEmpty)
        #expect(tree.size(tree.root) == 0)
    }

    @Test func outOfRangeIDsAreHarmless() {
        let (tree, _) = sampleTree()
        let bogus: NodeID = 9_999_999
        #expect(tree.name(bogus) == "")
        #expect(tree.size(bogus) == 0)
        #expect(tree.children(bogus).isEmpty)
        #expect(tree.parent(bogus) == nil)
        #expect(tree.identity(bogus) == nil)
        #expect(tree.reclaimableBytes(bogus, ifAlsoRemoving: []) == 0)
    }

    /// PLAN 2.4 memory budget: at most 64 bytes per node including names and side tables.
    @Test func twoMillionSyntheticNodesFitTheBudget() {
        let builder = ScanTreeBuilder(rootPath: "/Users/someone")
        var count = 1
        var folder: NodeID = builder.root
        for index in 0..<2_000_000 {
            if index % 40 == 0 {
                folder = builder.addDirectory("folder-\(index / 40)", under: builder.root)
                count += 1
                continue
            }
            builder.addFile("file-\(index).dat", size: UInt64(index % 9000) * 512, under: folder)
            count += 1
        }
        let tree = builder.build()
        let stats = tree.statistics()
        #expect(stats.nodes == count)
        let perNode = Double(tree.storageBytes) / Double(stats.nodes)
        #expect(perNode <= 64, "\(perNode) bytes per node")
        print("twoMillionSyntheticNodes bytes per node: \(perNode)")
    }
}
