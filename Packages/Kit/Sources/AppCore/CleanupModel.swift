import CleanupKit
import Foundation
import Observation
import RulesKit
import ScanKit

/// What the cleanup store needs from a scan to queue an item from it.
public struct CleanupScanContext: Sendable {
    public var tree: any TreeReading
    /// Rules plus the safety policy with this scan's root protected.
    public var engine: RuleEngine
    public var volume: VolumeInfo?
    /// Structure epoch the caller's node ids belong to; a different epoch on the tree means the ids
    /// were reassigned (full root rescan) and nothing is queued by id until they are resolved again.
    public var expectedEpoch: UInt64?
    /// Classification already computed by the session (skips the nested walk when present).
    public var cachedClassification: (@Sendable @MainActor (NodeID) -> Classification?)?

    public init(tree: any TreeReading, engine: RuleEngine, volume: VolumeInfo?, expectedEpoch: UInt64? = nil, cachedClassification: (@Sendable @MainActor (NodeID) -> Classification?)? = nil) {
        self.tree = tree
        self.engine = engine
        self.volume = volume
        self.expectedEpoch = expectedEpoch
        self.cachedClassification = cachedClassification
    }

    /// True when the tree still has the structure the caller's node ids came from.
    public var isStructureCurrent: Bool {
        guard let expectedEpoch else { return true }
        return structureEpoch(of: tree) == expectedEpoch
    }
}

/// How deletions run. Production uses the system Trash and no root limit; UI test mode uses the
/// fixture Trash and refuses everything outside the fixture (PLAN 2.7 step 7).
public struct CleanupConfiguration: Sendable {
    public var home: String
    public var trash: any TrashProviding
    public var allowedRoot: URL?
    /// Fixture Trash that counts as a Trash for "delete these permanently" (tests only).
    public var testTrash: FixtureTrash?
    public var rules: [Rule]
    public var runningApps: any RunningAppChecking

    public init(home: String, trash: any TrashProviding, allowedRoot: URL?, testTrash: FixtureTrash? = nil, rules: [Rule] = .bundled, runningApps: any RunningAppChecking = WorkspaceRunningApps()) {
        self.home = home
        self.trash = trash
        self.allowedRoot = allowedRoot
        self.testTrash = testTrash
        self.rules = rules
        self.runningApps = runningApps
    }

    public static func production(home: String = NSHomeDirectory()) -> CleanupConfiguration {
        CleanupConfiguration(home: home, trash: SystemTrash(), allowedRoot: nil)
    }

    /// UI test mode: `FixtureTrash` in the fixture, executor limited to the fixture.
    public static func fixture(root: URL, home: String) -> CleanupConfiguration {
        let trash = FixtureTrash(root: root)
        return CleanupConfiguration(home: home, trash: trash, allowedRoot: root, testTrash: trash)
    }
}

/// Cleanup queue store. Frozen contract (PLAN 4.3) plus additive helpers the screens need.
///
/// Adding classifies the item with the scan's RuleEngine (risk and rule), refuses protected items
/// (also folders holding one), copies the scan identity so the executor can verify the item, and
/// never lets the assistant queue dangerous items. Running goes through `CleanupExecutor` only:
/// Trash right away, Delete Permanently after a 5 second countdown that Stop cancels. Dangerous
/// items run only after a per-item acknowledgement. In preview mode `run(mode:)` simulates success
/// and touches no files.
@Observable
@MainActor
public final class CleanupModel {
    private var storage: CleanupQueue
    public var lastReport: DeletionReport?
    public var recentlyTrashed: [TrashedRecord]
    public private(set) var isRunning = false
    /// Seconds left before a permanent deletion starts; nil when no countdown runs.
    public private(set) var countdownRemaining: Int?
    /// True while a countdown is held (for example under the quit alert): it keeps its seconds
    /// and nothing runs until `resumeCountdown()`.
    public private(set) var isCountdownPaused = false
    /// Items done in the current run (for a progress bar).
    public private(set) var runProgress: (done: Int, total: Int)?
    /// Dangerous items the user acknowledged in the confirm sheet.
    public private(set) var acknowledged: Set<UUID> = []
    /// Feedback for the last add from the UI (for a transient banner).
    public private(set) var lastAddResult: AddResult?
    /// The last add was refused only because the item changed while it was being checked (the
    /// live refresh moved it on): adding it again can work. False for items that vanished or
    /// changed identity.
    @ObservationIgnored public private(set) var lastAddRetryable = false
    /// True while the "frees about" estimates are recomputed off the main actor.
    public private(set) var isEstimating = false
    /// Main-actor time from the executor's final event to `isRunning` clearing, for the last run.
    @ObservationIgnored public private(set) var lastRunSettleTime: Duration?

    /// Seconds of the permanent deletion countdown (PLAN 2.7 step 3).
    public static let countdownSeconds = 5

    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var configuration: CleanupConfiguration?
    @ObservationIgnored private var trashStore = RecentlyTrashed()
    /// Dangerous paths that go with each queued dangerous item, computed when it was added.
    @ObservationIgnored private var nestedDangerous: [UUID: [String]] = [:]
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// The frozen run set of the current countdown, kept so a paused countdown can resume.
    @ObservationIgnored private var countdownIDs: Set<UUID>?
    @ObservationIgnored private var executor: CleanupExecutor?
    /// Scan context for a path (the session whose tree holds it). Set by `AppModel`.
    @ObservationIgnored public var scanContext: @MainActor (String) -> CleanupScanContext? = { _ in nil }
    /// Roots of every open scan, protected in the executor's policy. Set by `AppModel`.
    @ObservationIgnored public var scanRoots: @MainActor () -> [String] = { [] }
    /// Called after a run with the items that are gone, so sessions can update their trees.
    @ObservationIgnored public var itemsRemoved: @MainActor ([QueueItem]) -> Void = { _ in }
    /// Called right before the executor runs, so live refreshes ignore the app's own deletions.
    @ObservationIgnored public var itemsWillBeRemoved: @MainActor ([QueueItem]) -> Void = { _ in }
    /// The estimate refresh running off the main actor, if any (at most one).
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    /// The queue changed while an estimate refresh ran: run once more when it lands.
    @ObservationIgnored private var estimateDirty = false

    /// Up to this many queued nodes (items plus everything inside them) the "frees about"
    /// estimates are recomputed on the main actor; above it, off the main actor (hard-link and
    /// clone walks over large folders take long).
    public static let synchronousEstimateLimit: UInt64 = 20_000

    public init(queue: [QueueItem] = [], recentlyTrashed: [TrashedRecord] = [], isPreview: Bool = false) {
        self.storage = CleanupQueue(items: queue)
        self.recentlyTrashed = recentlyTrashed
        self.isPreview = isPreview
    }

    /// A live store that deletes through `CleanupExecutor`.
    public convenience init(configuration: CleanupConfiguration) {
        self.init()
        self.configuration = configuration
    }

    public var queue: [QueueItem] { storage.items }
    public var totalBytes: UInt64 { storage.totalBytes }
    public var selectedBytes: UInt64 { storage.selectedBytes }
    public var selectedFreesAbout: UInt64 { storage.selectedFreesAbout }
    public var selectedCount: Int { storage.selected.count }
    public var selectedItems: [QueueItem] { storage.selected }
    public var selectedCountByRisk: [Risk: Int] { storage.selectedCountByRisk }
    /// Selected items that need the per-item acknowledgement before a run.
    public var selectedNeedingAcknowledgement: [QueueItem] { storage.selectedNeedingAcknowledgement }
    /// True when something would be removed and nothing runs or counts down.
    public var canRun: Bool {
        !isRunning && countdownRemaining == nil && !removalSet.isEmpty
    }

    /// Whether `item` may be removed at all, by its recorded risk: safe and review yes; dangerous
    /// only after the user's acknowledgement (which also makes it the user's own item); never no.
    public func mayRemove(_ item: QueueItem) -> Bool {
        switch item.risk {
        case .safe, .review: true
        case .dangerous: acknowledged.contains(item.id) && !item.source.isAssistant
        case .never: false
        }
    }

    /// The one "will be removed" set: ticked and allowed by `mayRemove`. Rows, totals, the confirm
    /// sheet and the run all use it.
    public var removalSet: [QueueItem] {
        storage.items.filter { $0.isSelected && mayRemove($0) }
    }

    /// Bytes still in the Trash from earlier cleanups (freed only when the Trash is emptied).
    public var trashedBytes: UInt64 { recentlyTrashedBytes }
    public var recentlyTrashedBytes: UInt64 { recentlyTrashed.reduce(0) { $0 + $1.bytes } }

    // MARK: Adding

    @discardableResult
    public func add(_ item: ItemSummary, source: QueueSource) -> AddResult {
        if isPreview { return addPreview(item, source: source, risk: .review, ruleID: nil) }
        guard let context = currentContext(for: item.path) else { return remember(.blocked(.notInScan)) }
        let tree = context.tree
        // Looked up by path: the summary may come from another tree or an older generation.
        guard let node = tree.node(atPath: item.path) else { return remember(.blocked(.notInScan)) }
        // The summary carries the scan identity (ScanKit); a different one means the item changed since.
        if let identity = item.identity, let current = tree.identity(node), identity != current {
            return remember(.blocked(.changedSinceScan))
        }
        let result = add(node: node, context: context, source: source)
        return remember(result, retryable: Self.isRetryableRefusal(result, node: node, tree: tree))
    }

    /// Queues `node` of a scan (what `add(_:source:)` does after finding the node).
    @discardableResult
    public func add(node: NodeID, context: CleanupScanContext, source: QueueSource) -> AddResult {
        let result = insert(node: node, context: context, source: source)
        if case .added = result { refreshEstimates() }
        return result
    }

    /// Queues several nodes of one scan with a single estimate refresh at the end.
    @discardableResult
    public func add(nodes: [NodeID], context: CleanupScanContext, source: QueueSource) -> [AddResult] {
        let results = nodes.map { insert(node: $0, context: context, source: source) }
        if results.contains(where: { if case .added = $0 { true } else { false } }) { refreshEstimates() }
        return results
    }

    /// A classification (and dangerous list) computed off the main actor for `insert`.
    struct Precomputed: Sendable {
        var classification: Classification
        var dangerous: [String]?
    }

    /// Queues `item` like `add(_:source:)`, except that a large folder whose nested check has not
    /// run yet is walked off the main actor first (the UI's Add to Cleanup, menu and context menu).
    public func queue(_ item: ItemSummary, source: QueueSource) async -> AddResult {
        if isPreview { return add(item, source: source) }
        guard let context = currentContext(for: item.path) else { return remember(.blocked(.notInScan)) }
        let tree = context.tree
        guard let node = tree.node(atPath: item.path) else { return remember(.blocked(.notInScan)) }
        let cached = context.cachedClassification?(node)
        // Large folders that still need a walk: the nested check (not classified yet) or the
        // dangerous list (classified dangerous). Both walks run off the main actor.
        let needsWalk = cached == nil || (cached?.block == nil && (cached?.risk ?? .safe) >= .dangerous)
        guard needsWalk, tree.flags(node).contains(.directory),
              tree.descendantCount(node) > ScanSessionModel.synchronousClassificationLimit
        else { return add(item, source: source) }
        let engine = context.engine
        let path = tree.path(node)
        var precomputed: Precomputed?
        var again: CleanupScanContext?
        // The live refresh changes the tree all the time (on a whole-disk scan, every few seconds
        // somewhere). Only a change of this item (its identity, its contents' count or size, or a
        // root rescan) means the walk may be out of date: then walk once more.
        for _ in 0..<3 {
            let before = SubtreeStamp(node, in: tree)
            // The person is waiting for this walk: it runs on its own queue, never behind walks
            // that fill Swift's cooperative pool.
            let result = await Self.offPool { () -> Precomputed in
                let full: Classification
                if let cached {
                    full = cached
                } else {
                    let base = engine.classify(path: path, resolveSymlinks: false)
                    full = ScanSessionModel.merge(base, base.block == nil ? engine.protectedDescendant(of: node, in: tree) : nil)
                }
                let dangerous = full.block == nil && full.risk >= .dangerous ? Self.dangerousPaths(in: node, path: path, tree: tree, engine: engine) : nil
                return Precomputed(classification: full, dangerous: dangerous)
            }
            // The tree may have changed while walking: the result is used only for the same item.
            guard let context = currentContext(for: item.path), context.tree === tree, tree.node(atPath: item.path) == node, tree.path(node) == path else {
                return remember(.blocked(.changedSinceScan), retryable: true)
            }
            if SubtreeStamp(node, in: tree) == before, context.expectedEpoch == before.epoch {
                precomputed = result
                again = context
                break
            }
        }
        guard let precomputed, let again else { return remember(.blocked(.changedSinceScan), retryable: true) }
        if let identity = item.identity, let current = tree.identity(node), identity != current {
            return remember(.blocked(.changedSinceScan))
        }
        let result = insert(node: node, context: again, source: source, precomputed: precomputed)
        if case .added = result { refreshEstimates() }
        return remember(result, retryable: Self.isRetryableRefusal(result, node: node, tree: tree))
    }

    private func insert(node: NodeID, context: CleanupScanContext, source: QueueSource, precomputed: Precomputed? = nil) -> AddResult {
        let tree = context.tree
        // Node ids from before a full root rescan name other items now: never queue by a stale id.
        guard context.isStructureCurrent else { return .blocked(.changedSinceScan) }
        let path = tree.path(node)
        if node == tree.root { return .blocked(.scanRoot) }
        let flags = tree.flags(node)
        if flags.contains(.missing) { return .blocked(.changedSinceScan) }
        if context.volume?.isReadOnly == true { return .blocked(.readOnlyVolume) }
        let classification: Classification
        if let precomputed {
            classification = precomputed.classification
        } else if let cached = context.cachedClassification?(node) {
            classification = cached
        } else {
            let base = context.engine.classify(path: path, resolveSymlinks: false)
            // Category items were checked for nested protected items when the categories were built.
            if case .category = source {
                classification = base
            } else {
                classification = ScanSessionModel.merge(base, base.block == nil ? context.engine.protectedDescendant(of: node, in: tree) : nil)
            }
        }
        if let block = classification.block { return .blocked(block) }
        // The executor refuses items without a scan identity, so they are never queued.
        guard tree.identity(node) != nil else { return .blocked(.notInScan) }
        let risk = classification.risk
        if source.isAssistant && risk >= .dangerous { return .needsUserChoice }
        let selected: Bool
        switch source {
        case .user: selected = risk < .dangerous
        case .category: selected = risk == .safe
        case .assistant: selected = false
        }
        let item: QueueItem
        if UInt64(tree.descendantCount(node)) < Self.synchronousEstimateLimit {
            item = QueueItem(node: node, in: tree, risk: risk, ruleID: classification.ruleID, source: source, isSelected: selected)
        } else {
            // The estimate walk of a large folder runs off the main actor (`refreshEstimates`).
            item = QueueItem(
                path: path, nodeID: node, identity: tree.identity(node), bytes: tree.size(node), freesAbout: tree.size(node),
                risk: risk, ruleID: classification.ruleID, source: source, isSelected: source.isAssistant ? false : selected
            )
        }
        let result = storage.add(item, checkedBy: context.engine.policy, volume: context.volume)
        if case .added(let id) = result, risk >= .dangerous {
            // Kept with the item: the acknowledgement must not depend on node ids that a rescan reassigns.
            nestedDangerous[id] = precomputed?.dangerous ?? Self.dangerousPaths(in: node, path: path, tree: tree, engine: context.engine)
        }
        return result
    }

    /// Dangerous items that go with `node`: itself when dangerous by its path, plus nested Photos
    /// libraries, device backups and browser profiles (at most 50), sorted.
    nonisolated static func dangerousPaths(in node: NodeID, path: String, tree: any TreeReading, engine: RuleEngine) -> [String] {
        var paths: [String] = []
        if engine.classify(path: path, resolveSymlinks: false).risk == .dangerous {
            paths.append(path)
        }
        if let tableHit = engine.protectedDescendant(of: node, in: tree), !tableHit.isBlocked, !paths.contains(tableHit.path) {
            paths.append(tableHit.path)
        }
        var stack: [(NodeID, String)] = tree.children(node).filter { tree.flags($0).contains(.directory) }.map { ($0, tree.name(node)) }
        while let (current, parentName) = stack.popLast(), paths.count < 50 {
            let name = tree.name(current)
            if let found = SafetyPolicy.nestedDirectoryClass(name: name, parentName: parentName), found.risk == .dangerous {
                let nested = tree.path(current)
                if !paths.contains(nested) { paths.append(nested) }
                continue
            }
            for child in tree.children(current) where tree.flags(child).contains(.directory) && !tree.flags(child).contains(.symlink) {
                stack.append((child, name))
            }
        }
        return paths.sorted()
    }

    /// Queues every node of `category` (or only `nodes`). Safe items start selected.
    @discardableResult
    public func add(category: CategoryResult, nodes: [NodeID]? = nil, tree: any TreeReading) -> [AddResult] {
        let chosen = nodes ?? category.nodes
        guard category.risk != .never else { return [] }
        if isPreview {
            return lastAdd(chosen.map { node in
                addPreview(tree.summary(of: node), source: .category(category.ruleID), risk: category.risk, ruleID: category.ruleID)
            })
        }
        // The session is found by the tree's root (always valid); insert refuses stale node ids.
        guard !chosen.isEmpty, let context = scanContext(tree.path(tree.root)), context.tree === tree else {
            return chosen.map { _ in .blocked(.notInScan) }
        }
        return lastAdd(add(nodes: chosen, context: context, source: .category(category.ruleID)))
    }

    private func lastAdd(_ results: [AddResult]) -> [AddResult] {
        if let last = results.last { lastAddResult = last }
        return results
    }

    /// Queues every safe, trashable category of the session.
    @discardableResult
    public func addSafeItems(from session: ScanSessionModel) -> [AddResult] {
        guard let tree = session.tree else { return [] }
        return session.safeCategories.flatMap { add(category: $0, tree: tree) }
    }

    public func remove(_ id: UUID) {
        storage.remove(id)
        acknowledged.remove(id)
        nestedDangerous[id] = nil
        refreshEstimates()
    }

    /// Ticks or unticks an item. Items that may not be removed (`mayRemove`) can not be ticked.
    public func setSelected(_ id: UUID, _ selected: Bool) {
        guard let item = storage.items.first(where: { $0.id == id }) else { return }
        if selected && !mayRemove(item) { return }
        storage.setSelected(id, selected)
        refreshEstimates()
    }

    public func toggle(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        setSelected(id, !item.isSelected)
    }

    public func removeAll() {
        storage.removeAll()
        acknowledged.removeAll()
        nestedDangerous.removeAll()
    }

    /// Records (or withdraws) the per-item acknowledgement for a dangerous item. Acknowledging an
    /// item the assistant suggested makes it the user's own item in place (the executor only lets
    /// the user's dangerous items through); withdrawing also unticks it.
    public func acknowledge(_ id: UUID, _ isAcknowledged: Bool = true) {
        guard isAcknowledged else {
            acknowledged.remove(id)
            storage.setSelected(id, false)
            refreshEstimates()
            return
        }
        acknowledged.insert(id)
        if let item = storage.items.first(where: { $0.id == id }), item.source.isAssistant {
            let items = storage.items.map { queued -> QueueItem in
                guard queued.id == id else { return queued }
                var copy = queued
                copy.source = .user
                return copy
            }
            storage = CleanupQueue(items: items)
        }
    }

    /// Dangerous items inside a queued folder (Photos libraries, device backups, browser profiles),
    /// listed in the acknowledgement so the user sees what goes with it. Includes the item itself
    /// when it is dangerous on its own.
    public func nestedDangerousPaths(of item: QueueItem) -> [String] {
        nestedDangerous[item.id] ?? []
    }

    /// Clears the result card after the user has read it.
    public func dismissReport() {
        lastReport = nil
    }

    public func clearLastAddResult() {
        lastAddResult = nil
    }

    // MARK: Running

    /// Trash runs now; Delete Permanently starts the countdown and runs when it ends (Stop cancels).
    /// The run set is frozen here: the selected items (or `ids`, the ones the confirm sheet listed),
    /// so changing the selection during the countdown changes nothing.
    public func requestRun(mode: DeletionMode, ids: Set<UUID>? = nil) {
        guard !isRunning, countdownRemaining == nil else { return }
        let frozen = ids ?? Set(removalSet.map(\.id))
        guard !frozen.isEmpty else { return }
        switch mode {
        case .trash:
            Task { await run(mode: .trash, ids: frozen) }
        case .permanent:
            startCountdown(ids: frozen)
        }
    }

    /// Stops a running permanent-deletion countdown. Nothing has been touched yet.
    public func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        countdownIDs = nil
        isCountdownPaused = false
    }

    /// Holds a running countdown where it is. The timer task is cancelled, so no deletion can
    /// start until `resumeCountdown()`; `stopCountdown()` drops it for good.
    public func pauseCountdown() {
        guard countdownRemaining != nil, !isCountdownPaused else { return }
        countdownTask?.cancel()
        countdownTask = nil
        isCountdownPaused = true
    }

    /// Continues a paused countdown from the seconds it had left.
    public func resumeCountdown() {
        guard isCountdownPaused, let remaining = countdownRemaining, let ids = countdownIDs else { return }
        isCountdownPaused = false
        runCountdown(from: remaining, ids: ids)
    }

    /// Stops a running deletion before its next item.
    public func cancelRun() {
        executor?.cancel()
    }

    private func startCountdown(ids: Set<UUID>) {
        stopCountdown()
        countdownRemaining = Self.countdownSeconds
        countdownIDs = ids
        runCountdown(from: Self.countdownSeconds, ids: ids)
    }

    private func runCountdown(from seconds: Int, ids: Set<UUID>) {
        countdownTask = Task { [weak self] in
            for left in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, !self.isCountdownPaused, self.countdownRemaining != nil else { return }
                self.countdownRemaining = left
            }
            guard let self, !Task.isCancelled, !self.isCountdownPaused, self.countdownRemaining != nil else { return }
            self.countdownRemaining = nil
            self.countdownIDs = nil
            self.countdownTask = nil
            await self.run(mode: .permanent, ids: ids)
        }
    }

    /// Runs the selected items now (no countdown). Unacknowledged dangerous items are left out.
    public func run(mode: DeletionMode) async {
        await run(mode: mode, ids: Set(removalSet.map(\.id)))
    }

    /// Runs exactly the queued items in `ids` (still queued and, when dangerous, acknowledged).
    public func run(mode: DeletionMode, ids: Set<UUID>) async {
        guard !isRunning else { return }
        isRunning = true
        var executorFinished: ContinuousClock.Instant?
        defer {
            isRunning = false
            runProgress = nil
            lastRunSettleTime = executorFinished.map { ContinuousClock.now - $0 }
        }
        let items = storage.items.filter { ids.contains($0.id) && mayRemove($0) }
        let started = Date()
        guard !items.isEmpty else { return }
        if isPreview {
            simulateRun(items, mode: mode, started: started)
            return
        }
        guard let configuration else {
            lastReport = DeletionReport(mode: mode, succeeded: [], failed: [], startedAt: started, finishedAt: Date())
            return
        }
        itemsWillBeRemoved(items)
        let roots = scanRoots()
        let policy = SafetyPolicy(home: configuration.home, scanRoots: roots)
        let executor = CleanupExecutor(policy: policy, trash: configuration.trash, allowedRoot: configuration.allowedRoot, rules: configuration.rules, runningApps: configuration.runningApps)
        self.executor = executor
        runProgress = (0, items.count)
        var report: DeletionReport?
        for await event in executor.run(items, mode: mode) {
            switch event {
            case .itemStarted: break
            case .itemSucceeded, .itemFailed:
                if let progress = runProgress { runProgress = (progress.done + 1, progress.total) }
            case .finished(let final):
                report = final
                executorFinished = ContinuousClock.now
            }
        }
        self.executor = nil
        let final = report ?? DeletionReport(mode: mode, succeeded: [], failed: [], startedAt: started, finishedAt: Date())
        apply(final, items: items)
    }

    private func apply(_ report: DeletionReport, items: [QueueItem]) {
        let signpost = Signposts.begin("cleanup.apply")
        defer { Signposts.end("cleanup.apply", signpost) }
        let done = Set(report.succeeded.map(\.itemID))
        let removed = items.filter { done.contains($0.id) }
        storage.apply(report)
        acknowledged.subtract(done)
        for id in done { nestedDangerous[id] = nil }
        trashStore.record(report)
        recentlyTrashed = trashStore.records.reversed()
        lastReport = report
        if !removed.isEmpty { itemsRemoved(removed) }
        refreshEstimates()
    }

    /// Recently trashed records that came from `report` and are still in the Trash.
    public func trashedRecords(from report: DeletionReport) -> [TrashedRecord] {
        let urls = Set(report.succeeded.compactMap(\.trashedURL))
        return recentlyTrashed.filter { urls.contains($0.trashedURL) }
    }

    /// Deletes the recently trashed items for good, without emptying the rest of the Trash.
    public func deleteRecentlyTrashedPermanently() {
        deleteRecentlyTrashed(Set(recentlyTrashed.map(\.id)))
    }

    /// Deletes the chosen recently trashed items for good (each is revalidated first).
    public func deleteRecentlyTrashed(_ ids: Set<UUID>) {
        if isPreview {
            recentlyTrashed.removeAll { ids.contains($0.id) }
            return
        }
        guard let configuration, !ids.isEmpty, !isRunning else { return }
        isRunning = true
        let snapshot = trashStore
        Task { [weak self] in
            // Its own queue, like a cleanup run: never behind walks on the cooperative pool.
            let (report, updated) = await Self.offPool {
                var copy = snapshot
                let report = copy.deletePermanently(ids, allowedRoot: configuration.allowedRoot, testTrash: configuration.testTrash)
                return (report, copy)
            }
            guard let self else { return }
            // Merge instead of overwriting: records pruned or added meanwhile stay as they are.
            let gone = Set(snapshot.records.map(\.id)).subtracting(updated.records.map(\.id))
            self.trashStore = RecentlyTrashed(records: self.trashStore.records.filter { !gone.contains($0.id) })
            self.recentlyTrashed = self.trashStore.records.reversed()
            self.lastReport = report
            self.isRunning = false
        }
    }

    /// After a full root rescan the scan's node ids changed: resolve the queued items of that tree
    /// again by path (items whose path is gone keep no node and are refused by the executor's
    /// identity check if they reappear differently).
    public func remapNodes(in tree: any TreeReading) {
        let root = tree.path(tree.root)
        let prefix = root == "/" ? "/" : root + "/"
        var changed = false
        let items = storage.items.map { item -> QueueItem in
            guard item.path.hasPrefix(prefix) else { return item }
            var copy = item
            copy.nodeID = tree.node(atPath: item.path)
            changed = changed || copy.nodeID != item.nodeID
            return copy
        }
        guard changed else { return }
        storage = CleanupQueue(items: items)
        refreshEstimates()
    }

    /// Drops records whose item is no longer in the Trash (emptied or put back).
    public func pruneRecentlyTrashed() {
        guard !isPreview else { return }
        trashStore.pruneMissing()
        recentlyTrashed = trashStore.records.reversed()
    }

    // MARK: Private

    /// Runs `work` on a private serial queue and returns its result. Not the cooperative pool and
    /// not a global concurrent queue: both stop adding threads when their threads are busy, while
    /// a private queue gets a thread of its own. Main-actor isolated on purpose: a nonisolated
    /// async function would itself wait for a pool thread.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.alexluncan.lightwell.cleanup.walk", qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// The scan context for `path`, for a node about to be looked up by path in its tree: such an
    /// id belongs to the tree's current structure, so the context expects that epoch (not the one
    /// the session last handled; the refresher may have swapped in a root rescan just now).
    private func currentContext(for path: String) -> CleanupScanContext? {
        guard var context = scanContext(path) else { return nil }
        context.expectedEpoch = structureEpoch(of: context.tree)
        return context
    }

    /// What must stay the same while a large folder is walked for its classification.
    struct SubtreeStamp: Equatable {
        var identity: FileIdentity?
        var descendants: UInt32
        var bytes: UInt64
        var epoch: UInt64

        init(_ node: NodeID, in tree: any TreeReading) {
            identity = tree.identity(node)
            descendants = tree.descendantCount(node)
            bytes = tree.size(node)
            epoch = structureEpoch(of: tree)
        }
    }

    private func remember(_ result: AddResult, retryable: Bool = false) -> AddResult {
        lastAddResult = result
        lastAddRetryable = retryable
        return result
    }

    /// `insert` refuses with `changedSinceScan` for a node marked missing (gone from disk) and
    /// for ids from before a root rescan; only the latter can work on a second try.
    private static func isRetryableRefusal(_ result: AddResult, node: NodeID, tree: any TreeReading) -> Bool {
        guard result == .blocked(.changedSinceScan) else { return false }
        return !tree.flags(node).contains(.missing)
    }

    /// What an estimate refresh depends on besides the tree: the items, their nodes and ticks.
    struct EstimateKey: Hashable {
        var ids: [UUID]
        var nodes: [NodeID?]
        var selected: [Bool]

        init(_ items: [QueueItem]) {
            ids = items.map(\.id)
            nodes = items.map(\.nodeID)
            selected = items.map(\.isSelected)
        }
    }

    /// The tree the estimates are computed against: every queued item belongs to one scan tree
    /// and still names its node there.
    private func estimateTree() -> (any TreeReading)? {
        guard !isPreview, let first = storage.items.first, let context = scanContext(first.path) else { return nil }
        let tree = context.tree
        guard storage.items.allSatisfy({ item in
            guard let node = item.nodeID else { return false }
            return tree.path(node) == item.path
        }) else { return nil }
        return tree
    }

    /// PLAN 2.7 step 2: shared hard-link and clone bytes count only when every member goes.
    /// Applied when every queued item belongs to one scan tree. A small queue is recomputed in
    /// place; a large one off the main actor (one refresh at a time, the result is applied only if
    /// the items and ticks are still the ones it was computed for, and a change meanwhile runs it
    /// once more), so ticking a row never waits for hard-link and clone walks.
    private func refreshEstimates() {
        if estimateTask != nil {
            estimateDirty = true
            return
        }
        guard let tree = estimateTree() else { return }
        let work = storage.items.reduce(UInt64(0)) { total, item in
            total + 1 + UInt64(item.nodeID.map { tree.descendantCount($0) } ?? 0)
        }
        if work <= Self.synchronousEstimateLimit {
            storage.refreshEstimates(using: tree)
            return
        }
        isEstimating = true
        estimateTask = Task { [weak self] in
            await self?.runEstimates()
            self?.estimateTask = nil
            self?.isEstimating = false
        }
    }

    private func runEstimates() async {
        repeat {
            estimateDirty = false
            guard let tree = estimateTree() else { return }
            let items = storage.items
            let key = EstimateKey(items)
            let estimates = await Task.detached(priority: .userInitiated) { () -> [UUID: UInt64] in
                var copy = CleanupQueue(items: items)
                copy.refreshEstimates(using: tree)
                return Dictionary(uniqueKeysWithValues: copy.items.map { ($0.id, $0.freesAbout) })
            }.value
            if EstimateKey(storage.items) == key {
                storage = CleanupQueue(items: storage.items.map { item in
                    var copy = item
                    if let value = estimates[item.id] { copy.freesAbout = value }
                    return copy
                })
            } else {
                estimateDirty = true
            }
        } while estimateDirty
    }

    /// Waits until no estimate refresh runs (tests).
    func estimatesSettled() async {
        while let task = estimateTask { await task.value }
    }

    private func addPreview(_ item: ItemSummary, source: QueueSource, risk: Risk, ruleID: String?) -> AddResult {
        let selected: Bool
        switch source {
        case .user: selected = risk < .dangerous
        case .category: selected = risk == .safe
        case .assistant: selected = false
        }
        let queued = QueueItem(
            path: item.path,
            nodeID: item.nodeID,
            bytes: item.bytes,
            freesAbout: item.freesAbout,
            risk: risk,
            ruleID: ruleID,
            source: source,
            isSelected: selected
        )
        return remember(storage.add(queued))
    }

    private func simulateRun(_ items: [QueueItem], mode: DeletionMode, started: Date) {
        func trashURL(_ item: QueueItem) -> URL { URL(fileURLWithPath: "/Users/preview/.Trash/\(item.name)") }
        let succeeded = items.map { DeletionSuccess(itemID: $0.id, path: $0.path, bytes: $0.freesAbout, trashedURL: mode == .trash ? trashURL($0) : nil) }
        for item in items {
            storage.remove(item.id)
            acknowledged.remove(item.id)
        }
        if mode == .trash {
            recentlyTrashed.insert(contentsOf: items.map {
                TrashedRecord(originalPath: $0.path, trashedURL: trashURL($0), bytes: $0.bytes, date: Date())
            }, at: 0)
        }
        lastReport = DeletionReport(mode: mode, succeeded: succeeded, failed: [], startedAt: started, finishedAt: Date())
    }
}
