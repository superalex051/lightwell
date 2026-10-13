import AppCore
import CleanupKit
import RulesKit
import SwiftUI

/// The conversation: user bubbles, streamed replies (markdown), tool activity chips and
/// proposal cards. Stays pinned to the bottom while a reply streams.
struct AssistantTranscript: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let assistant = model.assistant
        let blocks = TranscriptBlock.group(assistant.items)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if blocks.isEmpty {
                    EmptyConversation()
                }
                ForEach(blocks) { block in
                    switch block.content {
                    case .user(let text):
                        UserBubble(text: text)
                    case .assistant(let text, let isStreaming):
                        StreamingMarkdown(text: text, isStreaming: isStreaming)
                            .accessibilityIdentifier("assistant.message")
                    case .tools(let activities):
                        ToolChips(activities: activities)
                    case .proposal(let batch, let index):
                        ProposalCard(batch: batch, index: index)
                    case .notice(let text):
                        Label(text, systemImage: "info.circle")
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.secondaryInk)
                    case .error(let text):
                        VStack(alignment: .leading, spacing: 4) {
                            Label(text, systemImage: "exclamationmark.triangle")
                                .font(Theme.Fonts.callout)
                                .foregroundStyle(Theme.danger)
                                .accessibilityIdentifier("assistant.error")
                            // PLAN 3.9: the CLI's recent output, for the newest error only.
                            if block.id == blocks.last(where: { $0.isError })?.id, let details = assistant.errorDetails, !details.isEmpty {
                                ErrorDetails(text: details)
                            }
                        }
                    }
                }
                if let refusal = assistant.refusal {
                    RefusalCard(refusal: refusal)
                }
            }
            .scrollTargetLayout()
            .padding(16)
        }
        .scrollPosition(id: $bottomID, anchor: .bottom)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onAppear { bottomID = blocks.last?.id }
        .onChange(of: assistant.items.count) { bottomID = blocks.last?.id }
        .accessibilityIdentifier("assistant.transcript")
    }

    /// Last block, kept in view when the conversation opens and when new items arrive.
    @State private var bottomID: UUID?
}

/// "Details" disclosure with the CLI's recent output (stderr tail, nonce redacted by AIBridge).
private struct ErrorDetails: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(text)
                    .font(Theme.Fonts.path)
                    .foregroundStyle(Theme.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } label: {
            Text("Details", tableName: "Assistant")
                .font(Theme.Fonts.callout)
        }
        .accessibilityIdentifier("assistant.error.details")
    }
}

/// PLAN 3.2b: the session was stopped because Claude Code would bill an API key.
private struct RefusalCard: View {
    @Environment(\.openSettings) private var openSettings
    let refusal: AssistantRefusal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(refusal.title)
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key.slash")
                    .foregroundStyle(Theme.danger)
            }
            Text(refusal.reason)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(refusal.advice)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(String(localized: "Open Terminal", table: "Assistant")) {
                    FileActions.openInTerminal(NSHomeDirectory(), isDirectory: true)
                }
                .buttonStyle(QuietButtonStyle())
                Button(String(localized: "Open Settings", table: "Assistant")) { openSettings() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .cardSurface(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.refusal")
    }
}

/// Transcript items folded for display: consecutive tool calls become one row of chips.
struct TranscriptBlock: Identifiable {
    var isError: Bool {
        if case .error = content { true } else { false }
    }

    enum Content {
        case user(String)
        case assistant(String, isStreaming: Bool)
        case tools([ToolActivity])
        case proposal(ProposalBatch, index: Int)
        case notice(String)
        case error(String)
    }

    let id: UUID
    var content: Content

    static func group(_ items: [ChatItem]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var proposals = 0
        for item in items {
            switch item.kind {
            case .user(let text): blocks.append(TranscriptBlock(id: item.id, content: .user(text)))
            case .assistant(let text, let isStreaming): blocks.append(TranscriptBlock(id: item.id, content: .assistant(text, isStreaming: isStreaming)))
            case .tool(let activity):
                if case .tools(var activities) = blocks.last?.content {
                    activities.append(activity)
                    blocks[blocks.count - 1].content = .tools(activities)
                } else {
                    blocks.append(TranscriptBlock(id: item.id, content: .tools([activity])))
                }
            case .proposal(let batch):
                blocks.append(TranscriptBlock(id: item.id, content: .proposal(batch, index: proposals)))
                proposals += 1
            case .notice(let text): blocks.append(TranscriptBlock(id: item.id, content: .notice(text)))
            case .error(let text): blocks.append(TranscriptBlock(id: item.id, content: .error(text)))
            }
        }
        return blocks
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.userMessage")
    }
}

/// First screen of a new conversation, in direction C's serif voice.
private struct EmptyConversation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask me about this disk.", tableName: "Assistant")
                .font(Theme.Fonts.summaryHeadline)
                .foregroundStyle(Theme.ink)
            Text("I can see names, sizes and categories from the scan, and I can put suggestions in your cleanup queue for you to review. I never delete anything.", tableName: "Assistant")
                .font(Theme.Fonts.summaryBody)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.empty")
    }
}

/// "Looked at ~/Downloads" style chips for tool calls.
struct ToolChips: View {
    let activities: [ToolActivity]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(activities) { activity in
                HStack(spacing: 5) {
                    Group {
                        switch activity.state {
                        case .running: ProgressView().controlSize(.mini)
                        case .succeeded: Image(systemName: "eye")
                        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.risk(.review))
                        }
                    }
                    .frame(width: 12, height: 12)
                    Text(ToolDescriptions.label(for: activity))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.secondaryInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.well, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .frame(maxWidth: 300, alignment: .leading)
                .help(activity.detail)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("assistant.tool.\(activity.id)")
            }
        }
    }
}

/// Plain-language names for the MCP tools (PLAN 3.7).
enum ToolDescriptions {
    static func label(for activity: ToolActivity) -> String {
        let target = pathArgument(activity.detail)
        switch activity.name {
        case "get_disk_overview": return String(localized: "Read the disk overview", table: "Assistant")
        case "get_category_summary": return String(localized: "Summed up the categories", table: "Assistant")
        case "get_largest_items":
            return target.map { String(localized: "Listed the largest items in \($0)", table: "Assistant") }
                ?? String(localized: "Listed the largest items", table: "Assistant")
        case "list_children":
            return target.map { String(localized: "Looked inside \($0)", table: "Assistant") }
                ?? String(localized: "Looked inside a folder", table: "Assistant")
        case "inspect_path":
            return target.map { String(localized: "Checked \($0)", table: "Assistant") }
                ?? String(localized: "Checked an item", table: "Assistant")
        case "search_items": return String(localized: "Searched the scan", table: "Assistant")
        case "get_cleanup_queue": return String(localized: "Read the cleanup queue", table: "Assistant")
        case "propose_deletion": return String(localized: "Suggested items for cleanup", table: "Assistant")
        default: return activity.name
        }
    }

    /// Pulls `path: <value>` out of the activity's argument summary.
    static func pathArgument(_ detail: String) -> String? {
        guard let range = detail.range(of: "path: ") else { return nil }
        let rest = detail[range.upperBound...]
        let value = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? String(rest)
        return value.isEmpty ? nil : value
    }
}

/// "Queue It Myself": queues a rejected dangerous suggestion as the user's own item, unticked.
private struct QueueItMyselfButton: View {
    @Environment(AppModel.self) private var model
    let rejected: RejectedProposal
    @State private var result: AddResult?

    var body: some View {
        HStack(spacing: 8) {
            if model.isQueued(rejected) {
                Label(String(localized: "In your cleanup queue, unticked. Tick it there after confirming you understand.", table: "Assistant"), systemImage: "checkmark")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                Button(String(localized: "Queue It Myself", table: "Assistant")) {
                    result = model.queueItMyself(rejected)
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("assistant.queueMyself.\((rejected.path as NSString).lastPathComponent)")
                if let result, !result.isSuccess {
                    Text(result.message)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        }
    }
}

/// Result of one propose_deletion call: what landed in the queue (unticked) and what
/// Lightwell refused.
private struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    let batch: ProposalBatch
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(batch.summary)
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(Format.bytes(batch.totalBytes))
                    .font(Theme.Fonts.figureSmall)
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
            }
            if !batch.queued.isEmpty {
                Text("Added to your cleanup queue, unticked. Nothing is removed until you confirm.", tableName: "Assistant")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(batch.queued) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        RiskBadge(risk: item.risk)
                        Text(item.path)
                            .font(Theme.Fonts.path)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(Format.bytes(item.bytes))
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.secondaryInk)
                            .monospacedDigit()
                    }
                    Text(item.reason)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(batch.rejected) { rejected in
                VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock")
                        .foregroundStyle(Theme.risk(.never))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lightwell refused \(rejected.path). Nothing was queued or deleted.", tableName: "Assistant")
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(rejected.message)
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("assistant.proposal.\(index).rejected")
                    // Items only the user may queue: offer it, unticked, with the acknowledgement to follow.
                    if rejected.userMayQueue {
                        QueueItMyselfButton(rejected: rejected)
                    }
                }
            }
            if !batch.queued.isEmpty {
                Button {
                    model.isQueueVisible = true
                } label: {
                    Label(String(localized: "Review in Cleanup", table: "Assistant"), systemImage: "tray.full")
                }
                .buttonStyle(InkButtonStyle())
                .accessibilityIdentifier("assistant.proposal.\(index).review")
            }
        }
        .cardSurface(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.proposal.\(index)")
    }
}
