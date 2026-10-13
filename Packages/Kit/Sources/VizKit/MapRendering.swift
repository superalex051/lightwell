import SwiftUI

// MARK: - Layout cache

/// Layouts keyed by tree identity, generation, revision, root, size, options and layout type.
/// Not observed: reading or filling it never invalidates a view. Keeps the last few entries of
/// the current tree so a zoom can reach the previous layout.
///
/// Each entry retains the source's identity object, so its address cannot be reused by another
/// object while the entry lives, and hits are confirmed with `===`. Entries of other trees are
/// dropped as soon as a new tree is laid out, so the cache never keeps an old tree alive.
@MainActor
final class MapLayoutCache {
    struct Key: Hashable {
        var identity: ObjectIdentifier
        var generation: UInt64
        var revision: UInt64
        var root: MapNodeID
        var size: CGSize
        var options: MapLayoutOptions
        var layoutType: ObjectIdentifier
    }

    struct Entry {
        var tiles: [MapTile]
        /// Unique per computed layout; lets the drawing layers skip redraws.
        var revision: Int
        /// Strong reference to the tree identity object the layout belongs to.
        var identity: AnyObject
    }

    private var keys: [Key] = []
    private var entries: [Key: Entry] = [:]
    private var counter = 0
    private let capacity = 6
    /// Bounds of the last layout requested.
    var bounds: CGRect = .zero
    /// Number of layouts computed (cache misses).
    private(set) var layoutCount = 0

    /// The cached layout for these inputs, computing it on a miss.
    func entry(
        source: some MapDataSource,
        root: MapNodeID,
        bounds: CGRect,
        options: MapLayoutOptions,
        layout: any MapLayout
    ) -> Entry {
        self.bounds = bounds
        let identity = source.mapIdentityObject
        let key = Key(
            identity: ObjectIdentifier(identity),
            generation: source.generation,
            revision: source.mapRevision,
            root: root,
            size: bounds.size,
            options: options,
            layoutType: ObjectIdentifier(type(of: layout) as Any.Type)
        )
        if let hit = entries[key], hit.identity === identity {
            if keys.last != key, let index = keys.firstIndex(of: key) {
                keys.remove(at: index)
                keys.append(key)
            }
            return hit
        }
        // A different tree: forget layouts that would keep the old one alive.
        keys.removeAll { key in
            guard let entry = entries[key], entry.identity !== identity else { return false }
            entries[key] = nil
            return true
        }
        counter += 1
        layoutCount += 1
        let entry = Entry(tiles: layout.layout(root: root, in: bounds, source: source, options: options), revision: counter, identity: identity)
        entries[key] = entry
        keys.append(key)
        if keys.count > capacity { entries[keys.removeFirst()] = nil }
        return entry
    }

    /// Most recently used layout of `root` at `size` for the tree `identity`.
    func previousEntry(root: MapNodeID, size: CGSize, identity: AnyObject) -> Entry? {
        for key in keys.reversed() where key.root == root && key.size == size {
            if let entry = entries[key], entry.identity === identity { return entry }
        }
        return nil
    }
}

// MARK: - Zoom transform

/// Uniform affine map `p -> p * scale + offset` used for drill-down zooms. The scale is the same
/// on both axes, so labels keep their proportions while zooming.
struct MapZoomTransform: Equatable {
    var scale: CGFloat
    var offset: CGSize

    static let identity = MapZoomTransform(scale: 1, offset: .zero)

    /// Scales `rect` up (or down) until it fits inside `bounds`, centered: the whole rect stays
    /// visible and the other axis is letterboxed.
    static func fit(_ rect: CGRect, into bounds: CGRect) -> MapZoomTransform {
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else { return .identity }
        let scale = min(bounds.width / rect.width, bounds.height / rect.height)
        return MapZoomTransform(
            scale: scale,
            offset: CGSize(width: bounds.midX - rect.midX * scale, height: bounds.midY - rect.midY * scale)
        )
    }

    var inverse: MapZoomTransform {
        guard scale > 0 else { return .identity }
        return MapZoomTransform(scale: 1 / scale, offset: CGSize(width: -offset.width / scale, height: -offset.height / scale))
    }

    func apply(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    func apply(_ rect: CGRect) -> CGRect {
        CGRect(origin: apply(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func interpolated(to other: MapZoomTransform, _ t: Double) -> MapZoomTransform {
        let t = CGFloat(min(max(t, 0), 1))
        return MapZoomTransform(
            scale: scale + (other.scale - scale) * t,
            offset: CGSize(width: offset.width + (other.offset.width - offset.width) * t,
                           height: offset.height + (other.offset.height - offset.height) * t)
        )
    }
}

extension View {
    func mapZoom(_ transform: MapZoomTransform) -> some View {
        scaleEffect(transform.scale, anchor: .topLeading)
            .offset(transform.offset)
    }
}

/// A running drill-down (or up) animation between two layouts.
struct MapTransition {
    enum Kind: Equatable { case zoomIn, zoomOut, fade }
    var token: Int
    var kind: Kind
    var outgoing: MapLayoutCache.Entry
    /// Where the incoming layout starts (it ends at identity).
    var incomingStart: MapZoomTransform
    /// Where the outgoing layout ends (it starts at identity).
    var outgoingEnd: MapZoomTransform
}

/// Picks the transition for a root change. Pure, so it is unit-tested.
enum MapTransitionPlanner {
    struct Plan: Equatable {
        var kind: MapTransition.Kind
        var incomingStart: MapZoomTransform
        var outgoingEnd: MapZoomTransform
    }

    /// Zoom in when the new root is a tile of the old layout, zoom out when the old root is a
    /// tile of the new layout, otherwise cross-fade. Reduce Motion always cross-fades.
    static func plan(outgoing: [MapTile], incoming: [MapTile], from old: MapNodeID, to new: MapNodeID, bounds: CGRect, reduceMotion: Bool) -> Plan {
        let fade = Plan(kind: .fade, incomingStart: .identity, outgoingEnd: .identity)
        guard !reduceMotion, bounds.width > 0, bounds.height > 0 else { return fade }
        if let tile = outgoing.first(where: { $0.id == .node(new) }), tile.rect.width > 0, tile.rect.height > 0 {
            // The camera moves into the tile: the old layout grows until the tile fills the view,
            // the new layout starts where the tile was.
            let zoom = MapZoomTransform.fit(tile.rect, into: bounds)
            return Plan(kind: .zoomIn, incomingStart: zoom.inverse, outgoingEnd: zoom)
        }
        if let tile = incoming.first(where: { $0.id == .node(old) }), tile.rect.width > 0, tile.rect.height > 0 {
            let zoom = MapZoomTransform.fit(tile.rect, into: bounds)
            return Plan(kind: .zoomOut, incomingStart: zoom, outgoingEnd: zoom.inverse)
        }
        return fade
    }
}

// MARK: - Drawing

/// Fonts and thresholds for labels inside tiles.
enum MapLabelStyle {
    static let nameFont1 = Font.system(size: 12, weight: .semibold)
    static let nameFont2 = Font.system(size: 11, weight: .medium)
    static let sizeFont = Font.system(size: 11).monospacedDigit()
    static let insetX: CGFloat = 8
    static let insetY: CGFloat = 6
    /// Name plus size.
    static let twoLines = CGSize(width: 46, height: 34)
    /// Name only.
    static let oneLine = CGSize(width: 34, height: 19)
}

/// Draws every tile once per layout. Equatable on the layout revision, the palette id and the
/// color scheme, so hover and pointer movement never redraw it but palette changes do.
struct MapTilesLayer: View, Equatable {
    let tiles: [MapTile]
    let revision: Int
    let palette: any MapPalette
    let paletteID: Int
    let colorScheme: ColorScheme

    init(entry: MapLayoutCache.Entry, palette: any MapPalette, colorScheme: ColorScheme) {
        self.tiles = entry.tiles
        self.revision = entry.revision
        self.palette = palette
        self.paletteID = palette.paletteID.hashValue
        self.colorScheme = colorScheme
    }

    nonisolated static func == (lhs: MapTilesLayer, rhs: MapTilesLayer) -> Bool {
        lhs.revision == rhs.revision && lhs.paletteID == rhs.paletteID && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        let tiles = tiles
        let palette = palette
        Canvas { context, _ in
            for tile in tiles {
                MapTileDrawing.draw(tile, palette: palette, in: &context)
            }
        }
    }
}

enum MapTileDrawing {
    static func cornerRadius(for tile: MapTile) -> CGFloat {
        let base: CGFloat = tile.depth <= 1 ? 7 : 5
        return min(base, min(tile.rect.width, tile.rect.height) / 3)
    }

    static func shape(for tile: MapTile) -> Path {
        let radius = cornerRadius(for: tile)
        return radius < 1 ? Path(tile.rect) : Path(roundedRect: tile.rect, cornerRadius: radius, style: .continuous)
    }

    static func draw(_ tile: MapTile, palette: any MapPalette, in context: inout GraphicsContext) {
        let rect = tile.rect
        guard rect.width >= 0.5, rect.height >= 0.5 else { return }
        let shape = shape(for: tile)
        context.fill(shape, with: .color(palette.fill(for: tile)))
        if tile.isLocked { hatch(shape, rect: rect, color: palette.hatchColor(for: tile), in: context) }
        drawLabel(tile, palette: palette, in: &context)
    }

    static func hatch(_ shape: Path, rect: CGRect, color: Color, in context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: shape)
        var stripes = Path()
        let step: CGFloat = 7
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        clipped.stroke(stripes, with: .color(color), lineWidth: 2)
    }

    static func drawLabel(_ tile: MapTile, palette: any MapPalette, in context: inout GraphicsContext) {
        let rect = tile.rect
        guard rect.width >= MapLabelStyle.oneLine.width, rect.height >= MapLabelStyle.oneLine.height else { return }
        let width = rect.width - 2 * MapLabelStyle.insetX
        let nameFont = tile.depth <= 1 ? MapLabelStyle.nameFont1 : MapLabelStyle.nameFont2
        let origin = CGPoint(x: rect.minX + MapLabelStyle.insetX, y: rect.minY + MapLabelStyle.insetY)

        let name = fitted(tile.label, font: nameFont, color: palette.labelColor(for: tile), width: width, in: context)
        guard let name else { return }
        context.draw(name.text, at: origin, anchor: .topLeading)

        guard rect.width >= MapLabelStyle.twoLines.width, rect.height >= MapLabelStyle.twoLines.height else { return }
        if let size = fitted(MapText.size(tile.bytes), font: MapLabelStyle.sizeFont, color: palette.secondaryLabelColor(for: tile), width: width, in: context) {
            context.draw(size.text, at: CGPoint(x: origin.x, y: origin.y + name.height + 1), anchor: .topLeading)
        }
    }

    /// Resolves `string` on one line, truncated with an ellipsis to fit `width`. Nil if not even
    /// a couple of characters fit.
    static func fitted(_ string: String, font: Font, color: Color, width: CGFloat, in context: GraphicsContext) -> (text: GraphicsContext.ResolvedText, height: CGFloat)? {
        guard width > 8 else { return nil }
        func resolve(_ s: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(verbatim: s).font(font).foregroundStyle(color))
        }
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let full = resolve(string)
        let fullSize = full.measure(in: unbounded)
        if fullSize.width <= width { return (full, fullSize.height) }

        let characters = Array(string)
        var low = 0, high = characters.count - 1, best: GraphicsContext.ResolvedText?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = resolve(String(characters[0..<mid]).trimmingCharacters(in: .whitespaces) + "\u{2026}")
            if candidate.measure(in: unbounded).width <= width {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // Keep at least four characters; a stub like "Le..." says nothing.
        guard let best, low > 4 else { return nil }
        return (best, fullSize.height)
    }
}

/// Hover and selection outlines, drawn above the tiles.
struct MapHighlightLayer: View {
    let hovered: MapTile?
    let selected: MapTile?
    let palette: any MapPalette

    var body: some View {
        Canvas { context, _ in
            if let selected {
                let shape = MapTileDrawing.shape(for: selected)
                context.stroke(shape, with: .color(palette.highlight), lineWidth: 2)
            }
            if let hovered {
                let shape = MapTileDrawing.shape(for: hovered)
                context.fill(shape, with: .color(.white.opacity(0.22)))
                context.stroke(shape, with: .color(palette.highlight.opacity(0.55)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pointer location, observed only by the tooltip so pointer movement does not re-run the map's body.
@MainActor
@Observable
final class MapPointer {
    var location: CGPoint = .zero
}

/// Name and size next to the pointer.
struct MapTooltip: View {
    let tile: MapTile
    let pointer: MapPointer
    let bounds: CGRect

    var body: some View {
        let pointer = pointer.location
        let flipX = pointer.x > bounds.width * 0.62
        let flipY = pointer.y > bounds.height * 0.72
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: tile.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            Text(verbatim: MapText.size(tile.bytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .fixedSize()
        .alignmentGuide(.leading) { d in flipX ? d.width + 10 - pointer.x : -(pointer.x + 14) }
        .alignmentGuide(.top) { d in flipY ? d.height + 8 - pointer.y : -(pointer.y + 18) }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Holds the current tile action. The map writes it on every body pass, so an accessibility
/// element built in an earlier pass (and kept because its layer compared equal) still runs the
/// latest `onOpen`.
@MainActor
final class MapActionBox {
    var activate: (MapTile) -> Void = { _ in }
}

/// One synthetic accessibility element per tile (at most `MapAccessibility.maxElements`, the
/// largest ones), positioned over the tile. Equatable on the layout revision and size, so hover
/// updates never rebuild it; actions go through `MapActionBox`, so they are never stale.
struct MapAccessibilityTiles: View, Equatable {
    let tiles: [MapTile]
    let revision: Int
    let size: CGSize
    let actions: MapActionBox

    init(entry: MapLayoutCache.Entry, size: CGSize, actions: MapActionBox) {
        self.tiles = entry.tiles
        self.revision = entry.revision
        self.size = size
        self.actions = actions
    }

    nonisolated static func == (lhs: MapAccessibilityTiles, rhs: MapAccessibilityTiles) -> Bool {
        lhs.revision == rhs.revision && lhs.size == rhs.size
    }

    var body: some View {
        let actions = actions
        ZStack(alignment: .topLeading) {
            ForEach(MapAccessibility.elements(for: tiles)) { tile in
                // The element modifiers come before `.position`: a positioned view fills its
                // parent, so modifiers after it would give every element the whole map's frame.
                Rectangle()
                    .fill(.clear)
                    .frame(width: max(tile.rect.width, 1), height: max(tile.rect.height, 1))
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: MapText.accessibilityLabel(for: tile)))
                    .accessibilityIdentifier(MapText.accessibilityIdentifier(for: tile))
                    .accessibilityAddTraits(tile.isContainer || tile.isSmallerItems ? .isButton : [])
                    .accessibilityHint(Text(verbatim: tile.isSmallerItems ? MapText.expandHint : (tile.isContainer ? MapText.openHint : "")))
                    .accessibilityAction { actions.activate(tile) }
                    .position(x: tile.rect.midX, y: tile.rect.midY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
