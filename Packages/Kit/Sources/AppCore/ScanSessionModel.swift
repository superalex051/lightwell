import CleanupKit
import Foundation
import Observation
import RulesKit
import ScanKit
import Synchronization
import VizKit

/// What a session scans.
public enum ScanTarget: Sendable, Hashable {
    case volume(VolumeInfo)
    case folder(URL)

    public var url: URL {
        switch self {
        case .volume(let volume): volume.url
        case .folder(let url): url
        }
    }

    public var displayName: String {
        switch self {
        case .volume(let volume): volume.name
        case .folder(let url): url.lastPathComponent
        }
    }

    public var isVolume: Bool {
        if case .volume = self { true } else { false }
    }
}

public enum ScanState: Sendable, Hashable {
    case idle
    case scanning
    case finished
    case failed(ScanError)
    case cancelled
}

/// A tree whose nodes can be removed after a deletion (`ScanTree`; test trees conform in tests).
public protocol RemovableTree: TreeReading {
    func removeSubtree(_ id: NodeID)
}

extension ScanTree: RemovableTree {}

/// A tree whose node ids can all be reassigned at once (a full root rescan swapped in place).
/// `structureEpoch` changes exactly then; ids from an older epoch must be resolved again by path.
public protocol StructureVersioned: AnyObject {
    var structureEpoch: UInt64 { get }
}

extension ScanTree: StructureVersioned {}

/// Structure epoch of any tree (0 for trees that never reassign ids).
func structureEpoch(of tree: any TreeReading) -> UInt64 {
    (tree as? any StructureVersioned)?.structureEpoch ?? 0
}

/// Everything a live session needs besides its target.
public struct ScanServices: Sendable {
    /// Home folder the rules and the safety policy see (`<fixture>/home` in UI test mode).
    public var home: String
    public var rules: [Rule]
    public var metadata: any FileMetadataProviding
    public var workers: Int?
    public var countClonesOnce: Bool
    public var excludedPaths: [String]
    /// Keep the tree current with FSEvents after the scan (PLAN 2.4).
    public var liveRefresh: Bool
    /// UI test mode: feed the live refresh a dropped-events notice right after the scan.
    public var injectDroppedEvents = false

    public init(home: String, rules: [Rule] = .bundled, metadata: any FileMetadataProviding = LiveFileMetadata(), workers: Int? = nil, countClonesOnce: Bool = true, excludedPaths: [String] = [], liveRefresh: Bool = true) {
        self.home = home
        self.rules = rules
        self.metadata = metadata
        self.workers = workers
        self.countClonesOnce = countClonesOnce
        self.excludedPaths = excludedPaths
        self.liveRefresh = liveRefresh
    }
}

/// One scan and its navigation state. Frozen contract (PLAN 4.3) plus additive helpers.
///
/// A live session drives `Scanner`, then computes the volume summary and the RulesKit categories
/// off the main actor, keeps the tree current with `TreeRefresher`, and offers one `TreeMapSource`
/// per tree (its revision bumps when categories arrive). A preview session finishes immediately
/// with the supplied tree.
@Observable
@MainActor
public final class ScanSessionModel: Identifiable {
    public let id: UUID
    public let target: ScanTarget
    public var state: ScanState
    public var progress: ScanProgress?
    public var tree: (any TreeReading)?
    public var summary: SpaceSummary?
    public var categories: [CategoryResult]
    /// Folder shown in Explore.
    public var current: NodeID {
        didSet {
            currentPath = livePath(current)
            prepareClassification(for: current)
        }
    }
    public var selection: NodeID? {
        didSet {
            selectionPath = selection.flatMap(livePath)
            if let selection { prepareClassification(for: selection) }
        }
    }
    /// Bumped when a classification computed off the main actor arrives (inspector, menus).
    public private(set) var classificationRevision: UInt64 = 0
    public private(set) var backStack: [NodeID] = [] { didSet { backPaths = backStack.compactMap(livePath) } }
    public private(set) var forwardStack: [NodeID] = [] { didSet { forwardPaths = forwardStack.compactMap(livePath) } }
    /// Folders that did not answer during the scan or a refresh (size unknown, not an access problem).
    public private(set) var unresponsiveFolderCount = 0
    /// Volume holding the scanned root, with free space as of the last refresh.
    public private(set) var volume: VolumeInfo?
    /// When the scan finished (scan age for the assistant).
    public private(set) var finishedAt: Date?
    /// True while categories are computed after a scan or a change.
    public private(set) var isClassifying = false
    /// The root changed or its disk went away; the data may be out of date.
    public private(set) var staleReason: StaleReason?
    /// Changes were missed in many places: a full refresh of the scan waits until about this time
    /// (the live refresh rate limits whole-disk rescans). Nil when none is waiting.
    public private(set) var fullRefreshPendingAt: Date?
    /// Bumped when the tree changes in place (live refresh, deletions), so views redraw.
    public private(set) var treeRevision: UInt64 = 0
    /// Bumped when the map colours change (categories arrived).
    public private(set) var mapRevision: UInt64 = 0
    /// Rules and safety policy for this scan (home plus this scan root).
    public private(set) var engine: RuleEngine?
    /// One map source per tree, kept so the map's layout cache stays warm.
    public private(set) var mapSource: TreeMapSource?
    public private(set) var categorizer: NodeCategorizer?

    @ObservationIgnored private let previewTree: (any TreeReading)?
    @ObservationIgnored private let previewCategories: [CategoryResult]
    @ObservationIgnored private let services: ScanServices?
    @ObservationIgnored private var scanner: ScanKit.Scanner?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var refresher: TreeRefresher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var classifyTask: Task<Void, Never>?
    @ObservationIgnored private var classifyGeneration = 0
    /// The one categorization walk that may run (a newer one waits for it to stop).
    @ObservationIgnored private var classifyWalk: Task<[CategoryResult]?, Never>?
    @ObservationIgnored private var lastWalkStart: ContinuousClock.Instant?
    @ObservationIgnored private var appliedClassifyGeneration = 0
    /// A `.now` request is waiting to start its walk.
    @ObservationIgnored private var pendingUrgent = false
    /// The running walk serves a `.now` request.
    @ObservationIgnored private var walkIsUrgent = false
    /// Since when the shown categories lag behind the tree (nil when they are current).
    @ObservationIgnored private var categoriesStaleSince: ContinuousClock.Instant?
    /// Live refresh: a categorization walk starts at most once per this interval (the newest change wins).
    @ObservationIgnored var refreshClassifyInterval: Duration = .seconds(30)
    /// After this long without current categories, a running walk is let finish instead of being
    /// restarted, so a folder that never stops changing can not starve the categories.
    @ObservationIgnored var maximumCategoryStaleness: Duration = .seconds(120)
    /// Counts categorization walks (tests check that at most one runs at a time).
    nonisolated let walkStats = WalkStats()
    /// Paths of the navigation state, so it survives a full root rescan (node ids are reassigned).
    @ObservationIgnored private var currentPath: String?
    @ObservationIgnored private var selectionPath: String?
    @ObservationIgnored private var backPaths: [String] = []
    @ObservationIgnored private var forwardPaths: [String] = []
    @ObservationIgnored private var knownEpoch: UInt64 = 0
    /// Category index by node, for `category(covering:)`.
    @ObservationIgnored private var categoryIndex: [NodeID: Int] = [:]
    /// Classifications per node for the current tree object and structure epoch. A tree change
    /// drops only the entries on the changed paths (their ancestors and descendants).
    @ObservationIgnored private var classificationCache: [NodeID: Classification] = [:]
    /// Path of each cached node when it was cached (to match changed paths).
    @ObservationIgnored private var classificationPaths: [NodeID: String] = [:]
    @ObservationIgnored private var classificationStamp: ClassificationStamp?
    /// Tree generation the cache is current for.
    @ObservationIgnored private var cacheGeneration: UInt64 = 0
    /// Paths changed since `cacheGeneration`, and the tree generation after the last of them.
    @ObservationIgnored private var changedPaths: [String] = []
    @ObservationIgnored private var changedPathsGeneration: UInt64?
    /// Bumped when the whole cache is dropped (pending walks from before are discarded).
    @ObservationIgnored private(set) var cacheResets = 0
    /// Nodes with a nested walk in flight (at most one per node, whatever the stamp), by path.
    @ObservationIgnored private var classificationPending: [NodeID: String] = [:]
    /// Pending nodes whose subtree changed while their walk ran (the result is discarded).
    @ObservationIgnored private var classificationDirty: Set<NodeID> = []
    @ObservationIgnored private var partialScanner: ScanKit.Scanner?
    @ObservationIgnored private var partialTask: Task<Void, Never>?
    @ObservationIgnored private var breakdownCache: (generation: UInt64, revision: UInt64, value: [SpaceFamily: UInt64])?
    /// Called after node ids were reassigned (full root rescan), so the queue can re-resolve its items.
    @ObservationIgnored public var onRestructure: @MainActor (ScanSessionModel) -> Void = { _ in }
    /// Called once when the scan finishes (notifications, Dock progress).
    @ObservationIgnored public var onFinished: @MainActor (ScanSessionModel) -> Void = { _ in }

    public init(
        id: UUID = UUID(),
        target: ScanTarget,
        previewTree: (any TreeReading)? = nil,
        previewCategories: [CategoryResult] = []
    ) {
        self.id = id
        self.target = target
        self.state = .idle
        self.categories = []
        self.current = 0
        self.previewTree = previewTree
        self.previewCategories = previewCategories
        self.services = nil
    }

    /// A live session that scans the disk.
    public init(id: UUID = UUID(), target: ScanTarget, services: ScanServices) {
        self.id = id
        self.target = target
        self.state = .idle
        self.categories = []
        self.current = 0
        self.previewTree = nil
        self.previewCategories = []
        self.services = services
    }

    /// Injects a finished tree (tests and fixtures that do not scan). Categories are computed as usual.
    public init(id: UUID = UUID(), target: ScanTarget, tree: any TreeReading, services: ScanServices) {
        self.id = id
        self.target = target
        self.state = .idle
        self.categories = []
        self.current = tree.root
        self.previewTree = tree
        self.previewCategories = []
        self.services = services
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var isFinished: Bool { state == .finished }

    /// Root to current folder, for the breadcrumb.
    public var breadcrumb: [NodeID] { tree?.ancestry(of: current) ?? [] }

    /// Path of the scanned root.
    public var rootPath: String { tree.map { $0.path($0.root) } ?? Self.canonicalRoot(target.url) }

    // MARK: Scanning

    public func startScan() {
        if let previewTree {
            if let services {
                finish(with: previewTree, services: services)
            } else {
                finishPreview(previewTree)
            }
            return
        }
        guard let services else {
            state = .scanning
            progress = ScanProgress(fraction: nil, itemsScanned: 0, bytesScanned: 0, currentPath: target.url.path)
            return
        }
        stopLiveWork()
        state = .scanning
        staleReason = nil
        progress = ScanProgress(fraction: nil, itemsScanned: 0, bytesScanned: 0, currentPath: target.url.path)
        let options = ScanOptions(
            root: URL(fileURLWithPath: Self.canonicalRoot(target.url)),
            workers: services.workers,
            countClonesOnce: services.countClonesOnce,
            excludedPaths: services.excludedPaths
        )
        let scanner = ScanKit.Scanner(options)
        self.scanner = scanner
        let stream = scanner.start()
        scanTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .progress(let value):
                    if self.state == .scanning { self.progress = value }
                case .finished(let tree):
                    guard self.state == .scanning else { return }
                    self.finish(with: tree, services: services)
                case .failed(let error):
                    guard self.state == .scanning else { return }
                    self.state = error == .cancelled ? .cancelled : .failed(error)
                }
            }
        }
    }

    public func cancel() {
        guard state == .scanning else { return }
        scanner?.cancel()
        scanTask?.cancel()
        state = .cancelled
    }

    /// Rescans `node` (or the whole target when nil). A folder rescan splices the fresh subtree in
    /// place (`ScanTree.replaceChildren`); anything else starts a full scan.
    public func rescan(_ node: NodeID?) {
        guard services != nil, previewTree == nil else { return }
        guard let node, let scanTree = tree as? ScanTree, node != scanTree.root,
              scanTree.flags(node).contains(.directory), let services
        else {
            backStack.removeAll()
            forwardStack.removeAll()
            selection = nil
            startScan()
            return
        }
        let path = scanTree.path(node)
        let options = ScanOptions(root: URL(fileURLWithPath: path), workers: services.workers, countClonesOnce: services.countClonesOnce, excludedPaths: services.excludedPaths)
        partialScanner?.cancel()
        partialTask?.cancel()
        let scanner = ScanKit.Scanner(options)
        partialScanner = scanner
        let stream = scanner.start()
        partialTask = Task { [weak self] in
            for await event in stream {
                guard case .finished(let fresh) = event else { continue }
                guard !Task.isCancelled else { return }
                await Task.detached(priority: .userInitiated) { scanTree.replaceChildren(of: node, with: fresh) }.value
                guard let self, self.tree === scanTree else { return }
                self.partialScanner = nil
                self.partialTask = nil
                // The spliced subtree has new node ids: navigation and the queue resolve them by path.
                self.nodesReassigned(rescanned: path)
            }
        }
    }

    // MARK: Navigation

    public func navigate(to node: NodeID) {
        guard node != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = node
        selection = nil
    }

    public func goUp() {
        guard let parent = tree?.parent(current) else { return }
        navigate(to: parent)
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }

    // MARK: Helpers for the screens

    /// The knowledge-base category that covers `node` (the node itself or an ancestor).
    public func category(covering node: NodeID) -> CategoryResult? {
        guard let tree else { return nil }
        var cursor: NodeID? = node
        while let id = cursor {
            if let index = categoryIndex[id], index < categories.count { return categories[index] }
            cursor = tree.parent(id)
        }
        return nil
    }

    /// True when `node` can be added to the cleanup queue (see `addBlockReason(for:)` for why not).
    public func canQueue(_ node: NodeID) -> Bool {
        addBlockReason(for: node) == nil
    }

    /// The folder did not answer in time during the scan (shown as unknown size, not an access problem).
    public func isNotResponding(_ node: NodeID) -> Bool {
        tree?.flags(node).contains(.notResponding) ?? false
    }

    /// The folder could not be read (EACCES / EPERM); Full Disk Access may help.
    public func isRestricted(_ node: NodeID) -> Bool {
        tree?.flags(node).contains(.restricted) ?? false
    }

    /// Runs the waiting full refresh now ("Refresh Now").
    public func refreshEverythingNow() {
        fullRefreshPendingAt = nil
        refresher?.rescanRootNow()
    }

    /// Tells the live refresh to ignore changes the app itself is about to make (deletions).
    public func suppressRefresh(for paths: [String]) {
        let mine = paths.filter { contains(path: $0) }
        guard !mine.isEmpty else { return }
        refresher?.suppress(mine)
    }

    public func category(ruleID: String?) -> CategoryResult? {
        guard let ruleID else { return nil }
        return categories.first { $0.ruleID == ruleID }
    }

    /// Bytes per risk level across all categories.
    public func reclaimableBytes(_ risks: Set<Risk>) -> UInt64 {
        categories.filter { risks.contains($0.risk) }.reduce(0) { $0 + $1.bytes }
    }

    public var safeCategories: [CategoryResult] {
        categories.filter { $0.risk == .safe && $0.action == .trash }
    }

    /// Risk shown for a queued item (the store records the rule's risk).
    public func displayRisk(of item: QueueItem) -> Risk {
        item.risk
    }

    /// Badge title for a queued item from a category: its rule's title (what the category shows).
    /// Read from the rules, not from `categories`, so the queue's rows neither change nor redraw
    /// while categories are rebuilt (every re-categorization, and a root rescan clears them).
    public func sourceTitle(of item: QueueItem) -> String? {
        guard case .category(let ruleID) = item.source else { return nil }
        return engine?.rule(withID: ruleID)?.title ?? category(ruleID: ruleID)?.title
    }

    /// Plain explanation for a queued item: the assistant's reason or the rule's explanation (a
    /// category's explanation is its rule's). From the rules first, like `sourceTitle(of:)`.
    public func explanation(of item: QueueItem) -> String? {
        if case .assistant(_, let reason) = item.source { return reason }
        var ruleID = item.ruleID
        if case .category(let categoryRule) = item.source { ruleID = categoryRule }
        if let ruleID, let rule = engine?.rule(withID: ruleID) { return rule.explanation }
        return category(ruleID: ruleID)?.explanation
    }

    /// Folders with more descendants than this are checked for nested protected items off the
    /// main actor (the walk visits every folder inside).
    public static let synchronousClassificationLimit: UInt32 = 2_000

    /// Classification of `node` for the inspector, menus and Add to Cleanup (risk, rule, explanation,
    /// block reason, nested protected items). Cached per node for the current tree generation and
    /// structure epoch. For a large folder the nested check runs off the main actor: until it lands
    /// (`classificationRevision` bumps) the answer is the path-only classification.
    public func classification(of node: NodeID) -> Classification? {
        guard let tree, let engine else { return nil }
        if node == tree.root { return Classification(risk: .never, block: .scanRoot) }
        validateClassificationCache(tree)
        if let cached = classificationCache[node] { return cached }
        let path = tree.path(node)
        let base = engine.classify(path: path, resolveSymlinks: false)
        guard base.block == nil, tree.flags(node).contains(.directory) else {
            cache(base, for: node, path: path)
            return base
        }
        if tree.descendantCount(node) <= Self.synchronousClassificationLimit {
            let full = Self.merge(base, engine.protectedDescendant(of: node, in: tree))
            cache(full, for: node, path: path)
            return full
        }
        scheduleClassification(node, path: path, base: base, tree: tree, engine: engine)
        return base
    }

    private func cache(_ classification: Classification, for node: NodeID, path: String) {
        classificationCache[node] = classification
        classificationPaths[node] = path
    }

    /// The cached classification of `node`, if it was computed already (never walks the tree).
    public func cachedClassification(of node: NodeID) -> Classification? {
        guard let tree else { return nil }
        validateClassificationCache(tree)
        return classificationCache[node]
    }

    /// Starts computing the classification of `node` (selection or folder changed).
    public func prepareClassification(for node: NodeID) {
        guard engine != nil, tree != nil else { return }
        _ = classification(of: node)
    }

    nonisolated static func merge(_ base: Classification, _ nested: ProtectedDescendant?) -> Classification {
        guard base.block == nil, let nested else { return base }
        var result = base
        if let block = nested.classification.block {
            result.block = block
            result.risk = .never
        } else {
            result.risk = max(result.risk, .dangerous)
        }
        return result
    }

    /// What cached classifications belong to: the tree object (a rescan installs a new one, which
    /// can start at the same generation and epoch) and its structure epoch. Generation changes are
    /// handled per path (`noteTreeChange`).
    struct ClassificationStamp: Equatable {
        var tree: ObjectIdentifier
        var epoch: UInt64
    }

    /// Records paths whose subtrees changed; the tree's generation is `generation` afterwards.
    func noteTreeChange(_ paths: [String], generation: UInt64) {
        changedPaths.append(contentsOf: paths)
        changedPathsGeneration = max(changedPathsGeneration ?? 0, generation)
    }

    /// Brings the classification cache up to the tree. Another tree object or epoch drops it all.
    /// A newer generation drops only the entries on recorded changed paths, provided the records
    /// account for the current generation; a change nobody recorded drops it all (fail safe).
    private func validateClassificationCache(_ tree: any TreeReading) {
        let stamp = ClassificationStamp(tree: ObjectIdentifier(tree), epoch: structureEpoch(of: tree))
        let generation = tree.generation
        if stamp != classificationStamp {
            classificationStamp = stamp
            resetClassificationCache(generation: generation)
            return
        }
        guard generation != cacheGeneration else { return }
        if !changedPaths.isEmpty, changedPathsGeneration == generation {
            invalidateClassifications(under: changedPaths)
            changedPaths.removeAll()
            changedPathsGeneration = nil
            cacheGeneration = generation
        } else {
            resetClassificationCache(generation: generation)
        }
    }

    private func resetClassificationCache(generation: UInt64) {
        classificationCache.removeAll(keepingCapacity: true)
        classificationPaths.removeAll(keepingCapacity: true)
        classificationDirty.removeAll()
        changedPaths.removeAll()
        changedPathsGeneration = nil
        cacheGeneration = generation
        cacheResets &+= 1
    }

    /// Drops cached classifications of the changed paths, their ancestors (nested items may have
    /// appeared or gone) and their descendants (re-enumerated), and marks such pending walks dirty.
    private func invalidateClassifications(under paths: [String]) {
        guard !paths.isEmpty else { return }
        func affected(_ entry: String) -> Bool {
            paths.contains { Self.pathsOverlap(entry, $0) }
        }
        for (node, path) in classificationPaths where affected(path) {
            classificationCache[node] = nil
            classificationPaths[node] = nil
        }
        for (node, path) in classificationPending where affected(path) {
            classificationDirty.insert(node)
        }
    }

    /// True when `a` and `b` are the same path or one lies inside the other.
    nonisolated static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        func isWithin(_ path: String, _ ancestor: String) -> Bool {
            ancestor == "/" ? path.hasPrefix("/") : path.hasPrefix(ancestor + "/")
        }
        return a == b || isWithin(a, b) || isWithin(b, a)
    }

    /// Walks `node` for nested protected items off the main actor. At most one walk per node is in
    /// flight: a walk superseded by another tree object or epoch, a full cache reset or a change
    /// inside the node is discarded when it lands (the walk itself can not be interrupted), and one
    /// new walk starts if the node is still shown.
    private func scheduleClassification(_ node: NodeID, path: String, base: Classification, tree: any TreeReading, engine: RuleEngine) {
        guard classificationPending[node] == nil else { return }
        classificationPending[node] = path
        classificationDirty.remove(node)
        let stamp = classificationStamp
        let resets = cacheResets
        Task { [weak self] in
            let nested = await Task.detached(priority: .userInitiated) { engine.protectedDescendant(of: node, in: tree) }.value
            guard let self else { return }
            guard let current = self.tree else {
                self.classificationPending[node] = nil
                return
            }
            self.validateClassificationCache(current)
            self.classificationPending[node] = nil
            let dirty = self.classificationDirty.remove(node) != nil
            // Superseded: discard, and walk again if this id is still on screen, so the inspector
            // does not keep the path-only answer.
            guard self.tree === tree, self.classificationStamp == stamp, self.cacheResets == resets, !dirty else {
                if node == self.current || node == self.selection { self.prepareClassification(for: node) }
                return
            }
            self.cache(Self.merge(base, nested), for: node, path: path)
            self.classificationRevision &+= 1
        }
    }

    /// Why `node` cannot be added to the cleanup queue, or nil when it can (Add to Cleanup disabled with reason).
    public func addBlockReason(for node: NodeID) -> BlockReason? {
        guard let tree else { return .notInScan }
        if node == tree.root { return .scanRoot }
        if tree.flags(node).contains(.missing) { return .changedSinceScan }
        if volume?.isReadOnly == true { return .readOnlyVolume }
        guard engine != nil else {
            // Preview sessions have no rules engine: never-risk categories stay locked.
            return category(covering: node)?.risk == .never ? .systemPath : nil
        }
        return classification(of: node)?.block
    }

    /// Map colour family of `node` (memoized per categories revision).
    public func family(of node: NodeID) -> SpaceFamily? {
        categorizer?.family(of: node)
    }

    /// Bytes per colour family under the scan root, cached per tree generation and categories revision.
    public func breakdown() -> [SpaceFamily: UInt64] {
        guard let tree, let categorizer else { return [:] }
        let key = (tree.generation, mapRevision)
        if let cached = breakdownCache, cached.generation == key.0, cached.revision == key.1 { return cached.value }
        let value = categorizer.breakdown(of: tree.root)
        breakdownCache = (key.0, key.1, value)
        return value
    }

    /// Context the cleanup store uses to queue items from this scan. It carries the structure epoch
    /// the session knows and the session's classification cache (so adds do not walk again).
    public var cleanupContext: CleanupScanContext? {
        guard let tree, let engine, state == .finished else { return nil }
        return CleanupScanContext(
            tree: tree, engine: engine, volume: volume, expectedEpoch: knownEpoch,
            cachedClassification: { [weak self] node in self?.cachedClassification(of: node) }
        )
    }

    /// Context the assistant tools answer from.
    public var toolContext: ToolScanContext? {
        guard let tree, let engine, state == .finished else { return nil }
        return ToolScanContext(tree: tree, engine: engine, volume: volume, summary: summary, categories: categories, finishedAt: finishedAt ?? Date(), isVolumeScan: target.isVolume)
    }

    /// True when `path` lies inside this scan.
    public func contains(path: String) -> Bool {
        let root = rootPath
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Updates the tree after a deletion: removes the items, keeps navigation on surviving folders,
    /// then refreshes the volume summary and the categories.
    public func applyRemoval(_ items: [QueueItem]) {
        let signpost = Signposts.begin("tree.removal")
        defer { Signposts.end("tree.removal", signpost) }
        guard let removable = tree as? any RemovableTree else { return }
        var removedNodes: [NodeID] = []
        for item in items where contains(path: item.path) {
            guard let node = removable.node(atPath: item.path), node != removable.root else { continue }
            removedNodes.append(node)
        }
        guard !removedNodes.isEmpty else { return }
        let removedSet = Set(removedNodes)
        func survivor(_ node: NodeID) -> NodeID? {
            let chain = removable.ancestry(of: node)
            guard let index = chain.firstIndex(where: removedSet.contains) else { return node }
            return index > 0 ? chain[index - 1] : nil
        }
        current = survivor(current) ?? removable.root
        if let selected = selection, survivor(selected) != selected { selection = nil }
        backStack = backStack.compactMap(survivor)
        forwardStack = forwardStack.compactMap(survivor)
        let removedPaths = removedNodes.map { removable.path($0) }
        for node in removedNodes { removable.removeSubtree(node) }
        noteTreeChange(removedPaths, generation: removable.generation)
        treeChanged()
    }

    /// Stops the scan, the live refresh and background work (session closed or app quitting).
    public func shutdown() {
        cancel()
        stopLiveWork()
    }

    // MARK: Private

    private func finishPreview(_ tree: any TreeReading) {
        self.tree = tree
        setCategories(previewCategories)
        current = tree.root
        if case .volume(let volume) = target {
            self.volume = volume
            summary = SpaceSummary.compute(volume, scanned: tree.size(tree.root))
        }
        mapSource = TreeMapSource(tree: tree)
        updateMapCategories()
        finishedAt = Date()
        progress = ScanProgress(fraction: 1, itemsScanned: UInt64(tree.descendantCount(tree.root)), bytesScanned: tree.size(tree.root), currentPath: target.url.path)
        state = .finished
    }

    private func finish(with tree: any TreeReading, services: ScanServices) {
        let signpost = Signposts.begin("scan.finish")
        defer { Signposts.end("scan.finish", signpost) }
        let rootPath = tree.path(tree.root)
        knownEpoch = structureEpoch(of: tree)
        self.tree = tree
        current = tree.root
        updateUnresponsive()
        finishedAt = Date()
        let policy = SafetyPolicy(home: services.home, scanRoot: rootPath)
        engine = RuleEngine(home: services.home, rules: services.rules, policy: policy, metadata: services.metadata)
        mapSource = TreeMapSource(tree: tree)
        updateMapCategories()
        progress = ScanProgress(fraction: 1, itemsScanned: UInt64(tree.descendantCount(tree.root)), bytesScanned: tree.size(tree.root), currentPath: rootPath)
        if case .volume(let volume) = target {
            self.volume = volume
            summary = SpaceSummary.compute(volume, scanned: tree.size(tree.root))
        }
        state = .finished
        refreshVolume()
        classify()
        if services.liveRefresh, let scanTree = tree as? ScanTree {
            startRefresher(scanTree)
        }
        onFinished(self)
        // A rescan built a new tree: queued items from the old one resolve their nodes by path.
        onRestructure(self)
    }

    /// Volume numbers change after deletions and over time: re-read them off the main actor.
    private func refreshVolume() {
        let url = URL(fileURLWithPath: rootPath)
        let isVolume = target.isVolume
        let base = volume
        Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) { VolumeCatalog.volume(containing: url) ?? VolumeLookup.containing(url) }.value
            guard let self, let tree = self.tree else { return }
            var info = fresh ?? base
            if var known = base, let fresh {
                known.capacity = fresh.capacity
                known.available = fresh.available
                known.availableImportant = fresh.availableImportant
                info = known
            }
            self.volume = info
            guard let info else { return }
            let scanned = tree.size(tree.root)
            let computed = SpaceSummary.compute(info, scanned: scanned)
            self.summary = isVolume ? computed : SpaceSummary(
                capacity: computed.capacity, used: computed.used, free: computed.free, purgeable: computed.purgeable,
                otherVolumes: 0, scanned: scanned, hidden: 0
            )
        }
    }

    enum ClassifyTrigger {
        /// Scan finished, deletion, rescan: categorize right away.
        case now
        /// Live refresh (FSEvents): at most one walk per `refreshClassifyInterval`.
        case refresh
    }

    /// RulesKit categories, computed off the main actor (a large tree takes a while).
    ///
    /// Coalesced: at most one walk runs. A newer request cancels the running walk (the walk polls
    /// for cancellation) and starts only once it has stopped; requests in between are dropped, so
    /// N quick refreshes cost one more walk, not N. Live-refresh requests also wait until
    /// `refreshClassifyInterval` has passed since the last walk started. When the categories have
    /// lagged for `maximumCategoryStaleness`, a running walk is let finish (its result is shown)
    /// before the newer one starts, so constant changes can not starve the categories. A refresh
    /// never cancels or delays a `.now` request (scan finished, deletion, rescan).
    private func classify(_ trigger: ClassifyTrigger = .now) {
        guard let tree, let engine else { return }
        classifyGeneration += 1
        let generation = classifyGeneration
        isClassifying = true
        let now = ContinuousClock.now
        if categoriesStaleSince == nil { categoriesStaleSince = now }
        // A refresh that supersedes a waiting `.now` request inherits its urgency (no throttle),
        // so a deletion or a rescan never waits for the live-refresh interval.
        let urgent = trigger == .now || pendingUrgent
        pendingUrgent = urgent
        var delay: Duration = .zero
        if !urgent, let last = lastWalkStart, last + refreshClassifyInterval > now {
            delay = last + refreshClassifyInterval - now
        }
        let previous = classifyWalk
        let starving = categoriesStaleSince.map { now - $0 >= maximumCategoryStaleness } ?? false
        // A refresh never cancels a `.now` walk (scan finished, deletion, rescan): it follows it.
        if trigger == .now || (!starving && !walkIsUrgent) { previous?.cancel() }
        classifyTask?.cancel()
        let stats = walkStats
        classifyTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            // At most one walk runs: wait for the one before (cancelled, or let finish) to stop.
            _ = await previous?.value
            guard let self, !Task.isCancelled, generation == self.classifyGeneration, self.tree === tree else { return }
            self.lastWalkStart = ContinuousClock.now
            self.pendingUrgent = false
            self.walkIsUrgent = urgent
            let walk = Task.detached(priority: urgent ? .userInitiated : .utility) { () -> [CategoryResult]? in
                stats.begin()
                let result = engine.categories(in: tree, isCancelled: { Task.isCancelled })
                stats.end(stoppedEarly: result == nil)
                return result
            }
            self.classifyWalk = walk
            let result = await walk.value
            if self.classifyWalk == walk { self.classifyWalk = nil }
            guard let result, self.tree === tree else { return }
            self.applyCategories(result, generation: generation)
        }
    }

    /// Shows a finished walk's categories unless newer ones are already shown.
    private func applyCategories(_ result: [CategoryResult], generation: Int) {
        guard generation > appliedClassifyGeneration else { return }
        appliedClassifyGeneration = generation
        setCategories(result)
        if generation == classifyGeneration {
            isClassifying = false
            categoriesStaleSince = nil
        } else {
            // An older walk that was let finish: fresher than what was shown, a newer one follows.
            categoriesStaleSince = ContinuousClock.now
        }
        updateMapCategories()
    }

    private func updateMapCategories() {
        let signpost = Signposts.begin("map.categories")
        defer { Signposts.end("map.categories", signpost) }
        guard let tree, let mapSource else { return }
        let categorizer = NodeCategorizer(tree: tree, categories: categories)
        self.categorizer = categorizer
        mapSource.updateCategories { node in categorizer.family(of: node)?.rawValue }
        mapRevision &+= 1
    }

    private func startRefresher(_ tree: ScanTree) {
        let refresher = TreeRefresher(tree: tree, root: URL(fileURLWithPath: tree.path(tree.root)))
        self.refresher = refresher
        let events = refresher.events
        refresher.start()
        if services?.injectDroppedEvents == true { refresher.injectDroppedEvents() }
        refreshTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .updated(let generation, let paths):
                    if let tree = self.tree, structureEpoch(of: tree) != self.knownEpoch {
                        self.restructured()
                    } else {
                        self.liveTreeChanged(paths: paths, generation: generation)
                    }
                case .restructured:
                    self.restructured()
                case .stale(let reason):
                    self.staleReason = reason
                case .fullRescanPending(let at):
                    self.fullRefreshPendingAt = at
                }
            }
        }
    }

    /// The live refresh changed `paths` (FSEvents). Categories follow, throttled (`classify(.refresh)`).
    func liveTreeChanged(paths: [String], generation: UInt64) {
        noteTreeChange(paths, generation: generation)
        treeChanged(.refresh)
    }

    private func treeChanged(_ trigger: ClassifyTrigger = .now) {
        treeRevision &+= 1
        if let tree, let selected = selection, tree.parent(selected) == nil, selected != tree.root { selection = nil }
        updateUnresponsive()
        refreshVolume()
        classify(trigger)
    }

    /// A full root rescan reassigned every node id: resolve navigation by path, drop the old
    /// categories (their node ids are meaningless now), and let the queue re-resolve its items.
    func restructured() {
        guard let tree else { return }
        let signpost = Signposts.begin("tree.restructure")
        defer { Signposts.end("tree.restructure", signpost) }
        knownEpoch = structureEpoch(of: tree)
        let current = currentPath.map { Self.nearestNode(tree, path: $0) } ?? tree.root
        let back = backPaths.compactMap { tree.node(atPath: $0) }
        let forward = forwardPaths.compactMap { tree.node(atPath: $0) }
        let selection = selectionPath.flatMap { tree.node(atPath: $0) }
        setCategories([])
        updateMapCategories()
        self.current = current
        self.backStack = back
        self.forwardStack = forward
        self.selection = selection
        onRestructure(self)
        treeChanged()
    }

    /// The node at `path`, or its nearest existing ancestor, or the root.
    static func nearestNode(_ tree: any TreeReading, path: String) -> NodeID {
        var candidate = path
        let root = tree.path(tree.root)
        while candidate.count >= root.count {
            if let node = tree.node(atPath: candidate) { return node }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
        return tree.root
    }

    private func setCategories(_ list: [CategoryResult]) {
        categories = list
        var index: [NodeID: Int] = [:]
        for (position, category) in list.enumerated() {
            for node in category.nodes where index[node] == nil { index[node] = position }
        }
        categoryIndex = index
    }

    private func updateUnresponsive() {
        if let scanTree = tree as? ScanTree {
            unresponsiveFolderCount = scanTree.unresponsiveFolders.count
        } else {
            unresponsiveFolderCount = progress?.unresponsiveFolders ?? 0
        }
    }

    /// Path of `node` while the tree's node ids are still the ones this session knows.
    private func livePath(_ node: NodeID) -> String? {
        guard let tree else { return nil }
        if structureEpoch(of: tree) != knownEpoch { return nil }
        return tree.path(node)
    }

    /// After a partial rescan: the subtree's node ids are new, so navigation and the queue resolve by path.
    private func nodesReassigned(rescanned path: String) {
        guard let tree else { return }
        // Ids inside the spliced subtree are new; nothing outside it changed.
        noteTreeChange([path], generation: tree.generation)
        current = currentPath.map { Self.nearestNode(tree, path: $0) } ?? tree.root
        backStack = backPaths.compactMap { tree.node(atPath: $0) }
        forwardStack = forwardPaths.compactMap { tree.node(atPath: $0) }
        selection = selectionPath.flatMap { tree.node(atPath: $0) }
        onRestructure(self)
        treeChanged()
    }

    private func stopLiveWork() {
        scanner?.cancel()
        partialScanner?.cancel()
        partialScanner = nil
        partialTask?.cancel()
        partialTask = nil
        refresher?.stop()
        refresher = nil
        fullRefreshPendingAt = nil
        refreshTask?.cancel()
        refreshTask = nil
        classifyTask?.cancel()
        classifyWalk?.cancel()
        scanTask?.cancel()
    }

    /// Scan roots are resolved (realpath) and then standardized the way ScanKit reports its root
    /// (`/private/var/...` becomes `/var/...`), so tree paths, the home folder and tool paths agree.
    public static func canonicalRoot(_ url: URL) -> String {
        let path = url.path
        guard let resolved = realpath(path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL.path
    }
}

/// Running categorization walks of a session (thread safe; tests read it).
final class WalkStats: Sendable {
    struct Counts: Sendable, Equatable {
        var running = 0
        var maxRunning = 0
        var started = 0
        /// Walks that saw the cancellation and stopped before the end.
        var stoppedEarly = 0
    }

    private let counts = Mutex(Counts())

    var snapshot: Counts { counts.withLock { $0 } }

    func begin() {
        counts.withLock {
            $0.running += 1
            $0.started += 1
            $0.maxRunning = max($0.maxRunning, $0.running)
        }
    }

    func end(stoppedEarly: Bool) {
        counts.withLock {
            $0.running -= 1
            if stoppedEarly { $0.stoppedEarly += 1 }
        }
    }
}

/// Volume numbers for any folder, from URL resource values.
public enum VolumeLookup {
    public static func containing(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey, .volumeIsRemovableKey,
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsEncryptedKey, .volumeSupportsFileCloningKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), let volumeURL = values.volume else { return nil }
        let capacity = UInt64(max(values.volumeTotalCapacity ?? 0, 0))
        let available = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
        let important = UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
        let isNetwork = values.volumeIsLocal == false
        let kind: VolumeKind = isNetwork ? .network : (values.volumeIsInternal == true ? .internalDisk : (values.volumeIsRemovable == true ? .removable : .external))
        return VolumeInfo(
            url: volumeURL,
            name: values.volumeName ?? volumeURL.lastPathComponent,
            kind: kind,
            fsType: "",
            capacity: capacity,
            available: available,
            availableImportant: max(important, available),
            isReadOnly: values.volumeIsReadOnly ?? false,
            isEncrypted: values.volumeIsEncrypted ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isNetwork: isNetwork,
            supportsClones: values.volumeSupportsFileCloning ?? false
        )
    }
}
