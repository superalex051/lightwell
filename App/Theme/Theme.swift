import RulesKit
import SwiftUI

/// Design direction A, "Daylight": every color, font, material, metric and motion curve the app uses.
/// Colors live in the asset catalog (`Assets.xcassets/Colors`) with light and dark appearances.
/// Screens never use literal colors; they ask `Theme`.
nonisolated enum Theme {
    // MARK: Surfaces and ink

    static let window = Color("Window")
    static let raised = Color("Raised")
    /// Recessed fill for bar tracks, chips and wells.
    static let well = Color("Well")
    static let hairline = Color("Hairline")
    static let ink = Color("Ink")
    static let secondaryInk = Color("InkSecondary")
    static let tertiaryInk = Color("InkTertiary")
    static let inkButton = Color("InkButton")
    static let inkButtonLabel = Color("InkButtonLabel")

    // MARK: Signature: free space drawn as light

    static let light = Color("Light")
    static let lightDeep = Color("LightDeep")

    // MARK: Selection (lists)

    /// List selection uses the app accent (AccentColor asset: calm slate, not ink). Row text uses
    /// these hierarchical styles so it turns light on an emphasized selection.
    static let rowPrimary = HierarchicalShapeStyle.primary
    static let rowSecondary = HierarchicalShapeStyle.secondary
    static let rowTertiary = HierarchicalShapeStyle.tertiary

    // MARK: Risk and danger

    static let danger = Color("Danger")

    static func risk(_ risk: Risk) -> Color {
        switch risk {
        case .safe: Color("RiskSafe")
        case .review: Color("RiskReview")
        case .dangerous, .never: Color("RiskKeep")
        }
    }

    static func category(_ category: SpaceCategory) -> Color {
        switch category {
        case .projects: Color("CategoryProjects")
        case .developer: Color("CategoryDeveloper")
        case .apps: Color("CategoryApps")
        case .appData: Color("CategoryAppData")
        case .media: Color("CategoryMedia")
        case .caches: Color("CategoryCaches")
        case .downloads: Color("CategoryDownloads")
        case .system: Color("CategorySystem")
        case .other: Color("CategoryOther")
        }
    }

    /// Parent tiles in the map take a wash of their category color (design notes: 45%).
    static let containerWash: Double = 0.45

    // MARK: Type scale (SF Pro Text for UI, SF Pro Rounded for figures, New York for the summary voice)

    enum Fonts {
        static let label = Font.system(size: 11, weight: .medium)
        static let labelStrong = Font.system(size: 11, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let callout = Font.system(size: 12)
        static let section = Font.system(size: 15, weight: .semibold)
        static let screenTitle = Font.system(size: 22, weight: .semibold)
        static let figure = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let figureSmall = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let hero = Font.system(size: 54, weight: .semibold, design: .rounded)
        static let heroCaption = Font.system(size: 20, weight: .medium, design: .rounded)
        static let path = Font.system(size: 11, design: .monospaced)
        static let code = Font.system(size: 11.5, design: .monospaced)
        /// Direction C's bookish voice, used for the plain-language summaries.
        static let summaryHeadline = Font.system(size: 26, weight: .regular, design: .serif)
        static let summaryBody = Font.system(size: 15.5, design: .serif)
        /// SF Symbols sizes.
        static let iconLarge = Font.system(size: 22)
        static let icon = Font.system(size: 20)
        static let disclosure = Font.system(size: 10, weight: .semibold)
        static let crumbSeparator = Font.system(size: 9, weight: .semibold)
    }

    // MARK: Metrics

    enum Metrics {
        static let cardRadius: CGFloat = 14
        static let controlRadius: CGFloat = 8
        static let tileRadius: CGFloat = 5
        static let pagePadding: CGFloat = 24
        static let rowSpacing: CGFloat = 10
        static let barHeight: CGFloat = 26
        static let sidebarWidth: CGFloat = 228
        static let inspectorWidth: CGFloat = 350
    }

    // MARK: Motion (160 to 300 ms ease-out, opacity only when Reduce Motion is on)

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.16)
        static let standard = Animation.easeOut(duration: 0.24)
        static let page = Animation.easeOut(duration: 0.3)
        static let pressScale: CGFloat = 0.97
    }

    // MARK: Materials

    /// Glass for floating chrome (inspector bar, queue bar). Falls back to a material automatically.
    static let glassShape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
}
