import CleanupKit
import RulesKit
import SwiftUI

/// Risk is always color, word and icon together, so it survives color blindness.
struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Label {
            Text(Self.title(risk))
        } icon: {
            Image(systemName: Self.symbol(risk))
        }
        .labelStyle(BadgeLabelStyle())
        .foregroundStyle(Theme.risk(risk))
        .background(Theme.risk(risk).opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    static func title(_ risk: Risk) -> String {
        switch risk {
        case .safe: String(localized: "Safe", table: "UI")
        case .review: String(localized: "Review", table: "UI")
        case .dangerous: String(localized: "Keep", table: "UI")
        case .never: String(localized: "Locked", table: "UI")
        }
    }

    static func symbol(_ risk: Risk) -> String {
        switch risk {
        case .safe: "checkmark.shield"
        case .review: "eye"
        case .dangerous: "hand.raised"
        case .never: "lock"
        }
    }
}

/// Who put an item in the cleanup queue.
struct SourceBadge: View {
    let source: QueueSource
    var categoryTitle: String?

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(BadgeLabelStyle())
        .foregroundStyle(Theme.secondaryInk)
        .background(Theme.well, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch source {
        case .user: String(localized: "Added by you", table: "UI")
        case .category: categoryTitle ?? String(localized: "From a category", table: "UI")
        case .assistant: String(localized: "Suggested by the assistant", table: "UI")
        }
    }

    private var symbol: String {
        switch source {
        case .user: "person"
        case .category: "square.stack"
        case .assistant: "bubble.left"
        }
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
        .font(Theme.Fonts.labelStrong)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
    }
}
