import AppKit
import Quartz

/// Reveal in Finder, Copy Path, Open in Terminal and Quick Look (PLAN G7).
/// None of these read file contents or change anything on disk.
@MainActor
enum FileActions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func copy(_ text: String) {
        copyPath(text)
    }

    /// Opens Terminal at the folder (or the enclosing folder of a file). No Apple Events needed.
    static func openInTerminal(_ path: String, isDirectory: Bool) {
        let folder = isDirectory ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path).deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func quickLook(_ path: String) {
        QuickLookController.shared.show(URL(fileURLWithPath: path))
    }
}

/// Feeds one URL to the shared Quick Look panel.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var url: URL?

    /// Space toggles: a second press on the same item closes the panel.
    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, self.url == url {
            panel.orderOut(nil)
            return
        }
        self.url = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
