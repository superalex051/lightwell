import CoreGraphics
import Testing
import VizKit

@Suite("Hit testing and accessibility")
struct HitTestAndAccessibilityTests {
    let bounds = CGRect(x: 0, y: 0, width: 1100, height: 640)

    @Test func thousandRandomPointsHitTheDeepestContainingTile() {
        let tree = makeWideTree(folders: 25, filesPerFolder: 30, seed: 21)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        #expect(tiles.contains { $0.depth == 2 })
        var random = SeededRandom(seed: 1234)
        var hitsByDepth = [0, 0, 0]
        for _ in 0..<1_000 {
            let point = CGPoint(x: Double.random(in: 0..<Double(bounds.width), using: &random),
                                y: Double.random(in: 0..<Double(bounds.height), using: &random))
            let containing = tiles.filter { $0.rect.contains(point) }
            let hit = TreemapLayout.hitTest(tiles, at: point)
            // At most one tile per depth contains any point (no overlap within a level).
            for depth in 1...2 { #expect(containing.filter { $0.depth == depth }.count <= 1) }
            if containing.isEmpty {
                #expect(hit == nil)
                hitsByDepth[0] += 1
                continue
            }
            guard let hit else { Issue.record("no hit at \(point)"); continue }
            #expect(hit.rect.contains(point))
            #expect(hit.depth == containing.map(\.depth).max())
            if hit.depth == 2 {
                // The nested tile sits inside the depth-1 frame that also contains the point.
                let frame = containing.first { $0.depth == 1 }
                #expect(frame?.id.nodeID == hit.parent)
                #expect(frame?.isFrame == true)
            }
            hitsByDepth[hit.depth] += 1
        }
        // The sample covers gaps, frame headers and nested tiles.
        #expect(hitsByDepth[1] > 0 && hitsByDepth[2] > 0)
    }

    @Test func hitTestOutsideAndOnGaps() {
        let tree = makeWideTree(folders: 4, filesPerFolder: 2, seed: 2)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(padding: 6))
        #expect(TreemapLayout.hitTest(tiles, at: CGPoint(x: -5, y: 10)) == nil)
        #expect(TreemapLayout.hitTest(tiles, at: CGPoint(x: 1, y: 1)) == nil, "the outer padding is not a tile")
        #expect(TreemapLayout.hitTest([], at: .zero) == nil)
    }

    @Test func everyTileHasNameAndSizeLabel() {
        let tree = makeWideTree(folders: 20, filesPerFolder: 40, seed: 5)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        #expect(tiles.contains { $0.isSmallerItems })
        for tile in tiles {
            let label = MapText.accessibilityLabel(for: tile)
            #expect(label == "\(tile.label), \(MapText.size(tile.bytes))")
            #expect(!tile.label.isEmpty)
            let identifier = MapText.accessibilityIdentifier(for: tile)
            switch tile.id {
            case .node: #expect(identifier == "explore.tile.\(tile.label)")
            case .smallerItems(let parent): #expect(identifier == "explore.tile.smallItems.\(parent)")
            }
        }
    }

    @Test func stringsComeFromTheCatalog() {
        // Plural variants only resolve when VizKit's String Catalog is in the bundle.
        #expect(MapText.smallerItemsLabel(count: 1) == "1 small item")
        #expect(MapText.smallerItemsLabel(count: 7) == "7 small items")
        #expect(MapText.accessibilityLabel(name: "Library", bytes: 0) == "Library, \(MapText.size(0))")
        #expect(MapText.mapAccessibilityLabel == "Space map")
        #expect(MapText.size(1_500_000_000) == ByteFormat.string(1_500_000_000))
    }
}
