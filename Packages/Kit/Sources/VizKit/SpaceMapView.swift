import SwiftUI

/// Space map: a two-level squarified treemap of `root`'s children, drawn with `Canvas`.
///
/// - Hover highlights the tile under the pointer and shows its name and size.
/// - Click on a node tile calls `onOpen` with its id (the app decides whether to navigate).
///   When the app then changes `root` to that node, the map zooms into the tile; when `root`
///   changes to an ancestor, it zooms back out (uniform scale). Other root changes cross-fade.
/// - Click on a small-items tile expands it in place into separate tiles (capped by
///   `MapLayoutOptions.maxExpandedTiles`).
/// - Layouts are cached per tree identity (`mapIdentityObject`), generation, `mapRevision`,
///   root, size and options. Palette changes (`paletteID`) redraw without a relayout.
/// - Accessibility: the map is `explore.map`; every tile (up to `MapAccessibility.maxElements`,
///   the largest first) is a child element with the label "name, size" and the id
///   `explore.tile.<name>` (`explore.tile.smallItems.<parent id>` for a merged tile).
public struct SpaceMapView<Source: MapDataSource>: View {
    private let source: Source
    private let root: MapNodeID
    private let palette: any MapPalette
    private let layout: any MapLayout
    private let options: MapLayoutOptions
    private let selection: MapNodeID?
    private var onHover: ((MapTile?) -> Void)?
    private let onOpen: (MapNodeID) -> Void

    @State private var cache = MapLayoutCache()
    @State private var actions = MapActionBox()
    @State private var hoveredID: MapTileID?
    @State private var pointer = MapPointer()
    @State private var expanded: Set<MapNodeID> = []
    @State private var transition: MapTransition?
    @State private var progress: Double = 1
    @State private var transitionCounter = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - source: The tree to draw.
    ///   - root: The folder whose children fill the map.
    ///   - palette: Tile colors. The app theme provides one.
    ///   - layout: Layout algorithm (squarified treemap by default).
    ///   - options: Layout tuning (depth, small-items threshold, padding, frame header).
    ///   - selection: A node to outline (for example the item shown in the inspector).
    ///   - onOpen: Called with the node id of a clicked tile (or one activated with VoiceOver).
    public init(
        source: Source,
        root: MapNodeID,
        palette: any MapPalette = NeutralMapPalette(),
        layout: any MapLayout = TreemapLayout(),
        options: MapLayoutOptions = MapLayoutOptions(),
        selection: MapNodeID? = nil,
        onOpen: @escaping (MapNodeID) -> Void = { _ in }
    ) {
        self.source = source
        self.root = root
        self.palette = palette
        self.layout = layout
        self.options = options
        self.selection = selection
        self.onOpen = onOpen
    }

    public var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let current = entry(root: root, bounds: bounds)
            let tiles = current.tiles
            let hovered = transition == nil ? hoveredID.flatMap { id in tiles.first { $0.id == id } } : nil
            let selected = selection.flatMap { id in tiles.first { $0.id == .node(id) } }
            let _ = (actions.activate = activate)

            ZStack(alignment: .topLeading) {
                palette.background
                if let transition {
                    MapTilesLayer(entry: transition.outgoing, palette: palette, colorScheme: colorScheme)
                        .equatable()
                        .mapZoom(MapZoomTransform.identity.interpolated(to: transition.outgoingEnd, progress))
                        .opacity(1 - progress)
                }
                MapTilesLayer(entry: current, palette: palette, colorScheme: colorScheme)
                    .equatable()
                    .mapZoom((transition?.incomingStart ?? .identity).interpolated(to: .identity, progress))
                    .opacity(transition == nil ? 1 : (transition?.kind == .fade ? progress : min(1, 0.35 + progress)))
                if transition == nil {
                    MapHighlightLayer(hovered: hovered, selected: selected, palette: palette)
                    if let hovered {
                        MapTooltip(tile: hovered, pointer: pointer, bounds: bounds)
                    }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            // The drawing has no elements of its own; the tiles below stand in for it.
            .accessibilityHidden(true)
            // Real (laid out) views, so every tile element has the frame of its drawn tile and
            // VoiceOver and UI tests can find and press it. They never take the pointer: hover
            // and clicks reach the map's own handlers underneath.
            .overlay(alignment: .topLeading) {
                MapAccessibilityTiles(entry: current, size: bounds.size, actions: actions)
                    .equatable()
                    .allowsHitTesting(false)
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    pointer.location = location
                    if transition == nil { setHovered(TreemapLayout.hitTest(tiles, at: location)) }
                case .ended:
                    setHovered(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let tile = TreemapLayout.hitTest(tiles, at: value.location) { activate(tile) }
            })
            .pointerStyle(hovered.map { $0.isContainer || $0.isSmallerItems } == true ? .link : nil)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: MapText.mapAccessibilityLabel))
            .accessibilityIdentifier("explore.map")
            .onChange(of: root) { old, new in startTransition(from: old, to: new) }
            .onChange(of: current.revision) { dropHoverIfGone(from: tiles) }
            .onChange(of: source.generation) { expanded = [] }
        }
    }

    /// Calls `action` when the tile under the pointer changes (nil when the pointer leaves the map).
    /// A modifier rather than an init parameter, so a trailing closure on the init stays `onOpen`.
    public func onTileHover(_ action: @escaping (MapTile?) -> Void) -> Self {
        var copy = self
        copy.onHover = action
        return copy
    }

    // MARK: Layout

    private var effectiveOptions: MapLayoutOptions {
        var result = options
        result.expandedParents.formUnion(expanded)
        return result
    }

    private func entry(root: MapNodeID, bounds: CGRect) -> MapLayoutCache.Entry {
        cache.entry(source: source, root: root, bounds: bounds, options: effectiveOptions, layout: layout)
    }

    private func setHovered(_ tile: MapTile?) {
        guard tile?.id != hoveredID else { return }
        hoveredID = tile?.id
        onHover?(tile)
    }

    /// A relayout can drop the hovered tile (rescan, deletion, expansion): tell the app.
    private func dropHoverIfGone(from tiles: [MapTile]) {
        guard let id = hoveredID, !tiles.contains(where: { $0.id == id }) else { return }
        setHovered(nil)
    }

    // MARK: Interaction

    private func activate(_ tile: MapTile) {
        switch tile.id {
        case .node(let id):
            onOpen(id)
        case .smallerItems(let parent):
            expanded.insert(parent)
        }
    }

    private func startTransition(from old: MapNodeID, to new: MapNodeID) {
        setHovered(nil)
        let bounds = cache.bounds
        guard bounds.width > 0, bounds.height > 0,
              let outgoing = cache.previousEntry(root: old, size: bounds.size, identity: source.mapIdentityObject) else {
            transition = nil
            return
        }
        let incoming = entry(root: new, bounds: bounds)
        let plan = MapTransitionPlanner.plan(
            outgoing: outgoing.tiles, incoming: incoming.tiles,
            from: old, to: new, bounds: bounds, reduceMotion: reduceMotion
        )
        transitionCounter += 1
        let token = transitionCounter
        transition = MapTransition(token: token, kind: plan.kind, outgoing: outgoing, incomingStart: plan.incomingStart, outgoingEnd: plan.outgoingEnd)
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }
        let duration = reduceMotion ? 0.18 : 0.28
        // Start on the next turn of the run loop so the first frame renders at progress 0.
        Task { @MainActor in
            withAnimation(.easeOut(duration: duration)) {
                progress = 1
            } completion: {
                if transition?.token == token { transition = nil }
            }
        }
    }
}
