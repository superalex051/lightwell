import AppCore
import CleanupKit
import RulesKit
import SwiftUI

/// Confirmation before anything moves: counts per risk, the items, the total and the mode.
/// `items` is exactly the set that will run.
struct ConfirmDeletionSheet: View {
    let mode: DeletionChoice
    let items: [QueueItem]
    let riskOf: (QueueItem) -> Risk
    let confirm: () -> Void
    let cancel: () -> Void

    private var total: UInt64 { items.reduce(0) { $0 + $1.freesAbout } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            riskCounts
            if mode == .permanent {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                    Text("These items skip the Trash. Once the countdown ends they are gone for good.", tableName: "UI")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if riskOf(item) == .dangerous {
                                Text("you confirmed", tableName: "UI")
                                    .font(Theme.Fonts.label)
                                    .foregroundStyle(Theme.risk(.dangerous))
                            }
                            Spacer()
                            Text(Format.bytes(item.freesAbout))
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.secondaryInk)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .frame(height: min(CGFloat(items.count) * 33, 200))
            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Cancel", table: "UI"), action: cancel)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("queue.confirm.cancel")
                Button(action: confirm) {
                    Label(confirmTitle, systemImage: mode == .trash ? "trash" : "xmark.bin")
                }
                .buttonStyle(InkButtonStyle(isDestructive: mode == .permanent))
                .keyboardShortcut(mode == .trash ? .defaultAction : nil)
                .accessibilityIdentifier(mode == .trash ? "queue.confirm.trash" : "queue.confirm.permanent")
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.window)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.confirm")
    }

    /// "Safe 1 · Review 2 · Keep 1", one badge per risk present.
    private var riskCounts: some View {
        HStack(spacing: 10) {
            ForEach(Risk.allCases, id: \.self) { risk in
                let count = items.filter { riskOf($0) == risk }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        RiskBadge(risk: risk)
                        Text(Format.count(count))
                            .font(Theme.Fonts.bodyStrong)
                            .foregroundStyle(Theme.ink)
                            .monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.confirm.counts")
    }

    private var title: String {
        switch mode {
        case .trash: String(localized: "Move \(Format.bytes(total)) to the Trash?", table: "UI")
        case .permanent: String(localized: "Delete \(Format.bytes(total)) permanently?", table: "UI")
        }
    }

    private var message: String {
        switch mode {
        case .trash:
            String(localized: "\(items.count) items. They wait in the Trash, so you can put any of them back. The space comes back when you empty the Trash.", table: "UI")
        case .permanent:
            String(localized: "\(items.count) items, freed right away. You get a few seconds to change your mind after you confirm.", table: "UI")
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .trash: String(localized: "Move to Trash", table: "UI")
        case .permanent: String(localized: "Delete Permanently", table: "UI")
        }
    }
}

/// "Deleting in N s" with a ring and Stop.
struct CountdownView: View {
    let remaining: Int
    let total: Int
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Theme.well, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(total, 1)))
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: remaining)
                Text(Format.count(remaining))
                    .font(Theme.Fonts.bodyStrong)
                    .monospacedDigit()
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Deleting permanently in \(remaining) s", tableName: "UI")
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("The queue is locked until then. Press Stop to keep everything where it is.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            Button(String(localized: "Stop", table: "UI"), action: stop)
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("queue.countdown.stop")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.countdown")
    }
}

/// What happened in the last run. Moving to the Trash frees nothing until the Trash is emptied,
/// so a Trash run reports the bytes as waiting in the Trash and offers to empty those items.
struct CleanupReportCard: View {
    let report: DeletionReport
    /// Bytes this run moved to the Trash that are still there.
    let trashedBytes: UInt64
    let dismiss: () -> Void
    let emptyTrash: () -> Void
    @State private var confirmsEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(report.failed.isEmpty ? Theme.risk(.safe) : Theme.risk(.review))
                Text(headline)
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(String(localized: "Done", table: "UI"), action: dismiss)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("queue.report.dismiss")
            }
            if report.mode == .trash, !report.succeeded.isEmpty {
                Text("Changed your mind? Open the Trash in the Dock and choose Put Back. To get the space now, delete these items from the Trash.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if trashedBytes > 0 {
                    Button(String(localized: "Free \(Format.bytes(trashedBytes)) Now…", table: "UI")) { confirmsEmpty = true }
                        .buttonStyle(QuietButtonStyle(tint: Theme.danger))
                        .accessibilityIdentifier("queue.report.emptyTrash")
                }
            }
            ForEach(report.failed, id: \.itemID) { failure in
                VStack(alignment: .leading, spacing: 1) {
                    Text((failure.path as NSString).lastPathComponent)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.ink)
                    Text(failure.block?.message ?? failure.detail ?? String(localized: "It could not be removed.", table: "UI"))
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .cardSurface(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.report")
        .confirmationDialog(
            String(localized: "Delete the items this cleanup moved to the Trash for good?", table: "UI"),
            isPresented: $confirmsEmpty
        ) {
            Button(String(localized: "Delete Permanently", table: "UI"), role: .destructive, action: emptyTrash)
        } message: {
            Text("This frees the space now and cannot be undone. Other items in your Trash stay.", tableName: "UI")
        }
    }

    private var headline: String {
        let bytes = Format.bytes(report.bytesFreed)
        let done = report.succeeded.count
        let left = report.failed.count
        switch (report.mode, left == 0) {
        case (.trash, true):
            return String(localized: "Moved \(done) items to the Trash. They free \(bytes) once the Trash is emptied.", table: "UI")
        case (.trash, false):
            return String(localized: "Moved \(done) items to the Trash (\(bytes), freed once the Trash is emptied). \(left) left in place.", table: "UI")
        case (.permanent, true):
            return String(localized: "Deleted \(done) items. \(bytes) is free now.", table: "UI")
        case (.permanent, false):
            return String(localized: "Deleted \(done) items, \(bytes) free now. \(left) left in place.", table: "UI")
        }
    }
}

/// Items this app moved to the Trash recently. They still take space until they are deleted
/// from the Trash, which this section offers.
struct RecentlyTrashedSection: View {
    @Environment(AppModel.self) private var model
    let records: [TrashedRecord]
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In the Trash, still using \(Format.bytes(records.reduce(0) { $0 + $1.bytes }))", tableName: "UI")
                        .font(Theme.Fonts.section)
                        .foregroundStyle(Theme.ink)
                    Text("You can still put these back. The space comes back once they leave the Trash.", tableName: "UI")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Button(String(localized: "Delete These Permanently…", table: "UI")) { confirmsDelete = true }
                    .buttonStyle(QuietButtonStyle(tint: Theme.danger))
                    .fixedSize()
                    .accessibilityIdentifier("queue.recentlyTrashed.deleteAll")
            }
            .padding(.bottom, 8)
            Divider().overlay(Theme.hairline)
            ForEach(records) { record in
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.tertiaryInk)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((record.originalPath as NSString).lastPathComponent)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.ink)
                        Text("From \(Format.abbreviatedPath((record.originalPath as NSString).deletingLastPathComponent)), \(Format.date(record.date))", tableName: "UI")
                            .font(Theme.Fonts.path)
                            .foregroundStyle(Theme.tertiaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(Format.bytes(record.bytes))
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.secondaryInk)
                        .monospacedDigit()
                }
                .padding(.vertical, 8)
                .contextMenu {
                    Button(String(localized: "Reveal in Finder", table: "UI")) { FileActions.reveal(record.trashedURL.path) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("queue.recentlyTrashed.row.\((record.originalPath as NSString).lastPathComponent)")
                Divider().overlay(Theme.hairline)
            }
        }
        .padding(.top, 8)
        .confirmationDialog(
            String(localized: "Delete \(records.count) items from the Trash for good?", table: "UI"),
            isPresented: $confirmsDelete
        ) {
            Button(String(localized: "Delete Permanently", table: "UI"), role: .destructive) {
                model.cleanup.deleteRecentlyTrashedPermanently()
            }
        } message: {
            Text("This frees the space now and cannot be undone.", tableName: "UI")
        }
    }
}
