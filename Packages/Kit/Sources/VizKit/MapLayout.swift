import CoreGraphics
import Foundation

/// Node id understood by VizKit. Matches ScanKit's `NodeID` (UInt32) without depending on ScanKit.
public typealias MapNodeID = UInt32

/// Tree input for the space map. The app adapts its scan tree to this protocol.
/// `name(_:)`, `size(_:)` and `children(_:)` deliberately match `TreeReading`, so a scan tree
/// conforms with an empty extension plus optional category and container overrides.
public protocol MapDataSource: AnyObject {
    /// Bumps on every mutation of the tree. Layouts are cached per generation.
    var generation: UInt64 { get }
    func name(_ id: MapNodeID) -> String
    /// Aggregated size in bytes.
    func size(_ id: MapNodeID) -> UInt64
    /// Children sorted by size, largest first. The layout sorts again, so any order works.
    func children(_ id: MapNodeID) -> [MapNodeID]
    /// Category used for coloring (for example a RulesKit category id). Default: nil.
    func mapCategory(_ id: MapNodeID) -> String?
    /// Whether a tile can be drilled into. Default: has children.
    func mapIsContainer(_ id: MapNodeID) -> Bool
    /// Whether the node is unreadable or protected (drawn hatched). Default: false.
    func mapIsLocked(_ id: MapNodeID) -> Bool
    /// The object that owns the tree data, for example the scan tree an adapter wraps.
    /// Default: this object. The map caches layouts per identity object, keeps a strong
    /// reference to it while the cache entry lives and compares with `===`, so a layout of one
    /// tree is never shown for another. An adapter created on every SwiftUI body pass must
    /// return the wrapped tree (not itself), otherwise every pass misses the cache.
    var mapIdentityObject: AnyObject { get }
    /// Bump when anything the map shows changes without a `generation` bump, for example
    /// categories or lock state that arrive after the scan. Part of the cache key. Default: 0.
    var mapRevision: UInt64 { get }
}

extension MapDataSource {
    public var mapIdentityObject: AnyObject { self }
    public var mapRevision: UInt64 { 0 }
    public func mapCategory(_ id: MapNodeID) -> String? { nil }
    public func mapIsContainer(_ id: MapNodeID) -> Bool { !children(id).isEmpty }
    public func mapIsLocked(_ id: MapNodeID) -> Bool { false }
}

/// Identity of a tile: a real node, or the merged "small items" tile of a parent.
public enum MapTileID: Hashable, Sendable {
    case node(MapNodeID)
    case smallerItems(parent: MapNodeID)

    /// The node id for `.node`, nil for a merged tile.
    public var nodeID: MapNodeID? {
        if case .node(let id) = self { return id }
        return nil
    }
}

/// One laid-out rectangle.
public struct MapTile: Identifiable, Hashable, Sendable {
    public var id: MapTileID
    /// Drawn rectangle (the layout cell inset by half the padding), in the bounds' coordinates.
    public var rect: CGRect
    /// 1 for children of the current folder, 2 for grandchildren.
    public var depth: Int
    public var bytes: UInt64
    public var label: String
    public var category: String?
    public var isContainer: Bool
    /// Node ids merged into a small-items tile (empty for node tiles).
    public var memberIDs: [MapNodeID]
    /// The folder this tile belongs to (the map root for depth 1).
    public var parent: MapNodeID
    /// True when the next level is nested inside this tile (it is drawn as a frame with a header).
    public var isFrame: Bool
    /// True when the node is unreadable or protected (drawn hatched).
    public var isLocked: Bool

    public init(
        id: MapTileID,
        rect: CGRect,
        depth: Int,
        bytes: UInt64,
        label: String,
        category: String? = nil,
        isContainer: Bool = false,
        memberIDs: [MapNodeID] = [],
        parent: MapNodeID = 0,
        isFrame: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.rect = rect
        self.depth = depth
        self.bytes = bytes
        self.label = label
        self.category = category
        self.isContainer = isContainer
        self.memberIDs = memberIDs
        self.parent = parent
        self.isFrame = isFrame
        self.isLocked = isLocked
    }

    /// True for the merged small-items tile.
    public var isSmallerItems: Bool {
        if case .smallerItems = id { return true }
        return false
    }
}

public struct MapLayoutOptions: Sendable, Hashable {
    /// 2 = children plus one nested level of grandchildren.
    public var maxDepth: Int
    /// Tiles smaller than this fraction of the map area merge into one small-items tile per parent.
    public var minTileFraction: Double
    /// Gap between neighbouring tiles, in points.
    public var padding: CGFloat
    /// Height reserved at the top of a frame for its name and size.
    public var headerHeight: CGFloat
    /// Inset between a frame's edge and its nested tiles (left, right, bottom).
    public var innerInset: CGFloat
    /// A container nests its children only when its drawn rect is at least this big.
    public var minFrameSize: CGSize
    /// Parents whose small-items tile was expanded: their children only merge below `expandedMinTileArea`.
    public var expandedParents: Set<MapNodeID>
    /// Merge threshold, in square points, for children of an expanded parent.
    public var expandedMinTileArea: Double
    /// Most node tiles shown for an expanded parent (and for a root whose children are all
    /// below the threshold). Children beyond it stay in one residual small-items tile.
    public var maxExpandedTiles: Int

    public init(
        maxDepth: Int = 2,
        minTileFraction: Double = 0.0015,
        padding: CGFloat = 2,
        headerHeight: CGFloat = 40,
        innerInset: CGFloat = 5,
        minFrameSize: CGSize = CGSize(width: 96, height: 72),
        expandedParents: Set<MapNodeID> = [],
        expandedMinTileArea: Double = 9,
        maxExpandedTiles: Int = 2_000
    ) {
        self.maxDepth = maxDepth
        self.minTileFraction = minTileFraction
        self.padding = padding
        self.headerHeight = headerHeight
        self.innerInset = innerInset
        self.minFrameSize = minFrameSize
        self.expandedParents = expandedParents
        self.expandedMinTileArea = expandedMinTileArea
        self.maxExpandedTiles = maxExpandedTiles
    }
}

/// Pure layout: tree slice in, tiles out. Swappable (treemap, icicle, unit grid).
///
/// Contract: tiles come in pre-order (a frame is followed by its nested tiles), so later tiles
/// draw on top of earlier ones; tile ids are unique and depend only on the tree, never on order.
public protocol MapLayout: Sendable {
    func layout(root: MapNodeID, in bounds: CGRect, source: some MapDataSource, options: MapLayoutOptions) -> [MapTile]
}

/// Squarified treemap (design direction A), two levels deep by default.
///
/// The root's children fill `bounds`; every child that is a container and big enough becomes a
/// frame whose children fill the frame below its header. Children whose area would be under
/// `minTileFraction` of the map merge into one small-items tile per parent, laid out last.
/// Expanded parents (and a root whose children are all small) show at most `maxExpandedTiles`
/// node tiles; the rest stay merged.
public struct TreemapLayout: MapLayout {
    public init() {}

    public func layout(root: MapNodeID, in bounds: CGRect, source: some MapDataSource, options: MapLayoutOptions) -> [MapTile] {
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite, options.maxDepth > 0 else { return [] }
        var tiles: [MapTile] = []
        tiles.reserveCapacity(128)
        let minArea = max(0, options.minTileFraction) * Double(bounds.width * bounds.height)
        place(parent: root, in: bounds, depth: 1, minArea: minArea, source: source, options: options, into: &tiles)
        return tiles
    }

    private func place(
        parent: MapNodeID,
        in rect: CGRect,
        depth: Int,
        minArea: Double,
        source: some MapDataSource,
        options: MapLayoutOptions,
        into tiles: inout [MapTile]
    ) {
        var items: [(id: MapNodeID, size: UInt64)] = []
        for child in source.children(parent) {
            let size = source.size(child)
            if size > 0 { items.append((child, size)) }
        }
        guard !items.isEmpty else { return }
        items.sort { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }

        let total = items.reduce(0.0) { $0 + Double($1.size) }
        let area = Double(rect.width * rect.height)
        let isExpanded = options.expandedParents.contains(parent)
        let expandedThreshold = max(0, options.expandedMinTileArea)
        let expandedCap = max(0, options.maxExpandedTiles)

        // Sorted descending, so the small items are a suffix.
        func countAbove(_ threshold: Double) -> Int {
            var count = items.count
            guard threshold > 0 else { return count }
            while count > 0, Double(items[count - 1].size) / total * area < threshold { count -= 1 }
            return count
        }
        var cap = isExpanded ? expandedCap : Int.max
        var keptCount = countAbove(isExpanded ? expandedThreshold : minArea)
        if keptCount == 0, depth == 1, !isExpanded {
            // Every child of the root is small: show the largest ones rather than one giant merged tile.
            keptCount = countAbove(expandedThreshold)
            cap = expandedCap
        }
        keptCount = min(keptCount, cap)
        // Never merge a single item, unless the cap is what left it out.
        if items.count - keptCount == 1, keptCount < cap { keptCount = items.count }
        let merged = items[keptCount...]
        var weights = items[..<keptCount].map { Double($0.size) }
        let mergedBytes = merged.reduce(UInt64(0)) { $0 + $1.size }
        if !merged.isEmpty { weights.append(Double(mergedBytes)) }

        let cells = Self.squarify(weights, in: rect)
        let half = options.padding / 2

        for index in 0..<keptCount {
            let (id, size) = items[index]
            let drawn = Self.inset(cells[index], by: half)
            let isContainer = source.mapIsContainer(id)
            var tile = MapTile(
                id: .node(id),
                rect: drawn,
                depth: depth,
                bytes: size,
                label: source.name(id),
                category: source.mapCategory(id),
                isContainer: isContainer,
                parent: parent,
                isLocked: source.mapIsLocked(id)
            )
            var content = CGRect.null
            if depth < options.maxDepth, isContainer,
               drawn.width >= options.minFrameSize.width, drawn.height >= options.minFrameSize.height {
                content = CGRect(
                    x: drawn.minX + options.innerInset,
                    y: drawn.minY + options.headerHeight,
                    width: drawn.width - 2 * options.innerInset,
                    height: drawn.height - options.headerHeight - options.innerInset
                )
            }
            if !content.isNull, content.width > 0, content.height > 0 {
                let before = tiles.count
                tile.isFrame = true
                tiles.append(tile)
                place(parent: id, in: content, depth: depth + 1, minArea: minArea, source: source, options: options, into: &tiles)
                if tiles.count == before + 1 { tiles[before].isFrame = false } // nothing nested after all
            } else {
                tiles.append(tile)
            }
        }

        if !merged.isEmpty {
            tiles.append(MapTile(
                id: .smallerItems(parent: parent),
                rect: Self.inset(cells[keptCount], by: half),
                depth: depth,
                bytes: mergedBytes,
                label: MapText.smallerItemsLabel(count: merged.count),
                isContainer: false,
                memberIDs: merged.map(\.id),
                parent: parent
            ))
        }
    }

    private static func inset(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        guard amount > 0 else { return rect }
        let dx = min(amount, rect.width / 2)
        let dy = min(amount, rect.height / 2)
        return rect.insetBy(dx: dx, dy: dy)
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk 2000) of `weights` in `rect`.
    ///
    /// Returns one rect per weight, in input order; pass weights sorted largest first for the best
    /// aspect ratios. Areas are exactly proportional to the weights and the rects tile `rect`
    /// with no overlap. Non-positive weights get an empty rect at `rect`'s origin.
    public static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: CGRect(origin: rect.origin, size: .zero), count: weights.count)
        let indices = weights.indices.filter { weights[$0] > 0 && weights[$0].isFinite }
        let total = indices.reduce(0.0) { $0 + weights[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width) * Double(rect.height) / total
        var x = Double(rect.minX), y = Double(rect.minY)
        var width = Double(rect.width), height = Double(rect.height)
        var start = 0
        let count = indices.count

        @inline(__always) func worst(_ sum: Double, _ smallest: Double, _ largest: Double, _ side: Double) -> Double {
            let s2 = sum * sum, side2 = side * side
            return max(side2 * largest / s2, s2 / (side2 * smallest))
        }

        while start < count {
            let side = min(width, height)
            let first = weights[indices[start]] * scale
            var sum = first, smallest = first, largest = first
            var current = worst(sum, smallest, largest, side)
            var end = start + 1
            while end < count {
                let area = weights[indices[end]] * scale
                let nextSum = sum + area
                let next = worst(nextSum, min(smallest, area), max(largest, area), side)
                if next > current { break }
                sum = nextSum
                smallest = min(smallest, area)
                largest = max(largest, area)
                current = next
                end += 1
            }
            let isLast = end == count
            if width >= height {
                // Column along the left edge.
                let columnWidth = isLast ? width : sum / height
                var cursor = y
                for k in start..<end {
                    let h = (end - 1 == k) ? (y + height - cursor) : weights[indices[k]] * scale / columnWidth
                    result[indices[k]] = CGRect(x: x, y: cursor, width: columnWidth, height: h)
                    cursor += h
                }
                x += columnWidth
                width -= columnWidth
            } else {
                // Row along the top edge.
                let rowHeight = isLast ? height : sum / width
                var cursor = x
                for k in start..<end {
                    let w = (end - 1 == k) ? (x + width - cursor) : weights[indices[k]] * scale / rowHeight
                    result[indices[k]] = CGRect(x: cursor, y: y, width: w, height: rowHeight)
                    cursor += w
                }
                y += rowHeight
                height -= rowHeight
            }
            start = end
        }
        return result
    }

    /// Topmost tile containing `point`: the deepest one, and among equals the one drawn last.
    /// Analytic (rect containment), no allocation.
    public static func hitTest(_ tiles: [MapTile], at point: CGPoint) -> MapTile? {
        let best: Int? = tiles.withUnsafeBufferPointer { buffer in
            var best: Int?
            var bestDepth = Int.min
            for index in 0..<buffer.count {
                let depth = buffer[index].depth
                if depth >= bestDepth, buffer[index].rect.contains(point) {
                    best = index
                    bestDepth = depth
                }
            }
            return best
        }
        return best.map { tiles[$0] }
    }
}
