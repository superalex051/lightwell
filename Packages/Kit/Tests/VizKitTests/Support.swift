import CoreGraphics
import VizKit

/// In-memory tree for VizKit tests. Node 0 is the root. Leaves get explicit sizes, folders
/// aggregate their children when `seal()` runs.
final class TestTree: MapDataSource {
    var generation: UInt64 = 1
    private var names: [MapNodeID: String] = [0: "root"]
    private var sizes: [MapNodeID: UInt64] = [:]
    private var kids: [MapNodeID: [MapNodeID]] = [:]
    private var parents: [MapNodeID: MapNodeID] = [:]
    var categories: [MapNodeID: String] = [:]
    var locked: Set<MapNodeID> = []
    /// Bumped by tests that change categories or locks without a generation bump.
    var revision: UInt64 = 0
    var mapRevision: UInt64 { revision }
    private var nextID: MapNodeID = 1

    @discardableResult
    func add(_ name: String, size: UInt64 = 0, under parent: MapNodeID = 0, category: String? = nil) -> MapNodeID {
        let id = nextID
        nextID += 1
        names[id] = name
        sizes[id] = size
        kids[parent, default: []].append(id)
        parents[id] = parent
        if let category { categories[id] = category }
        return id
    }

    /// Aggregates folder sizes and sorts children largest first.
    @discardableResult
    func seal() -> TestTree {
        _ = aggregate(0)
        for (parent, list) in kids {
            kids[parent] = list.sorted { size($0) != size($1) ? size($0) > size($1) : $0 < $1 }
        }
        return self
    }

    private func aggregate(_ id: MapNodeID) -> UInt64 {
        guard let list = kids[id], !list.isEmpty else { return sizes[id] ?? 0 }
        let total = list.reduce(UInt64(0)) { $0 + aggregate($1) }
        sizes[id] = total
        return total
    }

    func name(_ id: MapNodeID) -> String { names[id] ?? "?" }
    func size(_ id: MapNodeID) -> UInt64 { sizes[id] ?? 0 }
    func children(_ id: MapNodeID) -> [MapNodeID] { kids[id] ?? [] }
    func mapCategory(_ id: MapNodeID) -> String? { categories[id] }
    func mapIsLocked(_ id: MapNodeID) -> Bool { locked.contains(id) }
    func parent(_ id: MapNodeID) -> MapNodeID? { parents[id] }

    /// Reverses every child list (layout must not depend on input order).
    func reverseChildOrder() {
        for (parent, list) in kids { kids[parent] = list.reversed() }
    }
}

/// Deterministic random numbers (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Geometry {
    static func area(_ r: CGRect) -> Double { Double(r.width) * Double(r.height) }

    /// Overlap area of two rects (0 when they only touch).
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 0 && h > 0 ? Double(w) * Double(h) : 0
    }

    static func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 1e-6) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.minY >= outer.minY - tolerance
            && inner.maxX <= outer.maxX + tolerance && inner.maxY <= outer.maxY + tolerance
    }

    static func aspect(_ r: CGRect) -> Double {
        let w = Double(r.width), h = Double(r.height)
        return max(w / h, h / w)
    }
}

/// Root with `folders` folders of `filesPerFolder` files each, random sizes.
func makeWideTree(folders: Int, filesPerFolder: Int, seed: UInt64) -> TestTree {
    var random = SeededRandom(seed: seed)
    let tree = TestTree()
    for f in 0..<folders {
        let folder = tree.add("folder\(f)")
        for i in 0..<filesPerFolder {
            tree.add("file\(f)-\(i)", size: UInt64.random(in: 1_000...50_000_000, using: &random), under: folder)
        }
    }
    return tree.seal()
}
