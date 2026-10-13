import AppCore
import SwiftUI

/// Advanced view (design B's tool trace): every tool call in this conversation with its
/// arguments, outcome and duration.
struct ToolLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let activities = model.assistant.items.compactMap { item -> ToolActivity? in
            if case .tool(let activity) = item.kind { return activity }
            return nil
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tool calls", tableName: "Assistant")
                    .sectionLabelStyle()
                Spacer()
                Text(activities.count == 1 ? String(localized: "1 call", table: "Assistant") : String(localized: "\(activities.count) calls", table: "Assistant"))
                    .sectionLabelStyle()
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider().overlay(Theme.hairline)
            if activities.isEmpty {
                Text("No tool calls yet in this conversation.", tableName: "Assistant")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(16)
                Spacer()
            } else {
                List(activities) { activity in
                    ToolLogRow(activity: activity)
                        .listRowSeparatorTint(Theme.hairline)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.risk(.safe))
                    .frame(width: 6, height: 6)
                Text(cliLine)
                    .font(Theme.Fonts.path)
                    .foregroundStyle(Theme.tertiaryInk)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("assistant.toolLog.cli")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.toolLog")
    }

    private var cliLine: String {
        if case .ready(let version?) = model.assistant.availability {
            return String(localized: "claude \(version) · read-only disk tools", table: "Assistant")
        }
        return String(localized: "claude · read-only disk tools", table: "Assistant")
    }
}

private struct ToolLogRow: View {
    let activity: ToolActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(activity.name)
                    .font(Theme.Fonts.code)
                    .foregroundStyle(activity.state == .failed ? Theme.risk(.review) : Theme.ink)
                Spacer()
                if let duration = activity.durationMs {
                    Text("\(duration) ms", tableName: "Assistant")
                        .font(Theme.Fonts.path)
                        .foregroundStyle(Theme.tertiaryInk)
                        .monospacedDigit()
                } else if activity.state == .running {
                    ProgressView().controlSize(.mini)
                }
            }
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(Theme.Fonts.path)
                    .foregroundStyle(Theme.secondaryInk)
                    .textSelection(.enabled)
            }
            Text(stateLine)
                .font(Theme.Fonts.path)
                .foregroundStyle(Theme.tertiaryInk)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.toolLog.\(activity.id)")
    }

    private var stateLine: String {
        switch activity.state {
        case .running: String(localized: "running", table: "Assistant")
        case .succeeded: String(localized: "done", table: "Assistant")
        case .failed: String(localized: "failed", table: "Assistant")
        }
    }
}
