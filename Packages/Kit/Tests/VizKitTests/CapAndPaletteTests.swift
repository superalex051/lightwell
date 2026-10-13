import CoreGraphics
import SwiftUI
import Testing
import VizKit

@Suite("Caps and palette identity")
struct CapAndPaletteTests {
    let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test func expandingAHugeFolderIsCapped() {
        let tree = TestTree()
        let folder = tree.add("huge")
        for i in 0..<50_000 { tree.add("f\(i)", size: 4_096, under: folder) }
        tree.add("other", size: 1, under: 0)
        tree.seal()
        // Show the folder as the root, expanded: every file is ~32 pt², above the 9 pt² floor.
        let tiles = TreemapLayout().layout(root: folder, in: bounds, source: tree, options: MapLayoutOptions(expandedParents: [folder]))
        let nodes = tiles.filter { !$0.isSmallerItems }
        let merged = tiles.filter { $0.isSmallerItems }
        #expect(nodes.count == 2_000)
        #expect(merged.count == 1)
        #expect(merged.first?.memberIDs.count == 48_000)
        #expect(tiles.count == 2_001)
        #expect(merged.first?.label == MapText.smallerItemsLabel(count: 48_000))

        let custom = TreemapLayout().layout(root: folder, in: bounds, source: tree, options: MapLayoutOptions(expandedParents: [folder], maxExpandedTiles: 10))
        #expect(custom.filter { !$0.isSmallerItems }.count == 10)
        #expect(custom.filter { $0.isSmallerItems }.first?.memberIDs.count == 49_990)
    }

    @Test func rootWithOnlySmallChildrenShowsTheLargestOnes() {
        // 1,000 equal children: each is 0.1% of the map, under the 0.15% threshold.
        let tree = TestTree()
        for i in 0..<1_000 { tree.add("c\(i)", size: 1_000) }
        tree.seal()
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        #expect(tiles.count == 1_000)
        #expect(tiles.allSatisfy { !$0.isSmallerItems })

        // 50,000 equal children: capped, the rest in one residual tile.
        let big = TestTree()
        for i in 0..<50_000 { big.add("c\(i)", size: 1_000) }
        big.seal()
        let capped = TreemapLayout().layout(root: 0, in: bounds, source: big, options: MapLayoutOptions())
        #expect(capped.filter { !$0.isSmallerItems }.count == 2_000)
        #expect(capped.filter { $0.isSmallerItems }.count == 1)
        #expect(capped.last?.isSmallerItems == true)
    }

    @Test func nestedFramesStillMergeEverything() {
        // The fallback is for the root only; a frame full of tiny files keeps one merged tile.
        let tree = TestTree()
        tree.add("big", size: 10_000_000)
        let folder = tree.add("folder")
        for i in 0..<500 { tree.add("t\(i)", size: 10_000, under: folder) }
        tree.seal()
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        #expect(tiles.filter { $0.parent == folder }.map(\.id) == [.smallerItems(parent: folder)])
    }

    @Test func accessibilityElementsAreCapped() {
        let tree = makeWideTree(folders: 100, filesPerFolder: 50, seed: 4)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(minTileFraction: 0, minFrameSize: .zero))
        #expect(tiles.count > MapAccessibility.maxElements)
        let elements = MapAccessibility.elements(for: tiles)
        #expect(elements.count == MapAccessibility.maxElements)
        // Original order is kept.
        let positions = Dictionary(uniqueKeysWithValues: tiles.enumerated().map { ($1.id, $0) })
        let order = elements.map { positions[$0.id]! }
        #expect(order == order.sorted())
        // The largest tiles are the ones kept.
        let kept = Set(elements.map(\.id))
        let smallestKept = elements.map { Geometry.area($0.rect) }.min()!
        let largestDropped = tiles.filter { !kept.contains($0.id) }.map { Geometry.area($0.rect) }.max()!
        #expect(smallestKept >= largestDropped)
        // All depth-1 frames survive (they are the biggest).
        #expect(tiles.filter { $0.depth == 1 }.allSatisfy { kept.contains($0.id) })

        let few = Array(tiles.prefix(10))
        #expect(MapAccessibility.elements(for: few) == few)
        #expect(MapAccessibility.elements(for: tiles, limit: 0).isEmpty)
    }

    @Test func paletteIDFollowsColors() {
        func palette(_ projects: Color) -> CategoryMapPalette {
            CategoryMapPalette(colors: ["projects": projects], fallback: .gray, background: .white, label: .black)
        }
        #expect(palette(.blue).paletteID == palette(.blue).paletteID)
        #expect(palette(.blue).paletteID != palette(.red).paletteID)
        var changed = palette(.blue)
        changed.frameWash = 0.3
        #expect(changed.paletteID != palette(.blue).paletteID)
        #expect(NeutralMapPalette().paletteID == NeutralMapPalette().paletteID)
        #expect(OpaquePalette().paletteID == OpaquePalette().paletteID, "non-Hashable palettes fall back to their type")
        #expect(OpaquePalette().paletteID != NeutralMapPalette().paletteID)
    }
}

/// A palette that is not Hashable.
struct OpaquePalette: MapPalette {
    var tint = 0
    func fill(for tile: MapTile) -> Color { .gray }
    func labelColor(for tile: MapTile) -> Color { .black }
    var background: Color { .white }
    var highlight: Color { .black }
}
