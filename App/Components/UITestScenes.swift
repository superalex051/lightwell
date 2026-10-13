import AIBridge
import AppCore
import AppKit
import ScanKit

/// Deterministic starting states for UI tests and screenshots. Active only with
/// `-LightwellUITestMode YES`; ignored otherwise.
///
/// `-LightwellUITestScene <name>` picks a state, `-LightwellAppearance dark|light` forces an appearance.
@MainActor
enum UITestScenes {
    static func apply(to model: AppModel, defaults: UserDefaults = .standard) {
        guard model.launchOptions.isUITestMode else { return }
        // Display preferences persist between launches; every UI test starts from the defaults.
        defaults.removeObject(forKey: UIPreferences.showsToolLogKey)
        defaults.removeObject(forKey: UIPreferences.showsTechnicalDetailsKey)
        switch defaults.string(forKey: "LightwellAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let scene = defaults.string(forKey: "LightwellUITestScene"), let volume = model.volumes.first else { return }

        switch scene {
        case "scanning":
            let session = ScanSessionModel(target: .volume(volume))
            session.state = .scanning
            session.progress = ScanProgress(
                fraction: 0.42,
                itemsScanned: 1_284_377,
                bytesScanned: 341_000_000_000,
                currentPath: "/Users/preview/Library/Developer/Xcode/DerivedData/Lightwell-abc123"
            )
            model.sessions.append(session)
            model.activeSessionID = session.id
        case "fdaGranted":
            model.fda = .granted
        default:
            guard scene.hasPrefix("assistant") else { return }
            model.startScan(.volume(volume))
            model.isAssistantVisible = true
            applyAssistant(scene, to: model.assistant)
        }
    }

    private static func applyAssistant(_ scene: String, to assistant: AssistantModel) {
        switch scene {
        case "assistant-checking": assistant.availability = .checking
        case "assistant-consent": assistant.availability = .needsConsent
        case "assistant-notInstalled": assistant.availability = .notInstalled
        case "assistant-notSignedIn": assistant.availability = .notSignedIn
        case "assistant-disabled": assistant.availability = .disabled
        case "assistant-failed": assistant.availability = .failed("The disk tools did not connect (lightwell-mcp exited with status 1).")
        case "assistant-streaming":
            assistant.items.append(ChatItem(kind: .user("And what about the iPhone backup?")))
            assistant.items.append(ChatItem(kind: .tool(ToolActivity(id: "tool-5", name: "inspect_path", detail: "path: ~/Library/Application Support/MobileSync/Backup", state: .running))))
            assistant.items.append(ChatItem(kind: .assistant(text: "That backup is **38 GB**. It may be the only copy of your phone's data, so I will not suggest it; if you decide to remove it, queue it yourself from Explore. If your phone backs up to iCloud", isStreaming: true)))
        case "assistant-empty":
            assistant.newThread()
        default: break
        }
    }
}
