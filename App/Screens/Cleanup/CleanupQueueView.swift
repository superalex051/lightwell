import AppCore
import CleanupKit
import RulesKit
import SwiftUI

/// Cleanup queue: the staging area. Rows with checkboxes, risk and source, totals, Move to Trash,
/// Delete Permanently (confirm, then a countdown with Stop), the result report and recently trashed.
///
/// Every number and list here comes from one set, `CleanupFlow.removalSet`: the rows show the
/// store's selection, the totals count that set, the confirm sheet lists it and the run removes it.
struct CleanupQueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let session: ScanSessionModel
    @State private var confirming: DeletionChoice?
    /// Narrow layout (for example with the assistant open): the Trash note is dropped.
    @State private var isCompact = false

    var body: some View {
        let cleanup = model.cleanup
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let report = cleanup.lastReport {
                    // "Free X Now" covers exactly what this run moved to the Trash.
                    let fromRun = cleanup.trashedRecords(from: report)
                    CleanupReportCard(report: report, trashedBytes: fromRun.reduce(0) { $0 + $1.bytes }) {
                        cleanup.dismissReport()
                    } emptyTrash: {
                        cleanup.deleteRecentlyTrashed(Set(fromRun.map(\.id)))
                    }
                }
                if cleanup.queue.isEmpty {
                    emptyState
                } else {
                    ForEach(Risk.allCases, id: \.self) { risk in
                        let rows = cleanup.queue.filter { $0.risk == risk }
                        if !rows.isEmpty {
                            group(risk: risk, rows: rows)
                        }
                    }
                }
                if !cleanup.recentlyTrashed.isEmpty {
                    RecentlyTrashedSection(records: cleanup.recentlyTrashed)
                }
            }
            .padding(.horizontal, Theme.Metrics.pagePadding + 8)
            .padding(.top, 24)
            // Room for the floating action bar, so it never covers the end of the Trash list.
            .padding(.bottom, 88)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            totalsBar
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 4)
        }
        .sheet(item: $confirming) { mode in
            let items = flow.removalSet(cleanup)
            ConfirmDeletionSheet(mode: mode, items: items, riskOf: { $0.risk }) {
                confirming = nil
                switch mode {
                case .trash: flow.moveToTrash(items, cleanup: cleanup)
                case .permanent: flow.startPermanentDeletion(items, cleanup: cleanup)
                }
            } cancel: {
                confirming = nil
            }
        }
        .onDisappear {
            flow.cancelCountdown(notice: String(localized: "Permanent deletion stopped because you left Cleanup. Nothing was deleted.", table: "UI"))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleanup", tableName: "UI")
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text("Nothing leaves your disk until you press the button. Items you add start ticked; suggestions wait for you.", tableName: "UI")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button {
                model.isAssistantVisible = true
            } label: {
                Label(String(localized: "Ask the Assistant", table: "UI"), systemImage: "bubble.left")
            }
            .buttonStyle(QuietButtonStyle())
            .fixedSize()
            .accessibilityIdentifier("queue.askAssistant")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The queue is empty", tableName: "UI")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.ink)
            Text("Add items from Explore or Reclaim, or let the assistant suggest some. You review everything here before anything moves.", tableName: "UI")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardSurface()
        .accessibilityIdentifier("queue.empty")
    }

    private func group(risk: Risk, rows: [QueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(ReclaimView.groupTitle(risk))
                    .font(Theme.Fonts.section)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(Format.bytes(rows.reduce(0) { $0 + $1.bytes }))
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
            }
            .padding(.bottom, 8)
            Divider().overlay(Theme.hairline)
            ForEach(rows) { item in
                QueueRow(item: item, risk: risk, session: session)
                Divider().overlay(Theme.hairline)
            }
        }
    }

    // MARK: Totals bar

    private var totalsBar: some View {
        let cleanup = model.cleanup
        let removal = flow.removalSet(cleanup)
        let bytes = removal.reduce(UInt64(0)) { $0 + $1.freesAbout }
        return HStack(alignment: .center, spacing: 16) {
            if let remaining = flow.countdownRemaining {
                CountdownView(remaining: remaining, total: CleanupFlow.countdownSeconds) {
                    flow.cancelCountdown(notice: String(localized: "Stopped. Nothing was deleted.", table: "UI"))
                    cleanup.stopCountdown()
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionLine(count: removal.count, bytes: bytes))
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                    if removal.isEmpty {
                        Text("Nothing ticked yet", tableName: "UI")
                            .font(Theme.Fonts.figureSmall)
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Format.bytes(bytes))
                                .font(Theme.Fonts.figure)
                                .foregroundStyle(Theme.ink)
                                .monospacedDigit()
                            Text("selected", tableName: "UI")
                                .font(Theme.Fonts.callout)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("queue.totals")
                Spacer(minLength: 12)
                if cleanup.isRunning {
                    ProgressView().controlSize(.small)
                    RunProgressText(cleanup: cleanup)
                } else if !isCompact {
                    Text("The Trash keeps everything until you empty it; the space comes back then.", tableName: "UI")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button(String(localized: "Delete Permanently…", table: "UI")) { confirming = .permanent }
                    .buttonStyle(QuietButtonStyle(tint: Theme.danger))
                    .disabled(removal.isEmpty || cleanup.isRunning)
                    .fixedSize()
                    .accessibilityIdentifier("queue.deletePermanently")
                Button {
                    confirming = .trash
                } label: {
                    Label(String(localized: "Move to Trash", table: "UI"), systemImage: "trash")
                }
                .buttonStyle(InkButtonStyle())
                .disabled(removal.isEmpty || cleanup.isRunning)
                .fixedSize()
                .accessibilityIdentifier("queue.trash")
            }
        }
        .glassBar()
        .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { isCompact = $0 }
    }

    /// "2 of 3 selected", plus what free space becomes once these are gone from the Trash too.
    private func selectionLine(count: Int, bytes: UInt64) -> String {
        let selected = String(localized: "\(count) of \(model.cleanup.queue.count) selected", table: "UI")
        guard let summary = session.summary, bytes > 0 else { return selected }
        return selected + " · " + String(localized: "free after the Trash is emptied: \(Format.bytes(summary.free + bytes))", table: "UI")
    }
}

/// "Working..." with how far the run got. Its own view, so the per-item progress redraws only
/// this text and not the whole queue page.
private struct RunProgressText: View {
    let cleanup: CleanupModel

    var body: some View {
        Group {
            if let progress = cleanup.runProgress, progress.total > 1 {
                Text("Working… \(progress.done) of \(progress.total)", tableName: "UI")
            } else {
                Text("Working…", tableName: "UI")
            }
        }
        .font(Theme.Fonts.callout)
        .foregroundStyle(Theme.secondaryInk)
        .monospacedDigit()
        .accessibilityIdentifier("queue.working")
    }
}

/// Which confirmation sheet is open.
enum DeletionChoice: String, Identifiable {
    case trash, permanent
    var id: String { rawValue }
}

/// One queued item. The checkbox always shows the store's selection; rows that may not be
/// removed are disabled (the store refuses to tick them).
private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let item: QueueItem
    let risk: Risk
    let session: ScanSessionModel
    @State private var isHovered = false

    var body: some View {
        let locked = flow.isCountingDown || model.cleanup.isRunning
        let canTick = flow.mayRemove(item) && !locked
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(get: { item.isSelected }, set: { model.cleanup.setSelected(item.id, $0) })) {
                Text(item.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!canTick)
            .accessibilityIdentifier("queue.row.\(item.name).checkbox")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(Theme.Fonts.bodyStrong)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    RiskBadge(risk: risk)
                    SourceBadge(source: item.source, categoryTitle: categoryTitle)
                }
                if let explanation = session.explanation(of: item) {
                    Text(explanation)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Format.abbreviatedPath(item.path))
                    .font(Theme.Fonts.path)
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                riskControl(locked: locked)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bytes(item.bytes))
                    .font(Theme.Fonts.figureSmall)
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                if item.freesAbout != item.bytes {
                    Text("frees about \(Format.bytes(item.freesAbout))", tableName: "UI")
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .fixedSize()
            Button {
                model.cleanup.remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryInk)
            .opacity(isHovered ? 1 : 0.35)
            .disabled(locked)
            .help(String(localized: "Remove from Cleanup", table: "UI"))
            .accessibilityLabel(String(localized: "Remove \(item.name) from Cleanup", table: "UI"))
            .accessibilityIdentifier("queue.row.\(item.name).remove")
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(String(localized: "Reveal in Finder", table: "UI")) { FileActions.reveal(item.path) }
            Button(String(localized: "Copy Path", table: "UI")) { FileActions.copyPath(item.path) }
            Divider()
            Button(String(localized: "Remove from Cleanup", table: "UI")) { model.cleanup.remove(item.id) }
                .disabled(locked)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.row.\(item.name)")
    }

    /// Dangerous rows need an explicit, per-item "I understand" before they can be ticked (for an
    /// assistant suggestion that also makes it the user's own item); never-items can not be ticked.
    @ViewBuilder private func riskControl(locked: Bool) -> some View {
        switch risk {
        case .dangerous:
            Toggle(isOn: Binding(get: { flow.acknowledged.contains(item.id) }, set: { flow.setAcknowledged(item, $0, cleanup: model.cleanup) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("I understand this may be the only copy, and I want to be able to remove it.", tableName: "UI")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    // Photos libraries, device backups or browser profiles that go with this item.
                    let nested = model.cleanup.nestedDangerousPaths(of: item).filter { $0 != item.path }
                    if !nested.isEmpty {
                        Text("It includes:", tableName: "UI")
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.secondaryInk)
                        ForEach(nested, id: \.self) { path in
                            Text(Format.abbreviatedPath(path))
                                .font(Theme.Fonts.path)
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(locked)
            .padding(8)
            .background(Theme.risk(.review).opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
            .accessibilityIdentifier("queue.row.\(item.name).acknowledge")
        case .never:
            note(String(localized: "Lightwell never removes this. Take it out of the queue.", table: "UI"), symbol: "lock")
        case .safe, .review:
            EmptyView()
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Theme.Fonts.callout)
            .foregroundStyle(Theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var categoryTitle: String? {
        session.sourceTitle(of: item)
    }
}
