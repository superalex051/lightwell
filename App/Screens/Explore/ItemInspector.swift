import AppCore
import CleanupKit
import RulesKit
import ScanKit
import SwiftUI

/// Floating details for the selected item (or the current folder): path, size, how much
/// removing it would free, category, explanation and actions.
struct ItemInspector: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel
    let insights: SessionInsights
    private var tree: any TreeReading { insights.tree }
    @State private var feedback: (node: NodeID, result: AddResult, retryable: Bool)?
    /// Narrow layout (for example with the assistant open): one figure column, icon buttons.
    @State private var isCompact = false

    var body: some View {
        let _ = SessionInsights.observeRevisions(of: session)
        let id = session.selection ?? session.current
        let category = insights.category(covering: id)
        let flags = tree.flags(id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: FolderList.symbol(flags: flags, name: tree.name(id)))
                    .font(Theme.Fonts.icon)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(tree.name(id))
                            .font(Theme.Fonts.bodyStrong)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if let category {
                            RiskBadge(risk: category.risk)
                            Text(category.title)
                                .font(Theme.Fonts.callout)
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    Text(Format.abbreviatedPath(tree.path(id)))
                        .font(Theme.Fonts.path)
                        .foregroundStyle(Theme.tertiaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                if isCompact {
                    compactFigures(id)
                } else {
                    figures(id)
                }
                actions(id)
            }
            if let note = note(for: id, category: category) {
                Text(note)
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(feedbackColor(for: id))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
                    .accessibilityIdentifier("explore.inspector.note")
            }
        }
        .glassBar()
        .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { isCompact = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.inspector")
        .onChange(of: session.selection) { feedback = nil }
    }

    private func figures(_ id: NodeID) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(tree.size(id)))
                    .font(Theme.Fonts.figureSmall)
                    .foregroundStyle(Theme.ink)
                Text("size", tableName: "UI")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.tertiaryInk)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(tree.reclaimableBytes(id, ifAlsoRemoving: [])))
                    .font(Theme.Fonts.figureSmall)
                    .foregroundStyle(Theme.ink)
                Text("frees about", tableName: "UI")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
        .monospacedDigit()
        .fixedSize()
    }

    private func compactFigures(_ id: NodeID) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(Format.bytes(tree.size(id)))
                .font(Theme.Fonts.figureSmall)
                .foregroundStyle(Theme.ink)
            Text("frees about \(Format.bytes(tree.reclaimableBytes(id, ifAlsoRemoving: [])))", tableName: "UI")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.tertiaryInk)
        }
        .monospacedDigit()
        .fixedSize()
    }

    private func actions(_ id: NodeID) -> some View {
        HStack(spacing: 6) {
            Button {
                FileActions.quickLook(tree.path(id))
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(QuietButtonStyle())
            .help(String(localized: "Quick Look", table: "UI"))
            .accessibilityLabel(String(localized: "Quick Look", table: "UI"))
            .accessibilityIdentifier("explore.inspector.quickLook")
            Button {
                FileActions.reveal(tree.path(id))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(QuietButtonStyle())
            .help(String(localized: "Reveal in Finder", table: "UI"))
            .accessibilityLabel(String(localized: "Reveal in Finder", table: "UI"))
            .accessibilityIdentifier("explore.inspector.reveal")
            Button {
                let summary = tree.summary(of: id)
                Task {
                    let result = await model.cleanup.queue(summary, source: .user)
                    feedback = (id, result, model.cleanup.lastAddRetryable && session.staleReason == nil)
                }
            } label: {
                Label(String(localized: "Add to Cleanup", table: "UI"), systemImage: "plus")
                    .labelStyle(isCompact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(InkButtonStyle())
            .help(String(localized: "Add to Cleanup", table: "UI"))
            .disabled(!insights.canQueue(id))
            .accessibilityIdentifier("explore.inspector.addToCleanup")
        }
        .fixedSize()
    }

    private func note(for id: NodeID, category: CategoryResult?) -> String? {
        if let feedback, feedback.node == id { return feedback.result.message(retryable: feedback.retryable) }
        if session.isNotResponding(id) {
            return String(localized: "This folder did not answer during the scan, so its size is unknown. This is not a permissions problem; Rescan may help.", table: "UI")
        }
        if session.isRestricted(id) {
            return String(localized: "Lightwell could not read this folder, so its size is unknown. Full Disk Access in System Settings may help.", table: "UI")
        }
        // Why Add to Cleanup is disabled: the safety policy's reason, then the rule's explanation.
        if let reason = session.addBlockReason(for: id) {
            return [reason.message, category?.explanation].compactMap { $0 }.joined(separator: " ")
        }
        if category?.risk == .dangerous || session.classification(of: id)?.risk == .dangerous {
            return (category?.explanation ?? "") + " " + String(localized: "You can still queue it yourself; it stays unticked until you confirm you understand.", table: "UI")
        }
        return category?.explanation
    }

    private func feedbackColor(for id: NodeID) -> Color {
        guard let feedback, feedback.node == id else { return Theme.secondaryInk }
        return feedback.result.isSuccess ? Theme.risk(.safe) : Theme.risk(.review)
    }
}

/// Type-erased label style, so one button can switch between icon-only and title-and-icon.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
