import AIBridge
import AppCore
import SwiftUI

/// The assistant inspector (design A's glass panel): header with conversations and the
/// tool log switch, then either a setup card or the conversation and composer.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UIPreferences.showsToolLogKey) private var showsToolLog = false
    @State private var showsConsent = false

    var body: some View {
        let assistant = model.assistant
        VStack(spacing: 0) {
            AssistantHeader(showsToolLog: $showsToolLog)
            Divider().overlay(Theme.hairline)
            switch assistant.availability {
            case .ready:
                if showsToolLog {
                    ToolLogView()
                } else {
                    AssistantTranscript()
                }
                AssistantComposer()
            default:
                ScrollView {
                    AssistantStatusCard(availability: assistant.availability) { showsConsent = true }
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
                Spacer(minLength: 0)
                AssistantFooter(usage: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        // The CLI is looked for when the panel first opens after the consent, not at launch.
        .onAppear { assistant.checkIfNeeded() }
        .sheet(isPresented: $showsConsent) {
            AssistantConsentSheet {
                showsConsent = false
                assistant.acceptConsent()
            } decline: {
                showsConsent = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.panel")
    }
}

/// Title, login note, conversation menu, tool log switch, close.
private struct AssistantHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var showsToolLog: Bool

    var body: some View {
        let assistant = model.assistant
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant", tableName: "Assistant")
                    .font(Theme.Fonts.section)
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if case .ready = assistant.availability {
                Menu {
                    Button(String(localized: "New Conversation", table: "Assistant")) { assistant.newThread() }
                        .accessibilityIdentifier("assistant.newThread")
                    if !assistant.threads.isEmpty {
                        Divider()
                        ForEach(assistant.threads) { thread in
                            Button {
                                assistant.select(thread.id)
                            } label: {
                                if thread.id == assistant.active {
                                    Label(Self.title(of: thread), systemImage: "checkmark")
                                } else {
                                    Text(Self.title(of: thread))
                                }
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "Conversations", table: "Assistant"), systemImage: "bubble.left.and.bubble.right")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help(String(localized: "Conversations", table: "Assistant"))
                .accessibilityIdentifier("assistant.threads")

                Toggle(isOn: $showsToolLog.animation(Theme.Motion.standard)) {
                    Label(String(localized: "Tool Log", table: "Assistant"), systemImage: "list.bullet.rectangle")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(String(localized: "Show every tool call the assistant made (advanced)", table: "Assistant"))
                .accessibilityIdentifier("assistant.toolLogToggle")
            }
            Button {
                model.isAssistantVisible = false
            } label: {
                Label(String(localized: "Close", table: "Assistant"), systemImage: "xmark")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help(String(localized: "Close the assistant", table: "Assistant"))
            .accessibilityIdentifier("assistant.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let assistant = model.assistant
        let thread = assistant.threads.first { $0.id == assistant.active }
        if case .ready = assistant.availability, let thread {
            return Self.title(of: thread)
        }
        return String(localized: "Uses your Claude login. Read only.", table: "Assistant")
    }

    static func title(of thread: ThreadRecord) -> String {
        thread.title.isEmpty ? String(localized: "New conversation", table: "Assistant") : thread.title
    }
}

extension UIPreferences {
    /// Whether the assistant panel shows the tool log instead of the conversation.
    static let showsToolLogKey = "assistantShowsToolLog"
}
