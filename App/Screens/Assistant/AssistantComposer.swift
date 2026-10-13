import AppCore
import SwiftUI

/// Suggestions, the message field, Send or Stop, and the footer.
struct AssistantComposer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var assistant = model.assistant
        let isBusy = assistant.isBusy
        VStack(alignment: .leading, spacing: 8) {
            if assistant.items.count <= 1, !isBusy {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { assistant.send(suggestion) }
                            .buttonStyle(ChipButtonStyle())
                    }
                }
                .accessibilityIdentifier("assistant.suggestions")
            }
            if !isBusy, assistant.canContinue || assistant.guardReached || assistant.canRetry {
                HStack(spacing: 8) {
                    if assistant.canRetry {
                        Button(String(localized: "Try Again", table: "Assistant"), action: assistant.retry)
                            .buttonStyle(ChipButtonStyle())
                            .accessibilityIdentifier("assistant.retry")
                    }
                    if assistant.canContinue || assistant.guardReached {
                        Button(String(localized: "Continue", table: "Assistant"), action: assistant.continueReply)
                            .buttonStyle(ChipButtonStyle())
                            .accessibilityIdentifier("assistant.continue")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(String(localized: "Ask about your disk…", table: "Assistant"), text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .publishesTextInput()
                    .onSubmit(send)
                    .accessibilityIdentifier("assistant.input")
                if isBusy {
                    Button(action: assistant.stop) {
                        Label(String(localized: "Stop", table: "Assistant"), systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .font(Theme.Fonts.iconLarge)
                    .foregroundStyle(Theme.ink)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!assistant.canStop)
                    .help(assistant.canStop ? String(localized: "Stop the reply", table: "Assistant") : String(localized: "This version of Claude Code can not stop a reply midway.", table: "Assistant"))
                    .accessibilityIdentifier("assistant.stop")
                } else {
                    Button(action: send) {
                        Label(String(localized: "Send", table: "Assistant"), systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .font(Theme.Fonts.iconLarge)
                    .foregroundStyle(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.tertiaryInk : Theme.ink)
                    .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(String(localized: "Send", table: "Assistant"))
                    .accessibilityIdentifier("assistant.send")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isFocused ? Theme.secondaryInk.opacity(0.5) : Theme.hairline))
            AssistantFooter(usage: assistant.usage)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func send() {
        let assistant = model.assistant
        guard !assistant.isBusy else { return }
        assistant.send(assistant.draft)
    }

    static var suggestions: [String] {
        [
            String(localized: "What is using the most space?", table: "Assistant"),
            String(localized: "Which caches are safe to clear?", table: "Assistant"),
            String(localized: "Find old installers I can remove", table: "Assistant"),
        ]
    }
}

/// Safety line and usage (tokens per thread, cost labelled as an estimate).
struct AssistantFooter: View {
    let usage: UsageSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(String(localized: "The assistant can look and suggest. Only you can delete.", table: "Assistant"), systemImage: "checkmark.shield")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.tertiaryInk)
            if let usage, usage.turns > 0 {
                Text(usageLine(usage))
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.tertiaryInk)
                    .monospacedDigit()
                    .help(String(localized: "Subscription usage is not billed per call. The amount shows what the same tokens would cost on the API.", table: "Assistant"))
                    .accessibilityIdentifier("assistant.usage")
            }
        }
        .padding(.horizontal, 4)
    }

    private func usageLine(_ usage: UsageSummary) -> String {
        String(localized: "\(Format.count(usage.inputTokens)) tokens in, \(Format.count(usage.outputTokens)) out, \(usage.turns) turns · about \(Format.dollars(cents: usage.costCents)), estimated", table: "Assistant")
    }
}
