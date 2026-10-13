import AppCore
import ScanKit
import SwiftUI
import VizKit

/// The only file that talks to VizKit. Everything the rest of the app needs from the space map
/// goes through here, so a VizKit API change is a one-file change.
///
/// Contract for the rest of the app:
/// - draws `root`'s children (two levels, squarified), colored by `insights`
/// - `onOpen(node)` when a folder tile is clicked (drill down; the map zooms in)
/// - `onSelect(node)` when a file tile is clicked
/// - `onHover(text)` with "name, size" of the tile under the pointer, or nil
/// - highlights `selection`
/// - AX ids `explore.map`, `explore.tile.<name>`, `explore.tile.smallItems.<parent>` (from VizKit)
struct SpaceMapContainer: View {
    let insights: SessionInsights
    let root: NodeID
    var selection: NodeID?
    var onOpen: (NodeID) -> Void
    var onSelect: (NodeID) -> Void
    var onHover: (String?) -> Void = { _ in }

    var body: some View {
        if let source = insights.session.mapSource {
            map(source)
        }
    }

    /// AppCore keeps one `TreeMapSource` per tree (identity = the tree, revision bumped when the
    /// colours change), so the map's layout cache stays warm across body passes.
    private func map(_ source: TreeMapSource) -> some View {
        SpaceMapView(
            source: source,
            root: root,
            palette: Self.palette,
            layout: TreemapLayout(),
            options: MapLayoutOptions(),
            selection: selection
        ) { id in
            if source.mapIsContainer(id) { onOpen(id) } else { onSelect(id) }
        }
        .onTileHover { tile in
            onHover(tile.map { MapText.accessibilityLabel(for: $0) })
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
    }

    /// Same words as the map's merged tile, for the children list's grouping row.
    static func smallerItemsLabel(count: Int) -> String {
        MapText.smallerItemsLabel(count: count)
    }

    /// Share of the current folder below which the map merges a child into its small-items
    /// tile; the children list groups with the same cut-off so both count the same N.
    static let smallItemShare = MapLayoutOptions().minTileFraction

    /// Built once from the theme's static colors, so the map's palette identity stays stable.
    private static let palette = CategoryMapPalette(
        colors: Dictionary(uniqueKeysWithValues: SpaceCategory.allCases.map { ($0.rawValue, Theme.category($0)) }),
        fallback: Theme.category(.other),
        smallItems: Theme.well,
        background: Theme.window,
        label: Theme.ink,
        highlight: Theme.ink,
        frameWash: Theme.containerWash
    )
}
