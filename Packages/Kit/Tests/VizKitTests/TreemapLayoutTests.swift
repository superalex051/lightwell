import CoreGraphics
import Testing
import VizKit

@Suite("Treemap layout")
struct TreemapLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 700)

    @Test func depthOneAreasProportionalAndTileBounds() {
        let tree = makeWideTree(folders: 40, filesPerFolder: 3, seed: 7)
        let options = MapLayoutOptions(maxDepth: 1, minTileFraction: 0, padding: 0)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: options)
        #expect(tiles.count == 40)
        let total = Double(tree.size(0))
        var covered = 0.0
        for tile in tiles {
            #expect(tile.depth == 1)
            #expect(tile.parent == 0)
            let expected = Double(tile.bytes) / total * Geometry.area(bounds)
            #expect(abs(Geometry.area(tile.rect) - expected) <= expected * 0.01)
            #expect(Geometry.contains(bounds, tile.rect))
            covered += Geometry.area(tile.rect)
        }
        #expect(abs(covered - Geometry.area(bounds)) < 1e-6 * Geometry.area(bounds))
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                #expect(Geometry.overlap(tiles[i].rect, tiles[j].rect) < 1e-6)
            }
        }
    }

    @Test func nestedTilesFillTheirFrame() {
        let tree = makeWideTree(folders: 8, filesPerFolder: 12, seed: 11)
        let options = MapLayoutOptions(minTileFraction: 0, padding: 0, headerHeight: 30, innerInset: 4)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: options)
        let frames = tiles.filter { $0.depth == 1 }
        #expect(frames.count == 8)
        #expect(frames.allSatisfy { $0.isFrame })
        for frame in frames {
            guard case .node(let folder) = frame.id else { Issue.record("frame without node id"); continue }
            let content = CGRect(x: frame.rect.minX + 4, y: frame.rect.minY + 30,
                                 width: frame.rect.width - 8, height: frame.rect.height - 34)
            let nested = tiles.filter { $0.parent == folder }
            #expect(nested.count == 12)
            let nestedTotal = Double(nested.reduce(UInt64(0)) { $0 + $1.bytes })
            var covered = 0.0
            for tile in nested {
                #expect(tile.depth == 2)
                #expect(Geometry.contains(content, tile.rect))
                let expected = Double(tile.bytes) / nestedTotal * Geometry.area(content)
                #expect(abs(Geometry.area(tile.rect) - expected) <= expected * 0.01)
                covered += Geometry.area(tile.rect)
            }
            #expect(abs(covered - Geometry.area(content)) < 1e-6 * Geometry.area(content))
            for i in nested.indices {
                for j in nested.indices where j > i {
                    #expect(Geometry.overlap(nested[i].rect, nested[j].rect) < 1e-6)
                }
            }
        }
    }

    @Test func preOrderAndDepthLimit() {
        let tree = makeWideTree(folders: 5, filesPerFolder: 4, seed: 3)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(minTileFraction: 0))
        // Every nested tile directly follows its frame or a sibling.
        var currentFrame: MapNodeID?
        for tile in tiles {
            if tile.depth == 1 {
                currentFrame = tile.isFrame ? tile.id.nodeID : nil
            } else {
                #expect(tile.parent == currentFrame)
            }
        }
        #expect(tiles.allSatisfy { $0.depth <= 2 })
        let flat = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(maxDepth: 1))
        #expect(flat.allSatisfy { $0.depth == 1 && !$0.isFrame })
    }

    @Test func smallFramesDoNotNest() {
        let tree = makeWideTree(folders: 3, filesPerFolder: 4, seed: 5)
        let options = MapLayoutOptions(minTileFraction: 0, minFrameSize: CGSize(width: 10_000, height: 10_000))
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: options)
        #expect(tiles.count == 3)
        #expect(tiles.allSatisfy { !$0.isFrame && $0.isContainer })
    }

    @Test func smallChildrenMergeIntoOneTilePerParent() {
        let tree = TestTree()
        var big: [MapNodeID] = []
        for i in 0..<10 { big.append(tree.add("big\(i)", size: 1_000_000_000)) }
        var tiny: [MapNodeID] = []
        for i in 0..<50 { tiny.append(tree.add("tiny\(i)", size: 1_000 + UInt64(i))) }
        tree.seal()

        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        let merged = tiles.filter(\.isSmallerItems)
        #expect(merged.count == 1)
        let group = merged[0]
        #expect(group.id == .smallerItems(parent: 0))
        #expect(Set(group.memberIDs) == Set(tiny))
        #expect(group.bytes == tiny.reduce(UInt64(0)) { $0 + tree.size($1) })
        #expect(group.label == "50 small items")
        #expect(!group.isContainer)
        #expect(tiles.last?.id == group.id, "the merged tile is laid out last")
        #expect(tiles.filter { !$0.isSmallerItems }.compactMap(\.id.nodeID).sorted() == big.sorted())
        // Every kept tile is at least the threshold.
        let minArea = 0.0015 * Geometry.area(bounds)
        for tile in tiles where !tile.isSmallerItems {
            #expect(Geometry.area(tile.rect.insetBy(dx: -1, dy: -1)) >= minArea)
        }

        // Expanding the parent shows the tiny items as tiles of their own.
        let expanded = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(expandedParents: [0], expandedMinTileArea: 0))
        #expect(expanded.filter(\.isSmallerItems).isEmpty)
        #expect(expanded.count == 60)
    }

    @Test func singleSmallChildIsNotMerged() {
        let tree = TestTree()
        tree.add("big", size: 1_000_000_000)
        tree.add("tiny", size: 10)
        tree.seal()
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        #expect(tiles.count == 2)
        #expect(tiles.allSatisfy { !$0.isSmallerItems })
    }

    @Test func nestedGroupingUsesMapArea() {
        let tree = TestTree()
        let folder = tree.add("folder")
        for i in 0..<5 { tree.add("big\(i)", size: 1_000_000_000, under: folder) }
        for i in 0..<30 { tree.add("tiny\(i)", size: 100, under: folder) }
        tree.seal()
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        let merged = tiles.filter(\.isSmallerItems)
        #expect(merged.map(\.id) == [.smallerItems(parent: folder)])
        #expect(merged.first?.depth == 2)
        #expect(merged.first?.memberIDs.count == 30)
    }

    @Test func idsAreDeterministicAndUnique() {
        let tree = makeWideTree(folders: 30, filesPerFolder: 20, seed: 99)
        let options = MapLayoutOptions()
        let first = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: options)
        let second = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: options)
        #expect(first == second)
        #expect(Set(first.map(\.id)).count == first.count)
        tree.reverseChildOrder()
        let reordered = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: options)
        #expect(reordered == first, "input child order must not change the layout")
    }

    @Test func equalSizesTieBreakOnID() {
        let tree = TestTree()
        for i in 0..<6 { tree.add("same\(i)", size: 500) }
        tree.seal()
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(minTileFraction: 0))
        #expect(tiles.compactMap(\.id.nodeID) == [1, 2, 3, 4, 5, 6])
    }

    @Test func metadataPropagates() {
        let tree = TestTree()
        let a = tree.add("Caches", size: 0, category: "caches")
        tree.add("blob", size: 4_000_000, under: a, category: "caches")
        let b = tree.add("Locked", size: 3_000_000)
        tree.locked = [b]
        tree.seal()
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        let caches = tiles.first { $0.id == .node(a) }
        let locked = tiles.first { $0.id == .node(b) }
        #expect(caches?.category == "caches")
        #expect(caches?.isContainer == true)
        #expect(caches?.isFrame == true)
        #expect(caches?.label == "Caches")
        #expect(locked?.isLocked == true)
        #expect(locked?.isContainer == false)
    }

    @Test func degenerateInputs() {
        let tree = TestTree()
        #expect(TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions()).isEmpty)
        tree.add("zero", size: 0)
        tree.seal()
        #expect(TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions()).isEmpty)
        let full = makeWideTree(folders: 3, filesPerFolder: 3, seed: 1)
        #expect(TreemapLayout().layout(root: 0, in: .zero, source: full, options: MapLayoutOptions()).isEmpty)
        #expect(TreemapLayout().layout(root: 0, in: CGRect(x: 0, y: 0, width: 100, height: 0), source: full, options: MapLayoutOptions()).isEmpty)
        #expect(TreemapLayout().layout(root: 0, in: bounds, source: full, options: MapLayoutOptions(maxDepth: 0)).isEmpty)
        // A leaf as root has nothing to show.
        #expect(TreemapLayout().layout(root: 2, in: bounds, source: full, options: MapLayoutOptions()).isEmpty)
    }

    @Test func paddingLeavesGapsInsideCells() {
        let tree = makeWideTree(folders: 6, filesPerFolder: 2, seed: 8)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(maxDepth: 1, padding: 4))
        for tile in tiles { #expect(Geometry.contains(bounds.insetBy(dx: 2, dy: 2), tile.rect, tolerance: 1e-6)) }
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                let a = tiles[i].rect.insetBy(dx: -1.99, dy: -1.99), b = tiles[j].rect.insetBy(dx: -1.99, dy: -1.99)
                #expect(Geometry.overlap(a, b) == 0, "neighbours keep a 4 pt gap")
            }
        }
    }
}
