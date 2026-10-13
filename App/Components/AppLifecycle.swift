import AppCore
import AppKit
import ScanKit
import SwiftUI
import UserNotifications

/// Owns the app model and handles app-level events: opening folders from the Dock or Finder,
/// Full Disk Access re-checks, quit guards and a clean shutdown of scans and the assistant.
///
/// The real stores run in every normal launch and in fixture UI tests (PLAN 5.3:
/// `-LightwellUITestMode YES -LightwellFixtureRoot <dir>`). UI test mode without a fixture root is
/// the screenshot walkthrough on preview data, so it never touches the disk.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let cleanupFlow: CleanupFlow

    override init() {
        let options = AppLaunchOptions.current()
        let model = options.isUITestMode && options.fixtureRoot == nil
            ? AppModel.preview(launchOptions: options)
            : AppModel.live(launchOptions: options)
        self.model = model
        self.cleanupFlow = CleanupFlow(cleanup: model.cleanup)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UITestScenes.apply(to: model)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The user may have granted Full Disk Access or emptied the Trash meanwhile.
        model.refreshFDA()
        model.cleanup.pruneRecentlyTrashed()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders and disks dropped on the Dock icon or opened with Lightwell from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let volume = model.volumes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            model.startScan(.volume(volume))
        } else {
            model.startScan(.folder(url))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let blockers = model.quitBlockers
        let deleting = model.cleanup.isRunning
        let countingDown = model.cleanup.countdownRemaining != nil
        // The queue is not saved between launches (PLAN 2.7 step 1), so a non-empty queue is worth a prompt.
        let queued = model.cleanup.queue.count
        let queuePrompt = blockers.queueHasItems && model.launchOptions.promptsBeforeDroppingQueue
        guard deleting || countingDown || blockers.isScanning || queuePrompt else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let stay: String
        if deleting {
            alert.messageText = String(localized: "A cleanup is still running", table: "UI")
            alert.informativeText = String(localized: "Quitting now stops it partway. Items already handled stay where they went; the rest stay in place.", table: "UI")
            stay = String(localized: "Keep Running", table: "UI")
        } else if countingDown {
            alert.messageText = String(localized: "A permanent deletion is about to start", table: "UI")
            alert.informativeText = String(localized: "Nothing has been deleted yet. Quitting cancels it and leaves every item where it is.", table: "UI")
            stay = String(localized: "Stay", table: "UI")
        } else if blockers.isScanning {
            alert.messageText = String(localized: "A scan is still running", table: "UI")
            alert.informativeText = String(localized: "Quitting now discards the scan. You can start it again later.", table: "UI")
            stay = String(localized: "Keep Running", table: "UI")
        } else {
            alert.messageText = String(localized: "Your cleanup queue still has \(queued) items", table: "UI")
            alert.informativeText = String(localized: "Nothing in it has been removed. If you quit, the queue is cleared and you can build it again after the next scan.", table: "UI")
            stay = String(localized: "Keep Queue", table: "UI")
        }
        alert.addButton(withTitle: stay)
        alert.addButton(withTitle: String(localized: "Quit Anyway", table: "UI"))
        // The alert promises that nothing has been deleted yet, so the countdown holds while it is
        // open: Stay resumes it, Quit Anyway drops it before the app goes.
        if countingDown { model.cleanup.pauseCountdown() }
        let quit = alert.runModal() == .alertSecondButtonReturn
        if countingDown {
            if quit { model.cleanup.stopCountdown() } else { model.cleanup.resumeCountdown() }
        }
        return quit ? .terminateNow : .terminateCancel
    }
}

/// Scan progress on the Dock icon.
@MainActor
enum DockProgress {
    private static var indicator: NSProgressIndicator?

    static func show(fraction: Double?) {
        let tile = NSApp.dockTile
        if indicator == nil {
            let size = tile.size
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            let icon = NSImageView(frame: container.bounds)
            icon.image = NSApp.applicationIconImage
            container.addSubview(icon)
            let bar = NSProgressIndicator(frame: NSRect(x: size.width * 0.12, y: size.height * 0.08, width: size.width * 0.76, height: 14))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            container.addSubview(bar)
            tile.contentView = container
            indicator = bar
        }
        if let fraction {
            indicator?.isIndeterminate = false
            indicator?.doubleValue = fraction
        } else {
            indicator?.isIndeterminate = true
        }
        tile.display()
    }

    static func clear() {
        indicator = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

/// "Scan finished" notification, only when Lightwell is in the background.
@MainActor
enum ScanNotifications {
    static func scanFinished(name: String, bytes: UInt64, model: AppModel) {
        guard model.settings.notifyWhenScanFinishes, !model.launchOptions.isUITestMode, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        let title = String(localized: "Scan finished", table: "UI")
        let body = String(localized: "\(name) holds \(Format.bytes(bytes)). Open Lightwell to explore it.", table: "UI")
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
