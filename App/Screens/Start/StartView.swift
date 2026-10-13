import AppCore
import ScanKit
import SwiftUI

/// First screen: a plain-language summary (direction C's serif voice), the disks, Scan Folder,
/// drop target, recent folders and the Full Disk Access banner.
struct StartView: View {
    @Environment(AppModel.self) private var model
    @State private var showsOnboarding = false
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if model.fda != .granted {
                    FDABanner { showsOnboarding = true }
                }
                volumes
                folders
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.window)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.lightDeep, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Theme.light.opacity(0.08))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.startScan(.folder(url))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView { showsOnboarding = false }
                .environment(model)
        }
        .navigationTitle(String(localized: "Lightwell", table: "UI"))
        .onAppear {
            // First launch: show the Full Disk Access guide once (PLAN 2.8).
            guard !model.settings.onboardingCompleted, model.fda != .granted, !model.launchOptions.isUITestMode else { return }
            model.settings.onboardingCompleted = true
            showsOnboarding = true
        }
    }

    // MARK: Header (serif summary)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lightwell", tableName: "UI")
                .font(Theme.Fonts.labelStrong)
                .foregroundStyle(Theme.tertiaryInk)
            Text(headline)
                .font(Theme.Fonts.summaryHeadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a disk or a folder. Lightwell maps where the space went and points out what can go without a second thought. It reads names and sizes, never what is inside your files.", tableName: "UI")
                .font(Theme.Fonts.summaryBody)
                .foregroundStyle(Theme.secondaryInk)
                .lineSpacing(3)
                .frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("start.summary")
    }

    private var headline: String {
        guard let main = model.volumes.first(where: { $0.kind == .internalDisk }) ?? model.volumes.first else {
            return String(localized: "Let some light into your disk.", table: "UI")
        }
        let free = min(main.available, main.capacity)
        return String(localized: "\(main.name) has \(Format.bytes(free)) free of \(Format.bytes(main.capacity)).", table: "UI")
    }

    // MARK: Disks

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disks", tableName: "UI")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(model.volumes) { volume in
                    VolumeCard(volume: volume) { model.startScan(.volume(volume)) }
                }
            }
        }
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders", tableName: "UI")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.ink)
            HStack(spacing: 14) {
                Button {
                    ScanFolderPanel.present(model)
                } label: {
                    Label(String(localized: "Scan a Folder…", table: "UI"), systemImage: "folder")
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("start.scanFolder")
                Text("or drop one anywhere in this window", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.tertiaryInk)
            }
            if !model.recentFolders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent", tableName: "UI")
                        .sectionLabelStyle()
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ForEach(model.recentFolders, id: \.self) { url in
                        RecentFolderRow(url: url) { model.startScan(.folder(url)) }
                    }
                }
            }
        }
    }
}

/// A disk with its usage bar and a Scan button.
struct VolumeCard: View {
    let volume: VolumeInfo
    let scan: () -> Void

    private var free: UInt64 { min(volume.available, volume.capacity) }
    private var used: UInt64 { volume.capacity - free }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.symbol(volume))
                    .font(Theme.Fonts.iconLarge)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(Theme.Fonts.bodyStrong)
                        .foregroundStyle(Theme.ink)
                    Text(Self.description(volume))
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer(minLength: 8)
            }
            CapacityBar(segments: [
                CapacitySegment(kind: .used, bytes: used),
                CapacitySegment(kind: .free, bytes: free),
            ], height: 8, spacing: 2)
            HStack {
                Text("\(Format.bytes(used)) used", tableName: "UI")
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Text("\(Format.bytes(free)) free", tableName: "UI")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
            }
            .font(Theme.Fonts.callout)
            .monospacedDigit()
            HStack {
                Button(action: scan) {
                    Label(String(localized: "Scan", table: "UI"), systemImage: "magnifyingglass")
                }
                .buttonStyle(InkButtonStyle())
                Spacer()
            }
        }
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("start.volume.\(volume.name)")
    }

    static func symbol(_ volume: VolumeInfo) -> String {
        switch volume.kind {
        case .internalDisk: "internaldrive"
        case .network: "externaldrive.connected.to.line.below"
        case .diskImage: "opticaldiscdrive"
        case .external, .removable, .unknown: "externaldrive"
        }
    }

    static func description(_ volume: VolumeInfo) -> String {
        var parts: [String] = []
        switch volume.kind {
        case .internalDisk: parts.append(String(localized: "Internal", table: "UI"))
        case .external: parts.append(String(localized: "External", table: "UI"))
        case .removable: parts.append(String(localized: "Removable", table: "UI"))
        case .network: parts.append(String(localized: "Network", table: "UI"))
        case .diskImage: parts.append(String(localized: "Disk image", table: "UI"))
        case .unknown: break
        }
        if volume.isEncrypted { parts.append(String(localized: "encrypted", table: "UI")) }
        if volume.isReadOnly { parts.append(String(localized: "read only", table: "UI")) }
        parts.append(volume.fsType.uppercased())
        parts.append(String(localized: "\(Format.bytes(volume.capacity)) total", table: "UI"))
        return parts.joined(separator: " · ")
    }
}

private struct RecentFolderRow: View {
    let url: URL
    let scan: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: scan) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.tertiaryInk)
                Text(url.lastPathComponent)
                    .foregroundStyle(Theme.ink)
                Text(Format.abbreviatedPath(url.deletingLastPathComponent().path))
                    .font(Theme.Fonts.path)
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.tertiaryInk)
                    .opacity(isHovered ? 1 : 0)
            }
            .font(Theme.Fonts.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovered ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("start.recent.\(url.lastPathComponent)")
    }
}

/// Shown while Full Disk Access is not granted.
struct FDABanner: View {
    let showHow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(Theme.Fonts.iconLarge)
                .foregroundStyle(Theme.lightDeep)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some folders are closed to Lightwell", tableName: "UI")
                    .font(Theme.Fonts.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("Without Full Disk Access, Mail, Messages and a few other folders count as hidden space. Lightwell still only reads names and sizes.", tableName: "UI")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(String(localized: "Show Me How", table: "UI"), action: showHow)
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("start.fdaBanner.showHow")
        }
        .padding(16)
        .background(Theme.light.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous).strokeBorder(Theme.light.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("start.fdaBanner")
    }
}
