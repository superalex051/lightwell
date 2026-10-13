import AppCore
import AppKit
import SwiftUI

/// Full Disk Access guide (PLAN 2.8): why, steps, open System Settings, drag the app icon,
/// relaunch, skip. Re-checks access whenever the window becomes key again.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                DraggableAppIcon()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let Lightwell see the whole disk", tableName: "UI")
                        .font(Theme.Fonts.screenTitle)
                        .foregroundStyle(Theme.ink)
                    Text("macOS keeps some folders, like Mail and Messages, closed until you allow Full Disk Access. Lightwell needs it only to count names and sizes. It never opens or reads your files.", tableName: "UI")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                step(1, String(localized: "Open Privacy and Security in System Settings.", table: "UI"))
                step(2, String(localized: "Find Full Disk Access and switch on Lightwell. If it is not listed, drag the icon above into the list.", table: "UI"))
                step(3, String(localized: "Relaunch Lightwell so the change takes effect.", table: "UI"))
            }
            .cardSurface()

            status

            HStack(spacing: 10) {
                Button(String(localized: "Not Now", table: "UI"), action: dismiss)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("onboarding.skip")
                Spacer()
                Button(String(localized: "Relaunch", table: "UI")) { Relauncher.relaunch() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("onboarding.relaunch")
                Button {
                    SystemSettingsLink.openFullDiskAccess()
                } label: {
                    Label(String(localized: "Open System Settings", table: "UI"), systemImage: "gearshape")
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.openSettings")
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Theme.window)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recheck()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Format.count(number))
                .font(Theme.Fonts.labelStrong)
                .foregroundStyle(Theme.inkButtonLabel)
                .frame(width: 20, height: 20)
                .background(Theme.inkButton, in: Circle())
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch model.fda {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.risk(.safe))
                Text("Full Disk Access is on. Relaunch to scan everything.", tableName: "UI")
            case .denied:
                Image(systemName: "lock").foregroundStyle(Theme.secondaryInk)
                Text("Full Disk Access is off.", tableName: "UI")
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.secondaryInk)
                Text("Lightwell could not tell whether Full Disk Access is on.", tableName: "UI")
            }
        }
        .font(Theme.Fonts.callout)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.status")
    }

    private func recheck() {
        model.refreshFDA()
    }
}

/// The app icon as a drag source, for dropping into the Full Disk Access list.
private struct DraggableAppIcon: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 72, height: 72)
            .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
            .help(String(localized: "Drag this icon into the Full Disk Access list", table: "UI"))
            .accessibilityLabel(String(localized: "Lightwell app icon, drag into the Full Disk Access list", table: "UI"))
            .accessibilityIdentifier("onboarding.dragIcon")
    }
}

/// Deep links into System Settings > Privacy and Security > Full Disk Access.
enum SystemSettingsLink {
    static let primary = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    static let fallback = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Tries the current pane id first, then the legacy one.
    @MainActor
    static func openFullDiskAccess() {
        if let url = URL(string: primary), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: fallback) { NSWorkspace.shared.open(url) }
    }
}

/// Relaunches the app after it has fully quit, so a new TCC grant applies.
enum Relauncher {
    @MainActor
    static func relaunch() {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let bundle = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Positional arguments keep the path out of the script text.
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"", "lightwell-relaunch", pid, bundle]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
        // Still running: the quit was cancelled (for example at the quit guard), so the
        // waiting shell must not relaunch the app later.
        process.terminate()
    }
}
