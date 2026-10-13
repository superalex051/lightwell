import AppCore
import ScanKit
import SwiftUI

/// Menu commands and shortcuts (PLAN 2.10).
/// Space for Quick Look is handled by the list and map themselves (a bare Space menu shortcut
/// would swallow spaces typed in the assistant composer).
struct LightwellCommands: Commands {
    let model: AppModel
    /// Where a refused Add to Cleanup is said (the session window's notice).
    let flow: CleanupFlow
    @FocusedValue(\.textInputActive) private var textInputActive

    private var session: ScanSessionModel? {
        guard let session = model.activeSession, session.state == .finished else { return nil }
        return session
    }

    private var isTyping: Bool { textInputActive == true }

    /// The selected item, or nil when nothing (or the scan root) is selected.
    private var selectedNode: NodeID? {
        guard let session, let tree = session.tree, let id = session.selection, id != tree.root else { return nil }
        return id
    }

    /// The selection exists and is not something Lightwell never removes.
    private var canQueueSelection: Bool {
        guard let session, let id = selectedNode, let insights = SessionInsights(session: session) else { return false }
        return insights.canQueue(id)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Scan Folder…", table: "UI")) { ScanFolderPanel.present(model) }
                .keyboardShortcut("o")
            Button(String(localized: "Show Disks", table: "UI")) { model.showStart() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.activeSession == nil)
        }

        CommandMenu(String(localized: "Go", table: "UI")) {
            Button(String(localized: "Back", table: "UI")) { session?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(session?.canGoBack ?? false))
            Button(String(localized: "Forward", table: "UI")) { session?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(session?.canGoForward ?? false))
            Button(String(localized: "Enclosing Folder", table: "UI")) { session?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(isTyping || session == nil || session?.current == session?.tree?.root)
            Divider()
            Button(String(localized: "Rescan Folder", table: "UI")) {
                if let session { session.rescan(session.current) }
            }
            .keyboardShortcut("r")
            .disabled(session == nil)
            Button(String(localized: "Rescan Everything", table: "UI")) { session?.rescan(nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session == nil)
        }

        CommandMenu(String(localized: "Item", table: "UI")) {
            Button(String(localized: "Quick Look", table: "UI")) { withSelection { FileActions.quickLook($0) } }
                .keyboardShortcut("y")
                .disabled(selectedNode == nil)
            Button(String(localized: "Reveal in Finder", table: "UI")) { withSelection { FileActions.reveal($0) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(selectedNode == nil)
            Button(String(localized: "Copy Path", table: "UI")) { withSelection { FileActions.copyPath($0) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(selectedNode == nil)
            Button(String(localized: "Open in Terminal", table: "UI")) {
                guard let session, let tree = session.tree, let id = selectedNode else { return }
                FileActions.openInTerminal(tree.path(id), isDirectory: tree.flags(id).contains(.directory))
            }
            .disabled(selectedNode == nil)
            Divider()
            Button(String(localized: "Add to Cleanup", table: "UI")) {
                guard let session, let tree = session.tree, let id = selectedNode else { return }
                let summary = tree.summary(of: id)
                Task {
                    let result = await model.cleanup.queue(summary, source: .user)
                    if !result.isSuccess {
                        flow.notice = result.message(retryable: model.cleanup.lastAddRetryable && session.staleReason == nil)
                    }
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(isTyping || !canQueueSelection)
        }

        CommandGroup(before: .toolbar) {
            Button(String(localized: "Show Cleanup Queue", table: "UI")) { model.isQueueVisible.toggle() }
                .keyboardShortcut("l")
                .disabled(session == nil)
            Button(String(localized: "Show Assistant", table: "UI")) { model.isAssistantVisible.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
        }
    }

    private func withSelection(_ action: (String) -> Void) {
        guard let session, let tree = session.tree, let id = selectedNode else { return }
        action(tree.path(id))
    }
}
