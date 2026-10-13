import AppCore
import SwiftUI

/// Settings window: General, Scanning, Assistant, Permissions, About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab(String(localized: "General", table: "UI"), systemImage: "gearshape") {
                GeneralSettings()
                    .accessibilityIdentifier("settings.general")
            }
            Tab(String(localized: "Scanning", table: "UI"), systemImage: "magnifyingglass") {
                ScanningSettings()
                    .accessibilityIdentifier("settings.scanning")
            }
            Tab(String(localized: "Assistant", table: "UI"), systemImage: "bubble.left") {
                Form { AssistantSettingsSection() }
                    .formStyle(.grouped)
                    .accessibilityIdentifier("settings.assistant")
            }
            Tab(String(localized: "Permissions", table: "UI"), systemImage: "lock.shield") {
                PermissionsSettings()
                    .accessibilityIdentifier("settings.permissions")
            }
            Tab(String(localized: "About", table: "UI"), systemImage: "info.circle") {
                AboutSettings()
                    .accessibilityIdentifier("settings.about")
            }
        }
        .frame(width: 580, height: 460)
        .tint(Theme.ink)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UIPreferences.showsTechnicalDetailsKey) private var showsTechnicalDetails = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(String(localized: "Count purgeable space as free", table: "UI"), isOn: $model.settings.purgeableCountedAsFree)
                    .accessibilityIdentifier("settings.general.purgeable")
            } footer: {
                Text("macOS can free purgeable space on its own, for example old iCloud downloads. Counting it as free matches what Finder shows.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Section {
                Toggle(String(localized: "Tell me when a scan finishes in the background", table: "UI"), isOn: $model.settings.notifyWhenScanFinishes)
                    .accessibilityIdentifier("settings.general.notify")
                Toggle(String(localized: "Show technical details (rule ids)", table: "UI"), isOn: $showsTechnicalDetails)
                    .accessibilityIdentifier("settings.general.technical")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScanningSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selectedExclusion: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                List(selection: $selectedExclusion) {
                    ForEach(model.settings.excludedPaths, id: \.self) { path in
                        Text(Format.abbreviatedPath(path))
                            .font(Theme.Fonts.path)
                            .tag(path)
                    }
                }
                .frame(minHeight: 90)
                .overlay {
                    if model.settings.excludedPaths.isEmpty {
                        Text("No folders are skipped.", tableName: "UI")
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.tertiaryInk)
                    }
                }
                .accessibilityIdentifier("settings.scanning.exclusions")
                HStack {
                    Button(String(localized: "Add Folder…", table: "UI")) { addExclusion() }
                        .accessibilityIdentifier("settings.scanning.addExclusion")
                    Button(String(localized: "Remove", table: "UI")) {
                        model.settings.excludedPaths.removeAll { $0 == selectedExclusion }
                        selectedExclusion = nil
                    }
                    .disabled(selectedExclusion == nil)
                }
            } header: {
                Text("Skip these folders", tableName: "UI")
            } footer: {
                Text("Skipped folders count as hidden space.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Section {
                Toggle(String(localized: "Count cloned files once", table: "UI"), isOn: $model.settings.countClonesOnce)
                    .accessibilityIdentifier("settings.scanning.clones")
                Picker(String(localized: "Parallel readers", table: "UI"), selection: $model.settings.scanWorkers) {
                    Text("Automatic", tableName: "UI").tag(Int?.none)
                    ForEach([2, 4, 8, 16], id: \.self) { count in
                        Text(Format.count(count)).tag(Int?.some(count))
                    }
                }
                .accessibilityIdentifier("settings.scanning.workers")
            } footer: {
                Text("APFS clones share their storage, so counting them once shows what deleting them would really free.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .formStyle(.grouped)
    }

    private func addExclusion() {
        guard let url = ScanFolderPanel.chooseFolder(prompt: String(localized: "Skip", table: "UI")) else { return }
        if !model.settings.excludedPaths.contains(url.path) {
            model.settings.excludedPaths.append(url.path)
        }
    }
}

private struct PermissionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showsGuide = false

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Full Disk Access", table: "UI")) {
                    HStack(spacing: 6) {
                        Image(systemName: model.fda == .granted ? "checkmark.circle.fill" : "lock")
                            .foregroundStyle(model.fda == .granted ? Theme.risk(.safe) : Theme.secondaryInk)
                        Text(statusText)
                    }
                    .accessibilityIdentifier("settings.permissions.status")
                }
                HStack {
                    Button(String(localized: "Show Me How…", table: "UI")) { showsGuide = true }
                        .accessibilityIdentifier("settings.permissions.guide")
                    Button(String(localized: "Open System Settings", table: "UI")) { SystemSettingsLink.openFullDiskAccess() }
                }
            } footer: {
                Text("Lightwell works without it, but folders macOS keeps closed show up as hidden space.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsGuide) {
            OnboardingView { showsGuide = false }
                .environment(model)
        }
    }

    private var statusText: String {
        switch model.fda {
        case .granted: String(localized: "Allowed", table: "UI")
        case .denied: String(localized: "Not allowed", table: "UI")
        case .unknown: String(localized: "Unknown", table: "UI")
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Lightwell", tableName: "UI")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.ink)
            Text("Version \(version)", tableName: "UI")
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.secondaryInk)
                .accessibilityIdentifier("settings.about.version")
            Text("Lets light into a full disk: see what takes the space, clear what is safe.", tableName: "UI")
                .font(Theme.Fonts.summaryBody)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Free and open source under the MIT License.", tableName: "UI")
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
