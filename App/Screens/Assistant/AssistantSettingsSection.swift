import AppCore
import SwiftUI

/// Settings > Assistant (owned by the assistant workstream, embedded by SettingsView).
struct AssistantSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsClear = false

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(String(localized: "Turn on the assistant", table: "Assistant"), isOn: $model.settings.assistantEnabled)
                .accessibilityIdentifier("settings.assistant.enabled")
        } footer: {
            Text("Uses the claude command line tool with your own Claude login. Names, paths and sizes from the scan are shared; file contents never are.", tableName: "Assistant")
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.secondaryInk)
        }

        Section(String(localized: "Claude Code", table: "Assistant")) {
            LabeledContent(String(localized: "Program", table: "Assistant")) {
                HStack(spacing: 8) {
                    Text(model.settings.claudePathOverride.map(Format.abbreviatedPath) ?? String(localized: "Found automatically", table: "Assistant"))
                        .font(model.settings.claudePathOverride == nil ? Theme.Fonts.body : Theme.Fonts.path)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(String(localized: "Choose…", table: "Assistant")) { chooseBinary() }
                        .accessibilityIdentifier("settings.assistant.chooseBinary")
                    if model.settings.claudePathOverride != nil {
                        Button(String(localized: "Use Automatic", table: "Assistant")) { model.settings.claudePathOverride = nil }
                    }
                }
            }
            LabeledContent(String(localized: "Version", table: "Assistant")) {
                Text(versionText)
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityIdentifier("settings.assistant.version")
                    // Looks for the CLI only now, and only after the consent (PLAN 3.11).
                    .onAppear { model.assistant.checkIfNeeded() }
            }
            if let source = model.assistant.keySource {
                LabeledContent(String(localized: "Billing", table: "Assistant")) {
                    Text(source == "none" || source == "/login managed key"
                        ? String(localized: "Your Claude login", table: "Assistant")
                        : String(localized: "An API key (\(source))", table: "Assistant"))
                        .foregroundStyle(Theme.secondaryInk)
                        .accessibilityIdentifier("settings.assistant.keySource")
                }
            }
            Toggle(String(localized: "Block API keys", table: "Assistant"), isOn: $model.settings.blockAPIKeys)
                .help(String(localized: "Stops a conversation when Claude Code would bill an API key instead of your Claude login.", table: "Assistant"))
                .accessibilityIdentifier("settings.assistant.blockAPIKeys")
        }

        Section(String(localized: "Limits", table: "Assistant")) {
            Picker(String(localized: "Model", table: "Assistant"), selection: $model.settings.assistantModel) {
                Text("Default (Sonnet)", tableName: "Assistant").tag(String?.none)
                Text("Opus", tableName: "Assistant").tag(String?.some("opus"))
                Text("Haiku", tableName: "Assistant").tag(String?.some("haiku"))
            }
            .accessibilityIdentifier("settings.assistant.model")
            Stepper(value: $model.settings.assistantMaxTurns, in: 1...50) {
                LabeledContent(String(localized: "Steps per question", table: "Assistant")) {
                    Text(Format.count(model.settings.assistantMaxTurns))
                        .monospacedDigit()
                }
            }
            .accessibilityIdentifier("settings.assistant.maxTurns")
            Stepper(value: $model.settings.assistantBudgetCents, in: 0...2_000, step: 25) {
                LabeledContent(String(localized: "Spending guard per conversation", table: "Assistant")) {
                    Text(model.settings.assistantBudgetCents == 0 ? String(localized: "None", table: "Assistant") : Format.dollars(cents: model.settings.assistantBudgetCents))
                        .monospacedDigit()
                }
            }
            .help(String(localized: "Stops a conversation once its estimated cost reaches this amount.", table: "Assistant"))
            .accessibilityIdentifier("settings.assistant.budget")
        }

        Section {
            Button(String(localized: "Delete All Conversations…", table: "Assistant"), role: .destructive) { confirmsClear = true }
                .disabled(model.assistant.threads.isEmpty)
                .accessibilityIdentifier("settings.assistant.clearThreads")
        }
        .confirmationDialog(String(localized: "Delete all assistant conversations?", table: "Assistant"), isPresented: $confirmsClear) {
            Button(String(localized: "Delete All", table: "Assistant"), role: .destructive) {
                model.assistant.clearThreads()
            }
        } message: {
            Text("Your scans and cleanup queue stay as they are.", tableName: "Assistant")
        }
    }

    private var versionText: String {
        switch model.assistant.availability {
        case .ready(let version?): return version
        case .ready(nil): return String(localized: "Ready", table: "Assistant")
        case .checking: return String(localized: "Checking…", table: "Assistant")
        case .notInstalled: return String(localized: "Not installed", table: "Assistant")
        case .notSignedIn: return String(localized: "Not signed in", table: "Assistant")
        case .needsConsent: return String(localized: "Waiting for your go-ahead", table: "Assistant")
        case .disabled: return String(localized: "Off", table: "Assistant")
        case .failed: return String(localized: "Could not start", table: "Assistant")
        }
    }

    private func chooseBinary() {
        guard let url = ScanFolderPanel.chooseExecutable(
            prompt: String(localized: "Use This", table: "Assistant"),
            message: String(localized: "Choose the claude program. It usually lives in ~/.local/bin.", table: "Assistant")
        ) else { return }
        model.settings.claudePathOverride = url.path
    }
}
