import AppCore
import AppKit

/// Folder picker for Scan Folder (Cmd+O).
enum ScanFolderPanel {
    static func present(_ model: AppModel) {
        guard let url = chooseFolder(prompt: String(localized: "Scan", table: "UI")) else { return }
        model.startScan(.folder(url))
    }

    /// Asks for one folder; nil when cancelled.
    static func chooseFolder(prompt: String, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Asks for one executable file (the claude binary); nil when cancelled.
    static func chooseExecutable(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
