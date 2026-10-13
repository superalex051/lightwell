import AppCore
import RulesKit
import ScanKit
import SwiftUI

/// Reclaim: knowledge-base categories grouped by risk, with sizes, explanations, items,
/// guidance commands and "Add All Safe Items".
struct ReclaimView: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel
    @AppStorage(UIPreferences.showsTechnicalDetailsKey) private var showsTechnicalDetails = false
    @State private var lastAdded: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if session.categories.isEmpty {
                    emptyState
                }
                ForEach(Risk.allCases, id: \.self) { risk in
                    let group = session.categories.filter { $0.risk == risk }.sorted { $0.bytes > $1.bytes }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                RiskBadge(risk: risk)
                                Text(Self.groupTitle(risk))
                                    .font(Theme.Fonts.section)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text(Format.bytes(group.reduce(0) { $0 + $1.bytes }))
                                    .font(Theme.Fonts.figureSmall)
                                    .foregroundStyle(Theme.ink)
                                    .monospacedDigit()
                            }
                            Text(Self.groupNote(risk))
                                .font(Theme.Fonts.callout)
                                .foregroundStyle(Theme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(spacing: 8) {
                                ForEach(group) { category in
                                    CategoryCard(session: session, category: category, showsRuleID: showsTechnicalDetails)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.pagePadding + 8)
            .padding(.vertical, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reclaim", tableName: "UI")
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text("Known kinds of clutter, grouped by how sure Lightwell is that removing them is harmless.", tableName: "UI")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastAdded {
                    Text(lastAdded)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.risk(.safe))
                        .accessibilityIdentifier("reclaim.feedback")
                }
            }
            Spacer(minLength: 16)
            let safe = session.safeCategories.reduce(UInt64(0)) { $0 + $1.bytes }
            Button {
                let added = model.cleanup.addSafeItems(from: session).filter(\.isSuccess).count
                lastAdded = added > 0
                    ? String(localized: "Added \(added) safe items to the cleanup queue, ticked.", table: "UI")
                    : String(localized: "Nothing new to add: the safe items are already in the queue.", table: "UI")
            } label: {
                Label(String(localized: "Add All Safe Items (\(Format.bytes(safe)))", table: "UI"), systemImage: "checkmark.shield")
            }
            .buttonStyle(InkButtonStyle())
            .disabled(safe == 0)
            .fixedSize()
            .accessibilityIdentifier("reclaim.addSafe")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing familiar here", tableName: "UI")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.ink)
            Text("Lightwell did not find caches, build files or other known clutter in this scan. The map still shows every byte.", tableName: "UI")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.secondaryInk)
        }
        .cardSurface()
    }

    static func groupTitle(_ risk: Risk) -> String {
        switch risk {
        case .safe: String(localized: "Safe to clear", table: "UI")
        case .review: String(localized: "Worth a look", table: "UI")
        case .dangerous: String(localized: "Keep", table: "UI")
        case .never: String(localized: "Locked by macOS", table: "UI")
        }
    }

    static func groupNote(_ risk: Risk) -> String {
        switch risk {
        case .safe: String(localized: "These rebuild or download again on their own. Removing them costs a little time later, nothing more.", table: "UI")
        case .review: String(localized: "Often removable, but only you know whether you still need them.", table: "UI")
        case .dangerous: String(localized: "Personal data or backups. Usually best managed in the app that owns them. You can still queue one yourself; it stays unticked until you confirm you understand.", table: "UI")
        case .never: String(localized: "System locations. Lightwell never removes anything here.", table: "UI")
        }
    }
}

/// One category: summary row, then items, guidance and actions when expanded.
private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel
    let category: CategoryResult
    let showsRuleID: Bool
    @State private var isExpanded = false
    @State private var copied = false

    /// Safe and review categories meant for the Trash can be queued; dangerous ones can be queued
    /// by the user (they start unticked and need a per-item acknowledgement); never ones can not.
    private var canQueue: Bool {
        switch category.risk {
        case .safe, .review: category.action == .trash
        case .dangerous: true
        case .never: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Fonts.disclosure)
                        .foregroundStyle(Theme.tertiaryInk)
                        .frame(width: 12)
                    Circle()
                        .fill(SpaceCategory(categoryID: category.categoryID).color)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(category.title)
                                .font(Theme.Fonts.bodyStrong)
                                .foregroundStyle(Theme.ink)
                            if showsRuleID {
                                Text(category.ruleID)
                                    .font(Theme.Fonts.path)
                                    .foregroundStyle(Theme.tertiaryInk)
                            }
                        }
                        Text(category.explanation)
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(isExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 12)
                    Text(category.count == 1 ? String(localized: "1 item", table: "UI") : String(localized: "\(category.count) items", table: "UI"))
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.tertiaryInk)
                        .fixedSize()
                    Text(Format.bytes(category.bytes))
                        .font(Theme.Fonts.figureSmall)
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reclaim.category.\(category.ruleID).toggle")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().overlay(Theme.hairline)
                    if let tree = session.tree {
                        ForEach(category.nodes, id: \.self) { node in
                            itemRow(tree: tree, node: node)
                        }
                    }
                    if let command = category.commandHint {
                        guidance(command)
                    }
                    actionRow
                }
                .padding(.top, 10)
                .padding(.leading, 33)
                .transition(.opacity)
            }
        }
        .cardSurface(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reclaim.category.\(category.ruleID)")
    }

    private func itemRow(tree: any TreeReading, node: NodeID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FolderList.symbol(flags: tree.flags(node), name: tree.name(node)))
                .foregroundStyle(Theme.tertiaryInk)
            VStack(alignment: .leading, spacing: 1) {
                Text(tree.name(node))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.ink)
                Text(Format.abbreviatedPath(tree.path(node)))
                    .font(Theme.Fonts.path)
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(Format.bytes(tree.size(node)))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.secondaryInk)
                .monospacedDigit()
            if canQueue {
                Button {
                    model.cleanup.add(category: category, nodes: [node], tree: tree)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryInk)
                .help(String(localized: "Add this item to the cleanup queue", table: "UI"))
                .accessibilityLabel(String(localized: "Add \(tree.name(node)) to Cleanup", table: "UI"))
            }
        }
        .contextMenu {
            if let insights = SessionInsights(session: session) {
                ItemContextMenu(session: session, insights: insights, id: node)
            }
        }
    }

    private func guidance(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remove these with the tool that made them:", tableName: "UI")
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.secondaryInk)
            HStack(spacing: 8) {
                Text(command)
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? String(localized: "Copied", table: "UI") : String(localized: "Copy Command", table: "UI")) {
                    FileActions.copy(command)
                    copied = true
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("reclaim.copyCommand.\(category.ruleID)")
            }
        }
    }

    @ViewBuilder private var actionRow: some View {
        HStack {
            if canQueue, let tree = session.tree {
                if category.risk == .dangerous {
                    Button {
                        model.cleanup.add(category: category, tree: tree)
                    } label: {
                        Label(String(localized: "Add to Cleanup, Unticked", table: "UI"), systemImage: "plus")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("reclaim.add.\(category.ruleID)")
                    Text("Each item needs your explicit OK in Cleanup before it can be removed.", tableName: "UI")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        model.cleanup.add(category: category, tree: tree)
                    } label: {
                        Label(String(localized: "Add to Cleanup", table: "UI"), systemImage: "plus")
                    }
                    .buttonStyle(InkButtonStyle())
                    .accessibilityIdentifier("reclaim.add.\(category.ruleID)")
                }
            } else if category.risk == .never {
                Label(String(localized: "Lightwell never removes these.", table: "UI"), systemImage: "lock")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
        }
    }
}

/// App-level display preferences that are not part of the scan or assistant settings.
enum UIPreferences {
    /// Shows rule ids in Reclaim and the assistant's tool log (design B's "Advanced" details).
    static let showsTechnicalDetailsKey = "showsTechnicalDetails"
}
