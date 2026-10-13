import AppCore
import SwiftUI

/// Everything the panel shows before a conversation is possible (PLAN 3.9 failure modes).
struct AssistantStatusCard: View {
    @Environment(AppModel.self) private var model
    let availability: AssistantAvailability
    let showConsent: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch availability {
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Claude Code on this Mac…", tableName: "Assistant")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.secondaryInk)
                }
            case .needsConsent:
                title(String(localized: "Ask about your disk in plain words", table: "Assistant"), symbol: "bubble.left")
                paragraph(String(localized: "The assistant runs on Claude Code with your own Claude login. It can look at the scan and suggest items for your cleanup queue. It never deletes anything.", table: "Assistant"))
                Button(String(localized: "Review and Turn On…", table: "Assistant"), action: showConsent)
                    .buttonStyle(InkButtonStyle())
                    .accessibilityIdentifier("assistant.consent.open")
            case .notInstalled:
                title(String(localized: "Claude Code is not installed", table: "Assistant"), symbol: "shippingbox")
                paragraph(String(localized: "The assistant talks to the claude command line tool, signed in with your Claude account. Install it in Terminal, then come back.", table: "Assistant"))
                CommandBox(command: "curl -fsSL https://claude.ai/install.sh | bash")
                HStack(spacing: 8) {
                    Button(String(localized: "Choose claude Binary…", table: "Assistant")) { chooseBinary() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("assistant.chooseBinary")
                    Button(String(localized: "Check Again", table: "Assistant")) { model.assistant.recheck() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("assistant.retry")
                }
            case .notSignedIn:
                title(String(localized: "Sign in to Claude first", table: "Assistant"), symbol: "person.badge.key")
                paragraph(String(localized: "Open Terminal, run claude and follow the sign-in steps. Lightwell uses that same login and never asks for a key.", table: "Assistant"))
                CommandBox(command: "claude")
                HStack(spacing: 8) {
                    Button(String(localized: "Open Terminal", table: "Assistant")) {
                        FileActions.openInTerminal(NSHomeDirectory(), isDirectory: true)
                    }
                    .buttonStyle(InkButtonStyle())
                    .accessibilityIdentifier("assistant.openTerminal")
                    Button(String(localized: "Check Again", table: "Assistant")) { model.assistant.recheck() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("assistant.retry")
                }
            case .disabled:
                title(String(localized: "The assistant is off", table: "Assistant"), symbol: "moon.zzz")
                paragraph(String(localized: "Turn it on to ask questions about this scan. You can switch it off again in Settings at any time.", table: "Assistant"))
                Button(String(localized: "Turn On", table: "Assistant")) { model.assistant.enable() }
                    .buttonStyle(InkButtonStyle())
                    .accessibilityIdentifier("assistant.enable")
            case .failed(let detail):
                title(String(localized: "The assistant could not start", table: "Assistant"), symbol: "exclamationmark.triangle")
                paragraph(String(localized: "Something went wrong between Lightwell and Claude Code. Trying again usually helps; the details below can help with a bug report.", table: "Assistant"))
                DisclosureGroup(isExpanded: $showsDetails) {
                    Text(detail)
                        .font(Theme.Fonts.path)
                        .foregroundStyle(Theme.secondaryInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text("Details", tableName: "Assistant")
                        .font(Theme.Fonts.callout)
                }
                .accessibilityIdentifier("assistant.failure.details")
                Button(String(localized: "Try Again", table: "Assistant")) { model.assistant.recheck() }
                    .buttonStyle(InkButtonStyle())
                    .accessibilityIdentifier("assistant.retry")
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.setup")
    }

    private func title(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.secondaryInk)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseBinary() {
        guard let url = ScanFolderPanel.chooseExecutable(
            prompt: String(localized: "Use This", table: "Assistant"),
            message: String(localized: "Choose the claude program. It usually lives in ~/.local/bin.", table: "Assistant")
        ) else { return }
        model.settings.claudePathOverride = url.path
        model.assistant.recheck()
    }
}

/// A shell command with a Copy button.
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(Theme.Fonts.code)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? String(localized: "Copied", table: "Assistant") : String(localized: "Copy", table: "Assistant")) {
                FileActions.copy(command)
                copied = true
            }
            .buttonStyle(.borderless)
            .font(Theme.Fonts.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Privacy consent before first use (PLAN 3.11).
struct AssistantConsentSheet: View {
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Turn on the assistant?", tableName: "Assistant")
                .font(Theme.Fonts.summaryHeadline)
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 12) {
                point("arrow.up.doc", String(localized: "File and folder names, paths and sizes from your scan are sent to Anthropic through your Claude account, so Claude can answer.", table: "Assistant"))
                point("eye.slash", String(localized: "What is inside your files is never read or sent.", table: "Assistant"))
                point("checkmark.shield", String(localized: "The assistant can only suggest items for the cleanup queue. Nothing is removed until you confirm it yourself.", table: "Assistant"))
                point("switch.2", String(localized: "You can turn the assistant off in Settings whenever you like.", table: "Assistant"))
            }
            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Not Now", table: "Assistant"), action: decline)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("assistant.consent.decline")
                // Deliberately not the default button: Return must never accept sharing data.
                Button(String(localized: "Turn On", table: "Assistant"), action: accept)
                    .buttonStyle(InkButtonStyle())
                    .accessibilityIdentifier("assistant.consent.accept")
            }
        }
        .padding(28)
        .frame(width: 480)
        .background(Theme.window)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.consent")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 20)
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
