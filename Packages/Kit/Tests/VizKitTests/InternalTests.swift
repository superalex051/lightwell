// Tests of internal pieces (layout cache, drawing-layer equality, transitions). They need
// `@testable`, which only debug builds allow, so the file compiles to nothing in release.
#if DEBUG
import CoreGraphics
import SwiftUI
import Testing
@testable import VizKit

/// Adapter over a tree, rebuilt by the app on every SwiftUI body pass.
final class FreshAdapter: MapDataSource {
    let tree: TestTree
    init(_ tree: TestTree) { self.tree = tree }
    var generation: UInt64 { tree.generation }
    func name(_ id: MapNodeID) -> String { tree.name(id) }
    func size(_ id: MapNodeID) -> UInt64 { tree.size(id) }
    func children(_ id: MapNodeID) -> [MapNodeID] { tree.children(id) }
    func mapCategory(_ id: MapNodeID) -> String? { tree.mapCategory(id) }
    var mapIdentityObject: AnyObject { tree }
    var mapRevision: UInt64 { tree.mapRevision }
}

private func tree(_ names: [String], sizes: [UInt64]) -> TestTree {
    let tree = TestTree()
    for (name, size) in zip(names, sizes) { tree.add(name, size: size) }
    return tree.seal()
}

@Suite("Layout cache")
@MainActor
struct LayoutCacheTests {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let options = MapLayoutOptions()

    @Test func treesWithEqualGenerationAndRootNeverShareALayout() {
        let cache = MapLayoutCache()
        let a = tree(["alpha", "beta"], sizes: [300, 100])
        let b = tree(["gamma", "delta", "epsilon"], sizes: [50, 40, 10])
        #expect(a.generation == b.generation)
        let first = cache.entry(source: a, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        let second = cache.entry(source: b, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(first.tiles.map(\.label) == ["alpha", "beta"])
        #expect(second.tiles.map(\.label) == ["gamma", "delta", "epsilon"])
        #expect(cache.layoutCount == 2)
        // Through adapters too.
        let viaAdapter = cache.entry(source: FreshAdapter(a), root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(viaAdapter.tiles.map(\.label) == ["alpha", "beta"])
    }

    @Test func freedSourceAddressIsNeverReused() {
        let cache = MapLayoutCache()
        // Sources whose identity is themselves, released right after use: the cache keeps the
        // identity alive, so the next source cannot get the same address and a stale hit.
        for round in 0..<200 {
            let names = ["round\(round)"]
            let entry = cache.entry(source: tree(names, sizes: [10]), root: 0, bounds: bounds, options: options, layout: TreemapLayout())
            #expect(entry.tiles.map(\.label) == names)
        }
        #expect(cache.layoutCount == 200)
    }

    @Test func freshAdapterPerPassHitsTheCache() {
        let cache = MapLayoutCache()
        let shared = makeWideTree(folders: 10, filesPerFolder: 10, seed: 3)
        var revisions: Set<Int> = []
        // Every body pass (hover, inspector update, ...) rebuilds the adapter: no relayout.
        for _ in 0..<50 {
            revisions.insert(cache.entry(source: FreshAdapter(shared), root: 0, bounds: bounds, options: options, layout: TreemapLayout()).revision)
        }
        #expect(cache.layoutCount == 1)
        #expect(revisions.count == 1)
    }

    @Test func revisionAndGenerationInvalidate() {
        let cache = MapLayoutCache()
        let t = tree(["one", "two"], sizes: [10, 5])
        let first = cache.entry(source: t, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(first.tiles.allSatisfy { $0.category == nil })

        t.categories = [1: "caches", 2: "media"]
        let unchanged = cache.entry(source: t, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(unchanged.revision == first.revision, "without a bump the cached layout is reused")

        t.revision += 1
        let recolored = cache.entry(source: t, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(recolored.revision != first.revision)
        #expect(recolored.tiles.map(\.category) == ["caches", "media"])

        t.generation += 1
        let regenerated = cache.entry(source: t, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(regenerated.revision != recolored.revision)
        #expect(cache.layoutCount == 3)
    }

    @Test func previousEntryOnlyFromTheSameTree() {
        let cache = MapLayoutCache()
        let a = makeWideTree(folders: 4, filesPerFolder: 3, seed: 1)
        let b = makeWideTree(folders: 4, filesPerFolder: 3, seed: 2)
        _ = cache.entry(source: a, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        _ = cache.entry(source: a, root: 1, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(cache.previousEntry(root: 0, size: bounds.size, identity: a) != nil)
        #expect(cache.previousEntry(root: 0, size: bounds.size, identity: b) == nil)
        _ = cache.entry(source: b, root: 0, bounds: bounds, options: options, layout: TreemapLayout())
        #expect(cache.previousEntry(root: 1, size: bounds.size, identity: a) == nil, "entries of the old tree are dropped")
    }
}

@Suite("Drawing layers")
@MainActor
struct DrawingLayerTests {
    @Test func tilesLayerRedrawsOnPaletteOrSchemeChange() {
        let cache = MapLayoutCache()
        let entry = cache.entry(source: makeHomeTree(), root: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), options: MapLayoutOptions(), layout: TreemapLayout())
        func palette(_ color: Color) -> CategoryMapPalette {
            CategoryMapPalette(colors: ["media": color], fallback: .gray, background: .white, label: .black)
        }
        let base = MapTilesLayer(entry: entry, palette: palette(.pink), colorScheme: .light)
        #expect(base == MapTilesLayer(entry: entry, palette: palette(.pink), colorScheme: .light))
        #expect(base != MapTilesLayer(entry: entry, palette: palette(.orange), colorScheme: .light))
        #expect(base != MapTilesLayer(entry: entry, palette: palette(.pink), colorScheme: .dark))
    }

    @Test func accessibilityActionsAreNeverStale() {
        let cache = MapLayoutCache()
        let entry = cache.entry(source: makeHomeTree(), root: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), options: MapLayoutOptions(), layout: TreemapLayout())
        let box = MapActionBox()
        var opened: [String] = []
        box.activate = { opened.append("old:\($0.label)") }
        let early = MapAccessibilityTiles(entry: entry, size: CGSize(width: 400, height: 300), actions: box)
        let later = MapAccessibilityTiles(entry: entry, size: CGSize(width: 400, height: 300), actions: box)
        #expect(early == later, "equal layers skip rebuilding")
        // A later body pass installs a new action; the element kept from the early pass uses it.
        box.activate = { opened.append("new:\($0.label)") }
        early.actions.activate(entry.tiles[0])
        #expect(opened == ["new:\(entry.tiles[0].label)"])
    }
}

@Suite("Zoom transitions")
struct TransitionTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)

    @Test func zoomInIsUniformAndCentered() {
        let tree = makeWideTree(folders: 6, filesPerFolder: 4, seed: 9)
        let outgoing = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        let incoming = TreemapLayout().layout(root: 6, in: bounds, source: tree, options: MapLayoutOptions())
        let tile = outgoing.first { $0.id == .node(6) }!
        let plan = MapTransitionPlanner.plan(outgoing: outgoing, incoming: incoming, from: 0, to: 6, bounds: bounds, reduceMotion: false)
        #expect(plan.kind == .zoomIn)
        // The old layout ends with the clicked tile fitted in the view, aspect kept, centered.
        let end = plan.outgoingEnd.apply(tile.rect)
        #expect(abs(end.midX - bounds.midX) < 1e-6 && abs(end.midY - bounds.midY) < 1e-6)
        #expect(end.width <= bounds.width + 1e-6 && end.height <= bounds.height + 1e-6)
        #expect(abs(end.width - bounds.width) < 1e-6 || abs(end.height - bounds.height) < 1e-6)
        #expect(abs(end.width / end.height - tile.rect.width / tile.rect.height) < 1e-9)
        // The new layout starts centered on the tile, as the exact inverse.
        let start = plan.incomingStart.apply(bounds)
        #expect(abs(start.midX - tile.rect.midX) < 1e-6 && abs(start.midY - tile.rect.midY) < 1e-6)
        let roundTrip = plan.outgoingEnd.apply(plan.incomingStart.apply(CGPoint(x: 123, y: 45)))
        #expect(abs(roundTrip.x - 123) < 1e-6 && abs(roundTrip.y - 45) < 1e-6)
        // Halfway the scale is still uniform (one value for both axes by construction).
        let half = MapZoomTransform.identity.interpolated(to: plan.outgoingEnd, 0.5)
        #expect(half.scale > 1)
    }

    @Test func zoomOutAndFade() {
        let tree = makeWideTree(folders: 6, filesPerFolder: 4, seed: 9)
        let parent = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions())
        let child = TreemapLayout().layout(root: 1, in: bounds, source: tree, options: MapLayoutOptions())
        let out = MapTransitionPlanner.plan(outgoing: child, incoming: parent, from: 1, to: 0, bounds: bounds, reduceMotion: false)
        #expect(out.kind == .zoomOut)
        #expect(out.outgoingEnd == out.incomingStart.inverse)

        let unrelated = MapTransitionPlanner.plan(outgoing: child, incoming: parent, from: 77, to: 78, bounds: bounds, reduceMotion: false)
        #expect(unrelated.kind == .fade)
        let reduced = MapTransitionPlanner.plan(outgoing: parent, incoming: child, from: 0, to: 1, bounds: bounds, reduceMotion: true)
        #expect(reduced == MapTransitionPlanner.Plan(kind: .fade, incomingStart: .identity, outgoingEnd: .identity))
    }
}
#endif
