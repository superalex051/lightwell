import AppCore
import RulesKit
import ScanKit
import SwiftUI

/// Overview of a finished scan: one figure (free space), a plain-language summary in
/// direction C's serif voice, the capacity bar, and the ladder of space you can get back.
struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel
    let go: (SessionPage) -> Void

    var body: some View {
        if let tree = session.tree, let insights = SessionInsights(session: session) {
            // Cached per tree generation and categories revision, not recomputed per render.
            let breakdown = insights.breakdown
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    hero(tree: tree)
                    Text(summaryText(breakdown: breakdown))
                        .font(Theme.Fonts.summaryBody)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("overview.summary")
                    VStack(alignment: .leading, spacing: 10) {
                        let segments = segments(breakdown: breakdown)
                        CapacityBar(segments: segments)
                        CapacityLegend(segments: segments)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("overview.capacity")
                    ladder
                    if model.cleanup.trashedBytes > 0 {
                        trashCard
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Hero

    private func hero(tree: any TreeReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(Theme.Fonts.labelStrong)
                .foregroundStyle(Theme.secondaryInk)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let summary = session.summary {
                    Text(Format.bytes(freeBytes(summary)))
                        .font(Theme.Fonts.hero)
                        .foregroundStyle(Theme.ink)
                    Text("free of \(Format.bytes(summary.capacity))", tableName: "UI")
                        .font(Theme.Fonts.heroCaption)
                        .foregroundStyle(Theme.secondaryInk)
                } else {
                    Text(Format.bytes(tree.size(tree.root)))
                        .font(Theme.Fonts.hero)
                        .foregroundStyle(Theme.ink)
                    Text("in \(Format.count(tree.descendantCount(tree.root))) items", tableName: "UI")
                        .font(Theme.Fonts.heroCaption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview.hero")
    }

    private var caption: String {
        switch session.target {
        case .volume(let volume): String(localized: "\(volume.name) after a full scan", table: "UI")
        case .folder(let url): String(localized: "\(url.lastPathComponent), \(Format.abbreviatedPath(url.path))", table: "UI")
        }
    }

    private func freeBytes(_ summary: SpaceSummary) -> UInt64 {
        summary.free + (model.settings.purgeableCountedAsFree ? summary.purgeable : 0)
    }

    // MARK: Summary sentence

    private func summaryText(breakdown: [SpaceCategory: UInt64]) -> AttributedString {
        let top = breakdown.filter { $0.key != .other && $0.value > 0 }.sorted { $0.value > $1.value }.prefix(3)
        let parts = top.map { "**\($0.key.title.lowercased())** (\(Format.bytes($0.value)))" }
        var text: String
        switch parts.count {
        case 3: text = String(localized: "Most of the space goes to \(parts[0]), \(parts[1]) and \(parts[2]).", table: "UI")
        case 2: text = String(localized: "Most of the space goes to \(parts[0]) and \(parts[1]).", table: "UI")
        case 1: text = String(localized: "Most of the space goes to \(parts[0]).", table: "UI")
        default: text = String(localized: "Nothing here stands out by size.", table: "UI")
        }
        if let summary = session.summary, summary.hidden > 0 {
            text += " " + String(localized: "About \(Format.bytes(summary.hidden)) is system data or folders a normal scan cannot read.", table: "UI")
        }
        let safe = session.reclaimableBytes([.safe])
        if safe > 0 {
            text += " " + String(localized: "You can get back **\(Format.bytes(safe))** without touching anything personal.", table: "UI")
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private func segments(breakdown: [SpaceCategory: UInt64]) -> [CapacitySegment] {
        var result = breakdown.filter { $0.value > 0 }
            .sorted { lhs, rhs in lhs.key == .other ? false : rhs.key == .other ? true : lhs.value > rhs.value }
            .map { CapacitySegment(kind: .category($0.key), bytes: $0.value) }
        if let summary = session.summary {
            result.append(CapacitySegment(kind: .hidden, bytes: summary.hidden + summary.otherVolumes))
            result.append(CapacitySegment(kind: .free, bytes: freeBytes(summary)))
        }
        return result
    }

    // MARK: Ladder

    private var ladder: some View {
        let safe = session.reclaimableBytes([.safe])
        let review = session.reclaimableBytes([.review])
        let keep = session.reclaimableBytes([.dangerous, .never])
        let free = session.summary.map(freeBytes)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Room you can get back", tableName: "UI")
                    .font(Theme.Fonts.section)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if free != nil {
                    Text("Free space after each step, once the Trash is emptied", tableName: "UI")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.tertiaryInk)
                }
            }
            .padding(.bottom, 8)
            LadderRow(
                step: 1, risk: .safe,
                title: String(localized: "Safe to clear", table: "UI"),
                detail: String(localized: "Caches and build files that rebuild themselves. Add them in one go; they go to the Trash.", table: "UI"),
                bytes: safe,
                after: free.map { String(localized: "then \(Format.bytes($0 + safe)) free", table: "UI") },
                axID: "overview.ladder.safe"
            ) { go(.reclaim) }
            Divider().overlay(Theme.hairline)
            LadderRow(
                step: 2, risk: .review,
                title: String(localized: "Worth a look", table: "UI"),
                detail: String(localized: "Installers, project dependencies and simulators. You decide item by item.", table: "UI"),
                bytes: review,
                after: free.map { String(localized: "then \(Format.bytes($0 + safe + review)) free", table: "UI") },
                axID: "overview.ladder.review"
            ) { go(.reclaim) }
            Divider().overlay(Theme.hairline)
            LadderRow(
                step: 3, risk: .dangerous,
                title: String(localized: "Keep", table: "UI"),
                detail: String(localized: "Backups and personal libraries. Lightwell leaves them alone unless you queue one yourself and confirm you understand.", table: "UI"),
                bytes: keep,
                after: String(localized: "your call", table: "UI"),
                axID: "overview.ladder.keep"
            ) { go(.reclaim) }
            HStack {
                Button {
                    _ = model.cleanup.addSafeItems(from: session)
                    go(.cleanup)
                } label: {
                    Label(String(localized: "Add Safe Items to Cleanup", table: "UI"), systemImage: "checkmark.shield")
                }
                .buttonStyle(InkButtonStyle())
                .disabled(session.safeCategories.isEmpty)
                .accessibilityIdentifier("overview.addSafe")
                Button(String(localized: "Explore the Map", table: "UI")) { go(.explore) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("overview.explore")
            }
            .padding(.top, 16)
        }
    }

    /// Bytes earlier cleanups moved to the Trash: still on disk until the Trash is emptied.
    private var trashCard: some View {
        let bytes = model.cleanup.trashedBytes
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "trash")
                .font(Theme.Fonts.iconLarge)
                .foregroundStyle(Theme.secondaryInk)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Format.bytes(bytes)) is in the Trash", tableName: "UI")
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("Earlier cleanups moved it there. It frees \(Format.bytes(bytes)) when the Trash is emptied; until then you can put anything back.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(String(localized: "Review in Cleanup", table: "UI")) { go(.cleanup) }
                .buttonStyle(QuietButtonStyle())
                .fixedSize()
                .accessibilityIdentifier("overview.trash.review")
        }
        .cardSurface(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.trash")
    }
}

private struct LadderRow: View {
    let step: Int
    let risk: Risk
    let title: String
    let detail: String
    let bytes: UInt64
    let after: String?
    let axID: String
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                Text(Format.count(step))
                    .font(Theme.Fonts.labelStrong)
                    .foregroundStyle(Theme.inkButtonLabel)
                    .frame(width: 22, height: 22)
                    .background(Theme.risk(risk), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Theme.Fonts.bodyStrong)
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Text(Format.bytes(bytes))
                    .font(Theme.Fonts.figure)
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .fixedSize()
                if let after {
                    Text(after)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120, alignment: .trailing)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.tertiaryInk)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(isHovered ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(axID)
    }
}
