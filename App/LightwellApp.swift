import AppCore
import SwiftUI

@main
struct LightwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(String(localized: "Lightwell", table: "UI"), id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.cleanupFlow)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            LightwellCommands(model: delegate.model, flow: delegate.cleanupFlow)
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}
