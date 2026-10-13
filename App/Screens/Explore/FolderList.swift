import AppCore
import RulesKit
import ScanKit
import SwiftUI

/// Children of the current folder, largest first, with a share bar and risk badge.
/// At the volume root it adds rows for free space, space the scan can't see, purgeable space and other volumes.
/// Keyboard: arrows move, Return opens a folder, Space toggles Quick Look.
struct FolderList: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel
    let insights: SessionInsights
    @State private var showsSmallerItems = false

    private var tree: any TreeReading { insights.tree }

    var body: some View {
        let _ = SessionInsights.observeRevisions(of: session)
        let parentSize = max(tree.size(session.current), 1)
        let children = tree.children(session.current)
        let split = splitChildren(children, parentSize: parentSize)
        List(selection: selection) {
            ForEach(split.visible, id: \.self) { id in
                row(id, parentSize: parentSize)
                    .tag(id)
            }
            if !split.smaller.isEmpty {
                SmallerItemsRow(
                    count: split.smaller.count,
                    bytes: split.smaller.reduce(UInt64(0)) { $0 + tree.size($1) },
                    isExpanded: $showsSmallerItems
                )
                if showsSmallerItems {
                    ForEach(split.smaller.prefix(2_000), id: \.self) { id in
                        row(id, parentSize: parentSize)
                            .tag(id)
                    }
                }
            }
            if session.current == tree.root, let summary = session.summary {
                SpecialRows(summary: summary, purgeableCountedAsFree: model.settings.purgeableCountedAsFree)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: NodeID.self) { ids in
            if let id = ids.first {
                ItemContextMenu(session: session, insights: insights, id: id)
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            if !tree.children(id).isEmpty, !tree.flags(id).contains(.package) {
                session.navigate(to: id)
            } else {
                FileActions.quickLook(tree.path(id))
            }
        }
        .onKeyPress(.space) {
            guard let id = session.selection else { return .ignored }
            FileActions.quickLook(tree.path(id))
            return .handled
        }
        .onChange(of: session.current) { showsSmallerItems = false }
        .accessibilityIdentifier("explore.list")
    }

    private var selection: Binding<NodeID?> {
        Binding(get: { session.selection }, set: { session.selection = $0 })
    }

    /// Children below the map's small-items share group into one row, so the list and the
    /// map's merged tile count the same N with the same words.
    private func splitChildren(_ children: [NodeID], parentSize: UInt64) -> (visible: [NodeID], smaller: [NodeID]) {
        var visible: [NodeID] = []
        var smaller: [NodeID] = []
        for id in children {
            if Double(tree.size(id)) / Double(parentSize) >= SpaceMapContainer.smallItemShare {
                visible.append(id)
            } else {
                smaller.append(id)
            }
        }
        return (visible, smaller)
    }

    private func row(_ id: NodeID, parentSize: UInt64) -> some View {
        FolderRow(
            name: tree.name(id),
            symbol: Self.symbol(flags: tree.flags(id), name: tree.name(id)),
            bytes: tree.size(id),
            share: Double(tree.size(id)) / Double(parentSize),
            category: insights.color(of: id) ?? .other,
            risk: insights.category(covering: id)?.risk
        )
    }

    static func symbol(flags: NodeFlags, name: String) -> String {
        if flags.contains(.notResponding) { return "hourglass" }
        if flags.contains(.restricted) { return "lock" }
        if flags.contains(.symlink) { return "arrowshape.turn.up.right" }
        if flags.contains(.package) { return name.lowercased().hasSuffix(".app") ? "app" : "shippingbox" }
        if flags.contains(.directory) { return "folder" }
        return "doc"
    }
}

/// One child row. Text flips to the selection label on an emphasized selection.
private struct FolderRow: View {
    let name: String
    let symbol: String
    let bytes: UInt64
    let share: Double
    let category: SpaceCategory
    let risk: Risk?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(category.color)
                .frame(width: 8, height: 8)
            Image(systemName: symbol)
                .foregroundStyle(Theme.rowTertiary)
                .frame(width: 16)
            Text(name)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.rowPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 12)
            ShareBar(fraction: share, color: category.color)
                .frame(minWidth: 40, maxWidth: 160)
                .frame(height: 4)
            Text(Format.bytes(bytes))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.rowPrimary)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Group {
                if let risk { RiskBadge(risk: risk) } else { Color.clear }
            }
            .frame(width: 78, alignment: .leading)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("explore.list.row.\(name)")
    }
}

/// Thin proportional bar.
struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule().fill(color)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 2))
            }
        }
    }
}

private struct SmallerItemsRow: View {
    let count: Int
    let bytes: UInt64
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Fonts.disclosure)
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(width: 34)
                Text(SpaceMapContainer.smallerItemsLabel(count: count))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Text(Format.bytes(bytes))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
                Color.clear.frame(width: 78)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("explore.list.smallerItems")
    }
}

/// Space that is not a file: free (as light), hidden, purgeable, other volumes.
private struct SpecialRows: View {
    let summary: SpaceSummary
    let purgeableCountedAsFree: Bool

    var body: some View {
        special(.free, String(localized: "Free space", table: "UI"), bytes: summary.free + (purgeableCountedAsFree ? summary.purgeable : 0),
                note: String(localized: "Room you have right now", table: "UI"), id: "free")
        if summary.hidden > 0 {
            special(.hidden, String(localized: "Space Lightwell can't see", table: "UI"), bytes: summary.hidden,
                    note: String(localized: "System files, snapshots and folders closed to Lightwell", table: "UI"), id: "hidden")
        }
        if summary.purgeable > 0, !purgeableCountedAsFree {
            special(.used, String(localized: "Purgeable", table: "UI"), bytes: summary.purgeable,
                    note: String(localized: "macOS frees this on its own when space runs low", table: "UI"), id: "purgeable")
        }
        if summary.otherVolumes > 0 {
            special(.used, String(localized: "Other volumes on this disk", table: "UI"), bytes: summary.otherVolumes,
                    note: String(localized: "They share storage with this volume", table: "UI"), id: "otherVolumes")
        }
    }

    private func special(_ kind: CapacitySegment.Kind, _ title: String, bytes: UInt64, note: String, id: String) -> some View {
        HStack(spacing: 10) {
            CapacityBar(segments: [CapacitySegment(kind: kind, bytes: 1)], height: 8, spacing: 0)
                .frame(width: 8)
            Image(systemName: kind == .free ? "sun.max" : kind == .hidden ? "eye.slash" : "arrow.3.trianglepath")
                .foregroundStyle(Theme.tertiaryInk)
                .frame(width: 16)
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.secondaryInk)
            Text(note)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.tertiaryInk)
                .lineLimit(1)
            Spacer()
            Text(Format.bytes(bytes))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.secondaryInk)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Color.clear.frame(width: 78)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("explore.list.special.\(id)")
    }
}

/// Context menu for a file or folder in the list or inspector.
struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let session: ScanSessionModel
    let insights: SessionInsights
    let id: NodeID

    var body: some View {
        let tree = insights.tree
        let path = tree.path(id)
        let isFolder = tree.flags(id).contains(.directory)
        if isFolder, !tree.children(id).isEmpty, !tree.flags(id).contains(.package) {
            Button(String(localized: "Open", table: "UI")) { session.navigate(to: id) }
        }
        Button(String(localized: "Quick Look", table: "UI")) { FileActions.quickLook(path) }
        Button(String(localized: "Reveal in Finder", table: "UI")) { FileActions.reveal(path) }
        Button(String(localized: "Copy Path", table: "UI")) { FileActions.copyPath(path) }
        Button(String(localized: "Open in Terminal", table: "UI")) { FileActions.openInTerminal(path, isDirectory: isFolder) }
        Divider()
        Button(String(localized: "Add to Cleanup", table: "UI")) {
            let summary = tree.summary(of: id)
            Task {
                let result = await model.cleanup.queue(summary, source: .user)
                if !result.isSuccess {
                    flow.notice = result.message(retryable: model.cleanup.lastAddRetryable && session.staleReason == nil)
                }
            }
        }
        .disabled(!insights.canQueue(id))
    }
}
