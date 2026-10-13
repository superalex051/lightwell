import AIBridge
import CleanupKit
import Foundation
import IPCProtocol
import Observation
import RulesKit
import ScanKit

/// Root store. Frozen contract (PLAN 4.3).
///
/// Routing: `activeSession == nil` shows Start; otherwise its `state` picks Scanning or Explore.
/// `AppModel.live(launchOptions:)` builds the real stores (scanner, rules, executor, assistant);
/// `AppModel.preview()` builds the fake-data stores for SwiftUI previews.
@Observable
@MainActor
public final class AppModel {
    public var volumes: [VolumeInfo]
    public var sessions: [ScanSessionModel]
    public var activeSessionID: UUID?
    public var recentFolders: [URL]
    public let cleanup: CleanupModel
    public let assistant: AssistantModel
    public var fda: FDAStatus
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            assistant.settingsChanged(from: oldValue, to: settings)
        }
    }
    public var isQueueVisible = false
    public var isAssistantVisible = false
    public let launchOptions: AppLaunchOptions
    /// Home folder the rules and the safety policy see (`<fixture>/home` in UI test mode).
    public let home: String
    /// The MCP tool handler (live mode only).
    public private(set) var toolHandler: ToolHandler?

    @ObservationIgnored private let previewTreeProvider: (@MainActor (ScanTarget) -> (any TreeReading)?)?
    @ObservationIgnored private let previewCategories: [PreviewData.CategoryFixture]
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var isLive = false
    @ObservationIgnored private var rules: [Rule] = []
    @ObservationIgnored private var volumeTask: Task<Void, Never>?

    public init(
        volumes: [VolumeInfo] = [],
        recentFolders: [URL] = [],
        cleanup: CleanupModel = CleanupModel(),
        assistant: AssistantModel = AssistantModel(),
        fda: FDAStatus = .unknown,
        settings: AppSettings = AppSettings(),
        launchOptions: AppLaunchOptions = AppLaunchOptions(),
        previewTreeProvider: (@MainActor (ScanTarget) -> (any TreeReading)?)? = nil,
        previewCategories: [PreviewData.CategoryFixture] = [],
        settingsStore: SettingsStore = .volatile,
        home: String = NSHomeDirectory()
    ) {
        self.volumes = volumes
        self.sessions = []
        self.recentFolders = recentFolders
        self.cleanup = cleanup
        self.assistant = assistant
        self.fda = fda
        self.settings = settings
        self.launchOptions = launchOptions
        self.previewTreeProvider = previewTreeProvider
        self.previewCategories = previewCategories
        self.settingsStore = settingsStore
        self.home = home
    }

    // MARK: Live wiring

    /// The real app: scans with ScanKit, classifies with RulesKit, deletes with CleanupKit, talks to
    /// Claude Code through AIBridge. In UI test mode (PLAN 5.3) Start lists only the fixture root,
    /// deletions use `FixtureTrash` and refuse anything outside the fixture, the rules see
    /// `<fixture>/home`, settings are not saved and the assistant uses the fake CLI.
    public static func live(launchOptions: AppLaunchOptions = .current(), defaults: UserDefaults = .standard, bundle: Bundle = .main, assistantRoot rootOverride: URL? = nil) -> AppModel {
        let fixture = launchOptions.usesFixture ? launchOptions.fixtureRoot.map { URL(fileURLWithPath: ScanSessionModel.canonicalRoot($0)) } : nil
        let home: String
        let store: SettingsStore
        var settings: AppSettings
        let cleanupConfiguration: CleanupConfiguration
        let assistantRoot: URL
        if let fixture {
            home = ScanSessionModel.canonicalRoot(fixture.appendingPathComponent("home"))
            store = .volatile
            settings = AppSettings(onboardingCompleted: true)
            cleanupConfiguration = .fixture(root: fixture, home: home)
            // Inside the fixture (deleted with it in teardown) and excluded from scans.
            assistantRoot = Self.uiTestScratch(for: fixture)
        } else {
            home = NSHomeDirectory()
            store = SettingsStore(defaults: defaults)
            settings = store.load()
            cleanupConfiguration = .production(home: home)
            assistantRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lightwell", isDirectory: true)
        }
        if launchOptions.isUITestMode { settings.onboardingCompleted = true }
        let filesRoot = rootOverride ?? assistantRoot

        let model = AppModel(
            volumes: [],
            recentFolders: fixture.map { [$0] } ?? [],
            cleanup: CleanupModel(configuration: cleanupConfiguration),
            assistant: AssistantModel(),
            fda: launchOptions.isUITestMode ? .granted : FDAProbe.check(),
            settings: settings,
            launchOptions: launchOptions,
            settingsStore: store,
            home: home
        )
        model.isLive = true
        model.rules = .bundled

        let helperURL = bundle.bundleURL.appendingPathComponent("Contents/Helpers/lightwell-mcp")
        let services = AssistantServices(
            directory: filesRoot.appendingPathComponent("assistant", isDirectory: true),
            ipcDirectory: filesRoot.appendingPathComponent("ipc", isDirectory: true),
            helperURL: helperURL,
            peerPolicy: .automatic(helperURL: helperURL),
            // UI test mode never falls back to the real CLI: without a fake it shows the setup card.
            claudeOverride: launchOptions.isUITestMode ? (launchOptions.fakeClaude ?? URL(fileURLWithPath: "/nonexistent/lightwell-fake-claude")) : nil,
            systemPromptTemplate: AssistantServices.bundledSystemPrompt(bundle)
        )
        model.connect(assistantServices: services, snapshots: launchOptions.isUITestMode ? .disabled : SnapshotCounter())
        if fixture == nil { model.watchVolumes() }
        return model
    }

    /// Wires the stores together and to the assistant (also used by tests with their own services).
    public func connect(assistantServices: AssistantServices?, snapshots: SnapshotCounter = SnapshotCounter(), metadata: ItemMetadata = .live) {
        isLive = true
        if rules.isEmpty { rules = .bundled }
        cleanup.scanContext = { [weak self] path in self?.session(containing: path)?.cleanupContext }
        cleanup.scanRoots = { [weak self] in self?.sessions.filter(\.isFinished).map(\.rootPath) ?? [] }
        cleanup.itemsRemoved = { [weak self] items in
            self?.sessions.forEach { $0.applyRemoval(items) }
        }
        cleanup.itemsWillBeRemoved = { [weak self] items in
            let paths = items.map(\.path)
            self?.sessions.forEach { $0.suppressRefresh(for: paths) }
        }
        assistant.settings = { [weak self] in self?.settings ?? AppSettings() }
        assistant.updateSettings = { [weak self] change in
            guard let self else { return }
            var copy = self.settings
            change(&copy)
            self.settings = copy
        }
        assistant.scanInfo = { [weak self] in
            guard let self, let scan = self.toolScanSession?.toolContext else { return nil }
            let age = max(0, Int(Date().timeIntervalSince(scan.finishedAt)))
            return (age, ToolPaths.abbreviate(scan.tree.path(scan.tree.root), home: scan.engine.home))
        }
        let environment = ToolEnvironment(
            context: { [weak self] in self?.toolContext() ?? ToolContext() },
            enqueue: { [weak self] thread, proposals in
                guard let self else { return proposals.map { _ in AddResult.blocked(.notInScan) } }
                return self.enqueue(proposals, thread: thread)
            },
            proposalMade: { [weak self] thread, batch in self?.assistant.receive(batch, thread: thread) },
            metadata: metadata,
            snapshots: snapshots
        )
        let handler = ToolHandler(environment: environment)
        toolHandler = handler
        if let assistantServices {
            assistant.configure(services: assistantServices, handler: handler)
            assistant.prepare()
        }
    }

    public var activeSession: ScanSessionModel? {
        sessions.first { $0.id == activeSessionID }
    }

    /// Creates a session for `target`, makes it active and starts scanning.
    @discardableResult
    public func startScan(_ target: ScanTarget) -> ScanSessionModel {
        let session: ScanSessionModel
        if isLive {
            session = ScanSessionModel(target: target, services: scanServices())
        } else {
            let tree = previewTreeProvider?(target)
            let categories = tree.map { tree in previewCategories.compactMap { $0.resolve(in: tree) } } ?? []
            session = ScanSessionModel(target: target, previewTree: tree, previewCategories: categories)
        }
        attach(session)
        if case .folder(let url) = target, !recentFolders.contains(url) {
            recentFolders.insert(url, at: 0)
        }
        session.startScan()
        return session
    }

    /// Adds an already built session (tests and fixtures that inject a tree) and makes it active.
    public func adopt(_ session: ScanSessionModel) {
        attach(session)
        if session.state == .idle { session.startScan() }
    }

    /// Scan settings for a new live session.
    public func scanServices() -> ScanServices {
        var excluded = settings.excludedPaths
        if launchOptions.usesFixture, let fixture = launchOptions.fixtureRoot {
            excluded.append(Self.uiTestScratch(for: URL(fileURLWithPath: ScanSessionModel.canonicalRoot(fixture))).path)
            // The fixture Trash lives inside the scanned fixture; the real Trash of a home scan is
            // a separate place. Excluded, so a live refresh never adds trashed items back to the
            // scan (and the totals match the E2E oracle, which skips it too).
            excluded.append(URL(fileURLWithPath: ScanSessionModel.canonicalRoot(fixture)).appendingPathComponent(FixtureTrash.folderName).path)
        }
        var services = ScanServices(
            home: home,
            rules: rules.isEmpty ? .bundled : rules,
            workers: settings.scanWorkers,
            countClonesOnce: settings.countClonesOnce,
            excludedPaths: excluded
        )
        services.injectDroppedEvents = launchOptions.isUITestMode && launchOptions.uiTestDroppedEvents
        return services
    }

    /// Returns to the Start screen (sessions stay in memory).
    public func showStart() {
        activeSessionID = nil
    }

    public func closeSession(_ id: UUID) {
        sessions.first { $0.id == id }?.shutdown()
        sessions.removeAll { $0.id == id }
        if activeSessionID == id { activeSessionID = nil }
    }

    /// Re-probes Full Disk Access (window became key, Settings > Permissions).
    public func refreshFDA() {
        guard !launchOptions.isUITestMode else { return }
        fda = FDAProbe.check()
    }

    /// Things that make quitting worth a confirmation (PLAN 2.7 step 6).
    public var quitBlockers: QuitBlockers {
        QuitBlockers(
            queueHasItems: !cleanup.queue.isEmpty,
            isScanning: sessions.contains { $0.state == .scanning },
            isDeleting: cleanup.isRunning || cleanup.countdownRemaining != nil
        )
    }

    /// The app's scratch folder in UI test mode: `<fixture>/.lightwell-app`, inside the fixture
    /// (AGENTS rule 7) and excluded from scans, so the scanned tree never shows it.
    public static func uiTestScratch(for fixture: URL) -> URL {
        fixture.standardizedFileURL.appendingPathComponent(".lightwell-app", isDirectory: true)
    }

    /// App quit: stops scans, refreshers and the assistant.
    public func shutdown() {
        volumeTask?.cancel()
        sessions.forEach { $0.shutdown() }
        defer {
            // UI test mode: remove the app's own scratch folder next to the fixture.
            if launchOptions.usesFixture, let fixture = launchOptions.fixtureRoot {
                let scratch = Self.uiTestScratch(for: URL(fileURLWithPath: ScanSessionModel.canonicalRoot(fixture)))
                if scratch.lastPathComponent == ".lightwell-app" { try? FileManager.default.removeItem(at: scratch) }
            }
        }
        cleanup.stopCountdown()
        cleanup.cancelRun()
        assistant.shutdown()
    }

    // MARK: Private

    private func attach(_ session: ScanSessionModel) {
        session.onRestructure = { [weak self] session in
            guard let tree = session.tree else { return }
            self?.cleanup.remapNodes(in: tree)
        }
        sessions.append(session)
        activeSessionID = session.id
    }

    /// The session whose scan holds `path` (the active one first).
    func session(containing path: String) -> ScanSessionModel? {
        let finished = sessions.filter { $0.isFinished }
        if let active = activeSession, active.isFinished, active.contains(path: path) { return active }
        return finished.last { $0.contains(path: path) }
    }

    /// The session the assistant talks about: the active finished one, else the latest finished one.
    var toolScanSession: ScanSessionModel? {
        if let active = activeSession, active.isFinished { return active }
        return sessions.last { $0.isFinished }
    }

    func toolContext() -> ToolContext {
        ToolContext(
            scan: toolScanSession?.toolContext,
            isScanning: sessions.contains { $0.state == .scanning },
            queue: cleanup.queue,
            fda: fda
        )
    }

    func enqueue(_ proposals: [ToolProposal], thread: UUID) -> [AddResult] {
        proposals.map { proposal in
            guard let session = session(containing: proposal.path), let context = session.cleanupContext, context.tree === proposal.tree else {
                return .blocked(.notInScan)
            }
            // Node ids may have been reassigned since the tool's snapshot (a rescan): queue by path,
            // so the reason always stays with the item it was written for.
            guard let node = context.tree.node(atPath: proposal.path), context.tree.path(node) == proposal.path else {
                return .blocked(.changedSinceScan)
            }
            return cleanup.add(node: node, context: context, source: .assistant(thread: thread, reason: proposal.reason))
        }
    }

    /// "Queue It Myself" on a proposal the assistant may not queue: queues it as the user's own
    /// item, unticked, needing the per-item acknowledgement. The model was told it was rejected.
    @discardableResult
    public func queueItMyself(_ rejected: RejectedProposal) -> AddResult {
        guard rejected.userMayQueue, let path = rejected.fullPath,
              let session = session(containing: path), let context = session.cleanupContext,
              let node = context.tree.node(atPath: path)
        else { return .blocked(.notInScan) }
        return cleanup.add(node: node, context: context, source: .user)
    }

    /// True when `rejected` is already in the cleanup queue (the card's button then reads as done).
    public func isQueued(_ rejected: RejectedProposal) -> Bool {
        guard let path = rejected.fullPath else { return false }
        return cleanup.queue.contains { $0.path == path }
    }

    private func watchVolumes() {
        volumeTask = Task { [weak self] in
            let current = await Task.detached(priority: .userInitiated) { VolumeCatalog.current() }.value
            self?.volumes = current
            for await update in VolumeCatalog.updates() {
                guard let self, !Task.isCancelled else { return }
                self.volumes = update
            }
        }
    }
}

/// Reasons to confirm before quitting.
public struct QuitBlockers: Sendable, Hashable {
    public var queueHasItems: Bool
    public var isScanning: Bool
    public var isDeleting: Bool

    public var any: Bool { queueHasItems || isScanning || isDeleting }
}
