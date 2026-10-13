import Foundation

/// Which tiles get an accessibility element.
public enum MapAccessibility {
    /// Most accessibility elements the map exposes at once.
    public static let maxElements = 2_000

    /// `tiles` when there are at most `limit`; otherwise the `limit` largest tiles by area,
    /// in their original (drawing) order.
    public static func elements(for tiles: [MapTile], limit: Int = maxElements) -> [MapTile] {
        guard tiles.count > limit else { return tiles }
        guard limit > 0 else { return [] }
        let chosen = tiles.indices
            .sorted { a, b in
                let areaA = tiles[a].rect.width * tiles[a].rect.height
                let areaB = tiles[b].rect.width * tiles[b].rect.height
                return areaA != areaB ? areaA > areaB : a < b
            }
            .prefix(limit)
            .sorted()
        return chosen.map { tiles[$0] }
    }
}

/// Text shown or spoken by the space map. Strings live in VizKit's String Catalog.
public enum MapText {
    /// Byte count with the app's shared formatter ("19.5 GB", see `ByteFormat`).
    public static func size(_ bytes: UInt64) -> String {
        ByteFormat.string(bytes)
    }

    /// Label of the merged tile that holds a parent's small children.
    public static func smallerItemsLabel(count: Int) -> String {
        String(localized: "\(count) small items", bundle: .module, comment: "Space map tile that groups many small files and folders")
    }

    /// Accessibility label of a tile: "name, size".
    public static func accessibilityLabel(for tile: MapTile) -> String {
        accessibilityLabel(name: tile.label, bytes: tile.bytes)
    }

    /// Accessibility label for a name and a size: "name, size".
    public static func accessibilityLabel(name: String, bytes: UInt64) -> String {
        let size = size(bytes)
        return String(localized: "tile.accessibilityLabel", defaultValue: "\(name), \(size)", bundle: .module, comment: "Accessibility label of a space map tile: item name, then its size")
    }

    /// Accessibility identifier of a tile: `explore.tile.<name>`, `explore.tile.smallItems.<parent id>` for a merged tile.
    public static func accessibilityIdentifier(for tile: MapTile) -> String {
        switch tile.id {
        case .node: "explore.tile.\(tile.label)"
        case .smallerItems(let parent): "explore.tile.smallItems.\(parent)"
        }
    }

    /// Accessibility label of the whole map.
    public static var mapAccessibilityLabel: String {
        String(localized: "Space map", bundle: .module, comment: "Accessibility label of the space map: blocks sized by how much space each item uses")
    }

    /// Accessibility hint of a tile that opens when activated.
    public static var openHint: String {
        String(localized: "Opens this folder in the map.", bundle: .module, comment: "Accessibility hint for a folder tile in the space map")
    }

    /// Accessibility hint of the merged small-items tile.
    public static var expandHint: String {
        String(localized: "Shows the small items as separate blocks.", bundle: .module, comment: "Accessibility hint for the merged small items tile")
    }
}
