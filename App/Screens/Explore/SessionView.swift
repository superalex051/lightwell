import AppCore
import ScanKit
import SwiftUI

/// Pages of a finished scan, listed in the sidebar.
enum SessionPage: Hashable, CaseIterable {
    case overview, explore, reclaim, cleanup

    var title: String {
        switch self {
        case .overview: String(localized: "Overview", table: "UI")
        case .explore: String(localized: "Explore", table: "UI")
        case .reclaim: String(localized: "Reclaim", table: "UI")
        case .cleanup: String(localized: "Cleanup", table: "UI")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .explore: "square.grid.2x2"
        case .reclaim: "sparkles.rectangle.stack"
        case .cleanup: "tray.full"
        }
    }

    var axID: String {
        switch self {
        case .overview: "sidebar.overview"
        case .explore: "sidebar.explore"
        case .reclaim: "sidebar.reclaim"
        case .cleanup: "sidebar.cleanup"
        }
    }
}

/// Window for a finished scan: sidebar (pages and locations), page content, toolbar,
/// and the assistant as a trailing inspector (design A).
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let session: ScanSessionModel
    @State private var page: SessionPage = .explore
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var windowWidth: CGFloat = 0
    /// True when the sidebar was hidden automatically for the assistant (not by the user).
    @State private var sidebarAutoHidden = false

    /// Below this width the sidebar steps aside while the assistant is open, so the map,
    /// the list and the conversation all keep a readable width.
    private static let roomForSidebarAndAssistant: CGFloat = 1320

    /// The Cleanup page doubles as the "queue visible" state, so Cmd+L and the toolbar badge
    /// open it from anywhere and leaving it hides the queue again.
    private var pageBinding: Binding<SessionPage> {
        Binding(
            get: { model.isQueueVisible ? .cleanup : page },
            set: { newValue in
                if newValue == .cleanup {
                    model.isQueueVisible = true
                } else {
                    model.isQueueVisible = false
                    page = newValue
                }
            }
        )
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SessionSidebar(session: session, page: pageBinding)
                .navigationSplitViewColumnWidth(min: 210, ideal: Theme.Metrics.sidebarWidth, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
                // PLAN 2.4: the scanned root changed or its disk went away; the data may be out of date.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let reason = session.staleReason {
                        StaleBanner(reason: reason) { session.rescan(nil) }
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }
                }
                // An overlay, not an inset: a transient notice must not change the page layout.
                .overlay(alignment: .top) {
                    if let notice = flow.notice {
                        NoticeBar(text: notice) { flow.notice = nil }
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.standard, value: flow.notice)
                // The notice floats over the page header, so it goes away on its own after a while.
                .task(id: flow.notice) {
                    guard flow.notice != nil else { return }
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    flow.notice = nil
                }
                .toolbar { toolbar }
                .inspector(isPresented: $model.isAssistantVisible) {
                    AssistantPanel()
                        .inspectorColumnWidth(min: 300, ideal: Theme.Metrics.inspectorWidth, max: 480)
                }
        }
        .navigationTitle(pageBinding.wrappedValue.title)
        .navigationSubtitle(session.target.displayName)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onChange(of: model.isAssistantVisible, initial: true) { updateSidebar() }
        .onChange(of: windowWidth) { updateSidebar() }
        .onChange(of: model.cleanup.queue, initial: true) { flow.reconcile(model.cleanup) }
    }

    /// Hides the sidebar while the assistant is open in a narrow window and brings it back when
    /// there is room again (or the assistant closes). A sidebar the user hid stays hidden.
    private func updateSidebar() {
        let crowded = model.isAssistantVisible && windowWidth < Self.roomForSidebarAndAssistant
        withAnimation(Theme.Motion.standard) {
            if crowded, columns != .detailOnly {
                columns = .detailOnly
                sidebarAutoHidden = true
            } else if !crowded, sidebarAutoHidden {
                columns = .all
                sidebarAutoHidden = false
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch pageBinding.wrappedValue {
        case .overview:
            OverviewPage(session: session) { pageBinding.wrappedValue = $0 }
        case .explore:
            ExplorePage(session: session)
        case .reclaim:
            ReclaimView(session: session)
        case .cleanup:
            CleanupQueueView(session: session)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button {
                pageBinding.wrappedValue = .explore
                session.goBack()
            } label: {
                Label(String(localized: "Back", table: "UI"), systemImage: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help(String(localized: "Back", table: "UI"))
            .accessibilityIdentifier("explore.back")
            Button {
                pageBinding.wrappedValue = .explore
                session.goForward()
            } label: {
                Label(String(localized: "Forward", table: "UI"), systemImage: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help(String(localized: "Forward", table: "UI"))
            .accessibilityIdentifier("explore.forward")
        }
        // A waiting full refresh (changes were missed in many places) sits in the toolbar: a banner
        // above the page made the window content taller than the window and shifted it up.
        if session.staleReason == nil, let at = session.fullRefreshPendingAt {
            ToolbarItem(placement: .primaryAction) {
                let time = at.formatted(date: .omitted, time: .shortened)
                Button {
                    session.refreshEverythingNow()
                } label: {
                    Label(String(localized: "Full refresh at \(time)", table: "UI"), systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .help(String(localized: "The disk changed in many places. A full refresh runs at \(time). Click to refresh now.", table: "UI"))
                .accessibilityLabel(String(localized: "Refresh Now", table: "UI"))
                .accessibilityValue(String(localized: "The disk changed in many places. A full refresh runs at \(time).", table: "UI"))
                .accessibilityIdentifier("session.refreshNow")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.rescan(session.current)
            } label: {
                Label(String(localized: "Rescan", table: "UI"), systemImage: "arrow.clockwise")
            }
            .help(String(localized: "Scan this folder again", table: "UI"))
            .accessibilityIdentifier("explore.rescan")

            Button {
                model.isQueueVisible.toggle()
            } label: {
                let removal = flow.removalSet(model.cleanup)
                QueueBadgeLabel(count: removal.count, bytes: removal.reduce(0) { $0 + $1.freesAbout })
            }
            .help(String(localized: "Show the cleanup queue", table: "UI"))
            .accessibilityLabel(String(localized: "Cleanup queue", table: "UI"))
            .accessibilityValue(String(localized: "\(model.cleanup.queue.count) items", table: "UI"))
            .accessibilityIdentifier("explore.queueToggle")

            Toggle(isOn: $model.isAssistantVisible) {
                Label(String(localized: "Assistant", table: "UI"), systemImage: "sidebar.right")
            }
            .help(String(localized: "Show the assistant", table: "UI"))
            .accessibilityIdentifier("explore.assistantToggle")
        }
    }
}

/// The scan no longer matches the disk (root moved, disk ejected, events lost).
private struct StaleBanner: View {
    let reason: StaleReason
    let rescan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(Theme.risk(.review))
            Text(text)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if reason != .unmounted {
                Button(String(localized: "Rescan", table: "UI"), action: rescan)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("session.stale.rescan")
            }
        }
        .glassBar()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.stale")
    }

    private var text: String {
        switch reason {
        case .rootChanged: String(localized: "The scanned folder was moved or renamed, so this scan may be out of date.", table: "UI")
        case .unmounted: String(localized: "The disk of this scan was ejected. What you see is the last scan.", table: "UI")
        case .eventsDropped: String(localized: "Some changes on disk were missed, so this scan may be out of date.", table: "UI")
        }
    }
}

/// One-line message across the top of the session window, with a dismiss button.
private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.secondaryInk)
            Text(text)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "OK", table: "UI"), action: dismiss)
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("session.notice.dismiss")
        }
        .glassBar()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.notice")
    }
}

/// Tray icon with the selected cleanup size, like a running total.
private struct QueueBadgeLabel: View {
    let count: Int
    let bytes: UInt64

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.full")
            if count > 0 {
                Text(Format.bytes(bytes))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Sidebar: the session's pages, other locations, and the free space card.
private struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let session: ScanSessionModel
    @Binding var page: SessionPage

    /// Size of what a cleanup would remove right now (the same set the queue page totals).
    private var cleanupDetail: String? {
        let removal = flow.removalSet(model.cleanup)
        return removal.isEmpty ? nil : Format.bytes(removal.reduce(0) { $0 + $1.freesAbout })
    }

    var body: some View {
        List(selection: Binding<SessionPage?>(get: { page }, set: { if let value = $0 { page = value } })) {
            Section(String(localized: "This Scan", table: "UI")) {
                ForEach(SessionPage.allCases, id: \.self) { item in
                    SidebarPageRow(
                        page: item,
                        detail: item == .cleanup ? cleanupDetail : nil
                    )
                    .tag(item)
                    .accessibilityIdentifier(item.axID)
                }
            }
            Section(String(localized: "Locations", table: "UI")) {
                ForEach(model.volumes) { volume in
                    locationButton(
                        title: volume.name,
                        symbol: VolumeCard.symbol(volume),
                        detail: Format.bytes(min(volume.available, volume.capacity)),
                        target: .volume(volume)
                    )
                }
                ForEach(model.recentFolders, id: \.self) { url in
                    locationButton(title: url.lastPathComponent, symbol: "folder", detail: nil, target: .folder(url))
                }
                Button {
                    ScanFolderPanel.present(model)
                } label: {
                    Label(String(localized: "Scan a Folder…", table: "UI"), systemImage: "plus")
                        .foregroundStyle(Theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.scanFolder")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            FreeSpaceCard(session: session)
                .padding(10)
        }
    }

    private func locationButton(title: String, symbol: String, detail: String?, target: ScanTarget) -> some View {
        let isCurrent = session.target == target
        return Button {
            open(target)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.tertiaryInk)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.location.\(title)")
    }

    /// Reuses a finished scan of the same place, otherwise starts a new one.
    private func open(_ target: ScanTarget) {
        if let existing = model.sessions.first(where: { $0.target == target && $0.state == .finished }) {
            model.activeSessionID = existing.id
        } else {
            model.startScan(target)
        }
    }
}

/// A page in the sidebar, with an optional figure that stays readable when selected.
private struct SidebarPageRow: View {
    let page: SessionPage
    let detail: String?

    var body: some View {
        HStack {
            Label(page.title, systemImage: page.symbol)
            Spacer()
            if let detail {
                Text(detail)
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.rowSecondary)
                    .monospacedDigit()
            }
        }
    }
}

/// Bottom of the sidebar: free space on the scanned disk (or the folder's size).
private struct FreeSpaceCard: View {
    let session: ScanSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = session.summary {
                Text("Free on \(session.target.displayName)", tableName: "UI")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.secondaryInk)
                Text(Format.bytes(summary.free))
                    .font(Theme.Fonts.figure)
                    .foregroundStyle(Theme.ink)
                CapacityBar(segments: [
                    CapacitySegment(kind: .used, bytes: summary.used),
                    CapacitySegment(kind: .free, bytes: summary.free),
                ], height: 5, spacing: 1)
            } else if let tree = session.tree {
                Text("Size of \(session.target.displayName)", tableName: "UI")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.secondaryInk)
                Text(Format.bytes(tree.size(tree.root)))
                    .font(Theme.Fonts.figure)
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.freeSpace")
    }
}
