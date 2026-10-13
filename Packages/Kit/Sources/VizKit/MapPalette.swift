import AppKit
import SwiftUI

/// Colors for the space map. The app theme implements it.
///
/// `fill(for:)` sees the whole tile, so a palette can color by `category`, wash out frames
/// (`isFrame`), and treat the merged small-items tile (`isSmallerItems`) or locked tiles differently.
public protocol MapPalette: Sendable {
    func fill(for tile: MapTile) -> Color
    func labelColor(for tile: MapTile) -> Color
    var background: Color { get }
    var highlight: Color { get }
    /// Second label line (the size). Default: the label color at 70% opacity.
    func secondaryLabelColor(for tile: MapTile) -> Color
    /// Stripes drawn over locked tiles. Default: the label color at 16% opacity.
    func hatchColor(for tile: MapTile) -> Color
    /// Changes whenever the palette's colors change; the map redraws when it does.
    /// Default: the palette itself when it is `Hashable`, otherwise its type.
    var paletteID: AnyHashable { get }
}

extension MapPalette {
    public var paletteID: AnyHashable {
        (self as? AnyHashable) ?? AnyHashable(ObjectIdentifier(Self.self))
    }
    public func secondaryLabelColor(for tile: MapTile) -> Color { labelColor(for: tile).opacity(0.7) }
    public func hatchColor(for tile: MapTile) -> Color { labelColor(for: tile).opacity(0.16) }
}

/// Neutral placeholder palette (warm greys, light and dark), used until the theme provides one.
public struct NeutralMapPalette: MapPalette, Hashable {
    public init() {}

    public func fill(for tile: MapTile) -> Color {
        if tile.isSmallerItems { return MapColor.dynamic(light: 0xECE9E3, dark: 0x2C2A26) }
        if tile.isFrame { return MapColor.dynamic(light: 0xEFECE6, dark: 0x2A2925) }
        return tile.depth <= 1
            ? MapColor.dynamic(light: 0xE3DFD7, dark: 0x34322E)
            : MapColor.dynamic(light: 0xD8D3CA, dark: 0x403D38)
    }

    public func labelColor(for tile: MapTile) -> Color { MapColor.dynamic(light: 0x1D1C19, dark: 0xF2EFE8) }
    public var background: Color { MapColor.dynamic(light: 0xF7F5F0, dark: 0x1B1A18) }
    public var highlight: Color { MapColor.dynamic(light: 0x1D1C19, dark: 0xF2EFE8) }
}

/// Palette that colors tiles by `MapTile.category`, the way direction A does: leaves take their
/// category color, frames take a wash of it over the background so their children stand out.
/// `Hashable`, so changing any color redraws the map. Keep the `Color` values stable (for example
/// static theme colors): a color rebuilt from a new `NSColor` on every pass hashes differently.
public struct CategoryMapPalette: MapPalette, Hashable {
    public var colors: [String: Color]
    public var fallback: Color
    public var smallItems: Color
    public var background: Color
    public var highlight: Color
    public var label: Color
    /// Share of the category color in a frame's fill (the rest is background).
    public var frameWash: Double

    public init(
        colors: [String: Color],
        fallback: Color,
        smallItems: Color? = nil,
        background: Color,
        label: Color,
        highlight: Color? = nil,
        frameWash: Double = 0.45
    ) {
        self.colors = colors
        self.fallback = fallback
        self.smallItems = smallItems ?? fallback
        self.background = background
        self.label = label
        self.highlight = highlight ?? label
        self.frameWash = frameWash
    }

    public func fill(for tile: MapTile) -> Color {
        if tile.isSmallerItems { return smallItems }
        let base = tile.category.flatMap { colors[$0] } ?? fallback
        return tile.isFrame ? base.mix(with: background, by: 1 - frameWash) : base
    }

    public func labelColor(for tile: MapTile) -> Color { label }
}

/// Internal color helpers (kept internal so they never clash with the app's own extensions).
enum MapColor {
    /// Dynamic color from two 0xRRGGBB values, resolved against the current appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return rgb(hex)
        })
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
