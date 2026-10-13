import AppCore
import SwiftUI

/// The nine color families of the space map and capacity bar (design A).
/// `init(categoryID:)` maps every knowledge-base category id (rules.json `category`) onto one
/// of them; `MapTile.category` carries the raw value.
nonisolated enum SpaceCategory: String, CaseIterable, Identifiable, Sendable {
    case projects
    case developer
    case apps
    case appData
    case media
    case caches
    case downloads
    case system
    case other

    var id: String { rawValue }

    /// Colour for a knowledge-base category id (rules.json `category`), using AppCore's vocabulary.
    init(categoryID: String?) {
        self.init(family: categoryID.map(SpaceFamily.init(ruleCategory:)) ?? .other)
    }

    init(family: SpaceFamily) {
        self = SpaceCategory(rawValue: family.rawValue) ?? .other
    }

    var title: String {
        switch self {
        case .projects: String(localized: "Projects", table: "UI")
        case .developer: String(localized: "Developer tools", table: "UI")
        case .apps: String(localized: "Apps", table: "UI")
        case .appData: String(localized: "App data", table: "UI")
        case .media: String(localized: "Photos and media", table: "UI")
        case .caches: String(localized: "Caches", table: "UI")
        case .downloads: String(localized: "Downloads", table: "UI")
        case .system: String(localized: "System", table: "UI")
        case .other: String(localized: "Everything else", table: "UI")
        }
    }

    var color: Color { Theme.category(self) }
}
