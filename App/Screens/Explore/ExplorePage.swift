import AppCore
import RulesKit
import ScanKit
import SwiftUI

/// Explore: breadcrumb, space map of the current folder, sorted children list, item details.
struct ExplorePage: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel
    /// Hover text lives in its own observable object, so pointer moves over the map only
    /// re-render the header hint, not this page or the list.
    @State private var hover = MapHover()

    var body: some View {
        if let tree = session.tree, let insights = SessionInsights(session: session) {
            // The outer reader takes exactly the space the window offers and reports a minimum
            // height of zero, so the inspector's wrapping note can never make the page taller than
            // the window (in the split view a tall minimum pushed the whole window out of shape).
            GeometryReader { _ in
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            BreadcrumbBar(session: session, tree: tree)
                            header(tree: tree)
                            if session.unresponsiveFolderCount > 0 {
                                Label(String(localized: "\(session.unresponsiveFolderCount) folders did not respond during the scan, so their sizes are unknown.", table: "UI"), systemImage: "hourglass")
                                    .font(Theme.Fonts.callout)
                                    .foregroundStyle(Theme.secondaryInk)
                                    .accessibilityIdentifier("explore.unresponsive")
                            }
                            SpaceMapContainer(
                                insights: insights,
                                root: session.current,
                                selection: session.selection,
                                onOpen: { session.navigate(to: $0) },
                                onSelect: { session.selection = $0 },
                                onHover: { [hover] in hover.text = $0 }
                            )
                            .frame(height: max(200, proxy.size.height * 0.42))
                        }
                        .padding(.horizontal, Theme.Metrics.pagePadding)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                        FolderList(session: session, insights: insights)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ItemInspector(session: session, insights: insights)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func header(tree: any TreeReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tree.name(session.current))
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(Format.bytes(tree.size(session.current)))
                .font(Theme.Fonts.figureSmall)
                .foregroundStyle(Theme.secondaryInk)
                .monospacedDigit()
                .accessibilityIdentifier("explore.mapHeader.size")
            Spacer(minLength: 12)
            HoverHint(hover: hover)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.mapHeader")
    }
}

/// Pointer state for the map, observed only by `HoverHint`.
@Observable
final class MapHover {
    var text: String?
}

/// "name, size" of the tile under the pointer, or how to use the map.
private struct HoverHint: View {
    let hover: MapHover

    var body: some View {
        Group {
            if let text = hover.text {
                Text(text)
            } else {
                Text("Click a block to open it. Area is size.", tableName: "UI")
            }
        }
        .font(Theme.Fonts.callout)
        .foregroundStyle(Theme.tertiaryInk)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// Root to current folder; every crumb is a button. Up goes to the enclosing folder.
private struct BreadcrumbBar: View {
    let session: ScanSessionModel
    let tree: any TreeReading

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    let crumbs = session.breadcrumb
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, id in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(Theme.Fonts.crumbSeparator)
                                .foregroundStyle(Theme.tertiaryInk)
                        }
                        let isLast = index == crumbs.count - 1
                        Button {
                            session.navigate(to: id)
                        } label: {
                            Text(tree.name(id))
                                .font(isLast ? Theme.Fonts.bodyStrong : Theme.Fonts.body)
                                .foregroundStyle(isLast ? Theme.ink : Theme.secondaryInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isLast ? Theme.well : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("explore.breadcrumb.\(index)")
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 8)
            Button {
                session.goUp()
            } label: {
                Label(String(localized: "Up", table: "UI"), systemImage: "arrow.up")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(session.current == tree.root)
            .help(String(localized: "Go to the enclosing folder", table: "UI"))
            .accessibilityIdentifier("explore.up")
        }
    }
}
