import CoreServices
import Darwin
import Foundation
import Synchronization

public enum RefreshEvent: Sendable, Hashable {
    /// Subtrees under these paths were re-enumerated; the tree's generation is now `generation`.
    /// After a full rescan of the root the tree's `structureEpoch` also changes (node ids were
    /// reassigned; resolve them again by path).
    case updated(generation: UInt64, paths: [String])
    /// The root changed or its volume went away; the scan is stale.
    case stale(reason: StaleReason)
    /// A full rescan of the root was swapped in: every node id was reassigned and the tree's
    /// `structureEpoch` is now `epoch`. Resolve held node ids again by path. Followed by an
    /// `.updated` event. Added by WS2.
    case restructured(epoch: UInt64)
    /// A full rescan of the root is waiting for the rate limit and runs at about `at` (or sooner
    /// with `rescanRootNow()`); `nil` once it started. Added after the live-bug fix.
    case fullRescanPending(at: Date?)
}

public enum StaleReason: String, Sendable, Hashable, Codable {
    case rootChanged
    case unmounted
    case eventsDropped
}

/// Keeps a `ScanTree` current with FSEvents (PLAN 2.4, WS2). Frozen contract (PLAN 4.3).
///
/// Directory-level events on the scanned root (latency 1 s, `WatchRoot`, `NoDefer` so the first
/// change of a quiet period arrives at once; replayed from the scan start, so changes made while
/// the scan ran are caught too) go into a dirty set. After 3 s without new events
/// each dirty directory is re-listed one level deep: children are matched by (name, file id),
/// unchanged subtrees are kept, changed files get new sizes, new folders are scanned fully and
/// vanished items are dropped. `MustScanSubDirs` triggers a full rescan of the subtree; dropped
/// events trigger a full rescan of the root, which is swapped in (`ScanTree.structureEpoch`)
/// rather than grafted. `RootChanged` or an unmount marks the scan stale. The scan's
/// `excludedPaths` stay excluded.
///
/// Events are taken in on their own queue, never behind refresh work: a stream that is not read
/// while a long refresh runs makes fseventsd drop events, and each drop asks for a full rescan.
/// Full rescans of the root (or of a subtree holding more than `largeSubtreeNodes` items) run at
/// most once per `minimumRootRescanInterval` (monotonic clock), counted from the scan: requests in
/// between are coalesced into one rescan when the interval is up and announced with
/// `.fullRescanPending(at:)`, while plain changes and smaller rescans keep landing.
/// `rescanRootNow()` skips the wait. A batch runs at the latest `maximumBatchDelay` after its
/// first change, even when events never pause for the idle delay.
///
/// `start()` and `stop()` never wait for refresh work: `stop()` cancels a running rescan and
/// tears the stream down asynchronously. Listings that do not return within the watchdog time
/// flag the folder `notResponding`.
public final class TreeRefresher: @unchecked Sendable {
    public let tree: ScanTree
    public let root: URL
    public let events: AsyncStream<RefreshEvent>
    private let continuation: AsyncStream<RefreshEvent>.Continuation
    let latency: TimeInterval
    let idleDelay: TimeInterval
    /// Watchdog for one shallow listing.
    let listingTimeout: TimeInterval
    /// Test hook, called before each folder is opened by a listing or a rescan.
    let openHook: (@Sendable ([UInt8]) -> Void)?
    /// Refresh work (listings, rescans, tree mutations).
    private let queue = DispatchQueue(label: "com.alexluncan.lightwell.refresh", qos: .utility)
    /// FSEvents delivery and the idle timer. Never runs refresh work, so events are always read.
    private let intake = DispatchQueue(label: "com.alexluncan.lightwell.refresh.intake", qos: .utility)
    private let treeRootPath: String
    private let realRootPath: String
    private let wantClones: Bool
    private let stopped = Atomic<Bool>(false)
    /// The rescan in progress, so `stop()` can cancel it.
    private let currentScan = Mutex<Scanner?>(nil)
    /// Diagnostics sink (scanbench `--refresh-watch`); nil in the app.
    /// Holds the sink as a class reference: a function value stored directly in the generic
    /// `Mutex` was reabstracted on every access and written back wrapped in one more thunk, so
    /// thousands of trace lines built a chain whose release overflowed a thread's stack.
    private final class TraceSink: Sendable {
        let sink: @Sendable (String) -> Void
        init(_ sink: @escaping @Sendable (String) -> Void) { self.sink = sink }
    }
    private let traceSink = Mutex<TraceSink?>(nil)

    /// Installs a diagnostics sink that receives one line per refresh decision (events, batches,
    /// subscans, unmatched children). For tooling only; set it before `start()`.
    public func setTrace(_ sink: (@Sendable (String) -> Void)?) {
        let box = sink.map(TraceSink.init)
        traceSink.withLock { $0 = box }
    }

    func trace(_ line: @autoclosure () -> String) {
        guard let box = traceSink.withLock({ $0 }) else { return }
        box.sink(line())
    }

    /// Paths waiting for the next batch (filled on `intake`, drained on `queue`).
    private struct Pending {
        var dirty = Set<String>()
        var fullRescan = Set<String>()
        /// When the oldest change of this batch arrived (bounds the idle-delay postponement).
        var firstChange: DispatchTime?
    }
    private let pending = Mutex(Pending())

    // Confined to `intake`.
    private var stream: FSEventStreamRef?
    private var idleWork: DispatchWorkItem?

    // Confined to `queue`.
    private var suppressed: [String: Date] = [:]
    /// When the last expensive full rescan started, on `clock` (initially: when the refresher was
    /// made, right after the scan).
    private var lastExpensiveRescan: TimeInterval = 0
    /// A postponed expensive rescan is scheduled.
    private var expensiveRescanScheduled = false
    /// `.fullRescanPending(at:)` with a time was sent and not withdrawn yet.
    private var announcedPending = false
    /// The next batch runs expensive rescans whatever the rate limit says ("Refresh Now").
    private var forceExpensive = false

    public convenience init(tree: ScanTree, root: URL) {
        self.init(tree: tree, root: root, latency: TreeRefresher.defaultLatency, idleDelay: TreeRefresher.defaultIdleDelay)
    }

    /// FSEvents coalescing latency. PLAN 2.4 says 2 s, but a delivery in the previous `latency`
    /// seconds defers the next one by up to `latency`, so with the 3 s idle delay a change could
    /// take latency + 3 s to land. 1 s keeps the worst case under the 5 s acceptance bound.
    static let defaultLatency: TimeInterval = 1
    /// Quiet time before dirty folders are re-listed (PLAN 2.4).
    static let defaultIdleDelay: TimeInterval = 3
    /// Same as the scanner's watchdog.
    static let defaultListingTimeout: TimeInterval = 30
    /// Shortest time between two full rescans of the root (dropped events).
    static let defaultMinimumRootRescanInterval: TimeInterval = 300
    let minimumRootRescanInterval: TimeInterval
    /// Longest time a pending change waits for the idle delay (events that never pause).
    static let defaultMaximumBatchDelay: TimeInterval = 25
    let maximumBatchDelay: TimeInterval
    /// Monotonic seconds (the rate limit must not follow wall-clock changes).
    let clock: @Sendable () -> TimeInterval
    public static let monotonicSeconds: @Sendable () -> TimeInterval = {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
    /// Events taken in so far (tests).
    let handledEvents = Atomic<Int>(0)
    /// A full rescan of a subtree this large is rate limited like one of the root.
    static let defaultLargeSubtreeNodes: UInt32 = 250_000
    let largeSubtreeNodes: UInt32
    /// Batches run so far (tests).
    let processRuns = Atomic<Int>(0)
    /// A batch is queued on `queue` and has not taken the pending set yet: further timers that
    /// fire meanwhile (events after the batch cap) add nothing.
    private let batchQueued = Atomic<Bool>(false)

    init(
        tree: ScanTree, root: URL, latency: TimeInterval, idleDelay: TimeInterval,
        listingTimeout: TimeInterval = TreeRefresher.defaultListingTimeout,
        minimumRootRescanInterval: TimeInterval = TreeRefresher.defaultMinimumRootRescanInterval,
        maximumBatchDelay: TimeInterval = TreeRefresher.defaultMaximumBatchDelay,
        largeSubtreeNodes: UInt32 = TreeRefresher.defaultLargeSubtreeNodes,
        clock: @escaping @Sendable () -> TimeInterval = TreeRefresher.monotonicSeconds,
        openHook: (@Sendable ([UInt8]) -> Void)? = nil
    ) {
        self.minimumRootRescanInterval = minimumRootRescanInterval
        self.maximumBatchDelay = maximumBatchDelay
        self.largeSubtreeNodes = largeSubtreeNodes
        self.clock = clock
        self.lastExpensiveRescan = clock()
        self.tree = tree
        self.root = root
        self.latency = latency
        self.idleDelay = idleDelay
        self.listingTimeout = listingTimeout
        self.openHook = openHook
        (events, continuation) = AsyncStream.makeStream(of: RefreshEvent.self)
        treeRootPath = tree.rootPath
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(tree.rootPath, &resolved) != nil {
            realRootPath = String(decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            realRootPath = tree.rootPath
        }
        let isLocal = VolumeProbe.fileSystem(at: tree.rootPath)?.isLocal ?? true
        wantClones = isLocal && tree.sizeMode == .allocated && VolumeProbe.supportsClones(at: tree.rootPath)
    }

    private var isStopped: Bool { stopped.load(ordering: .acquiring) }

    /// Starts watching. Returns at once; the stream is created on the refresher's queue.
    /// The stream retains the refresher until `stop()`.
    public func start() {
        guard !isStopped else { return }
        intake.async { [self] in
            guard stream == nil, !isStopped else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<TreeRefresher>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<TreeRefresher>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let refresher = Unmanaged<TreeRefresher>.fromOpaque(info).takeUnretainedValue()
                let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                for index in 0..<count {
                    refresher.handle(path: String(cString: cPaths[index]), flags: flags[index])
                }
            }
            // Replay from the scan start when known, so changes made during the scan are seen.
            let since = tree.eventIDAtScanStart > 0
                ? FSEventStreamEventId(tree.eventIDAtScanStart)
                : FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [realRootPath] as CFArray,
                since, latency, createFlags
            ) else { return }
            FSEventStreamSetDispatchQueue(created, intake)
            if FSEventStreamStart(created) {
                stream = created
            } else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
            }
        }
    }

    /// Stops watching. Returns at once: a running rescan is cancelled and the stream is torn
    /// down on the refresher's queue, after which no callback runs.
    public func stop() {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        currentScan.withLock { $0 }?.cancel()
        continuation.finish()
        intake.async { [self] in
            idleWork?.cancel()
            idleWork = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    /// Ignores changes at or below `paths` for `seconds` (items our own executor is deleting;
    /// the tree was already updated with `removeSubtree`). Added by WS2.
    public func suppress(_ paths: [String], for seconds: TimeInterval = 10) {
        let until = Date().addingTimeInterval(seconds)
        queue.async { [self] in
            for path in paths { suppressed[normalize(path)] = until }
        }
    }

    // MARK: Event intake (on `intake`)

    func handle(path rawPath: String, flags: FSEventStreamEventFlags) {
        guard !isStopped else { return }
        handledEvents.wrappingAdd(1, ordering: .acquiringAndReleasing)
        let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let unmount = FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)
        let ignored = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & rootChanged != 0 {
            continuation.yield(.stale(reason: .rootChanged))
            return
        }
        if flags & unmount != 0 {
            continuation.yield(.stale(reason: .unmounted))
            return
        }
        trace("event flags=0x\(String(flags, radix: 16)) path=\(rawPath)")
        if flags & ignored != 0 && flags & ~ignored == 0 { return }
        let now = DispatchTime.now()
        if flags & dropped != 0 {
            let root = treeRootPath
            pending.withLock {
                $0.fullRescan.insert(root)
                if $0.firstChange == nil { $0.firstChange = now }
            }
        } else if let path = mapToTree(rawPath) {
            let deep = flags & mustScan != 0
            pending.withLock {
                if deep { $0.fullRescan.insert(path) } else { $0.dirty.insert(path) }
                if $0.firstChange == nil { $0.firstChange = now }
            }
        } else {
            return
        }
        scheduleProcessing()
    }

    /// Restarts the idle timer (on `intake`). When it fires, the batch runs on `queue`. The timer
    /// never goes past `maximumBatchDelay` after the batch's first change, so events that never
    /// pause can not postpone the batch forever.
    private func scheduleProcessing() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // One queued batch takes everything pending; do not queue another behind it.
            guard !self.batchQueued.exchange(true, ordering: .acquiringAndReleasing) else { return }
            self.queue.async { [weak self] in self?.process() }
        }
        idleWork = work
        var deadline = DispatchTime.now() + idleDelay
        if let first = pending.withLock({ $0.firstChange }) {
            deadline = min(deadline, first + maximumBatchDelay)
        }
        intake.asyncAfter(deadline: deadline, execute: work)
    }

    /// Feeds a dropped-events notice, as fseventsd sends when it could not deliver everything
    /// (UI test mode and the scanbench harness).
    public func injectDroppedEvents() {
        simulate(path: realRootPath, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs))
    }

    /// Runs a full rescan of the root now, whatever the rate limit says ("Refresh Now").
    public func rescanRootNow() {
        let root = treeRootPath
        queue.async { [self] in
            pending.withLock { _ = $0.fullRescan.insert(root) }
            forceExpensive = true
            process()
        }
    }

    /// Test hook: feeds a synthetic event (for example `MustScanSubDirs`).
    func simulate(path: String, flags: FSEventStreamEventFlags) {
        intake.async { [self] in handle(path: path, flags: flags) }
    }

    /// Test hook: processes pending changes now instead of waiting for the idle delay.
    func processNow() {
        intake.sync {
            idleWork?.cancel()
            idleWork = nil
        }
        queue.sync { process() }
    }

    private func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Maps an FSEvents path (real path) to the tree's path space; `nil` when outside the root.
    private func mapToTree(_ eventPath: String) -> String? {
        let path = normalize(eventPath)
        func under(_ base: String) -> String? {
            if path == base { return "" }
            let prefix = base == "/" ? "/" : base + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        let join: (String) -> String = { rest in
            rest.isEmpty ? self.treeRootPath : (self.treeRootPath == "/" ? "/" + rest : self.treeRootPath + "/" + rest)
        }
        if let rest = under(realRootPath) { return join(rest) }
        if let rest = under(treeRootPath) { return join(rest) }
        return nil
    }

    // MARK: Processing (on `queue`)

    private func isUnder(_ path: String, _ base: String) -> Bool {
        path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    private func isSuppressed(_ path: String) -> Bool {
        let now = Date()
        suppressed = suppressed.filter { $0.value > now }
        return suppressed.keys.contains { isUnder(path, $0) }
    }

    /// At or below one of the scan's excluded paths.
    private func isExcluded(_ path: String) -> Bool {
        guard !tree.excludedPaths.isEmpty else { return false }
        return tree.excludedPaths.contains { isUnder(path, String(decoding: $0, as: UTF8.self)) }
    }

    /// Paths with no ancestor in the same set.
    private func minimal(_ paths: Set<String>) -> [String] {
        let sorted = paths.sorted()
        var result: [String] = []
        for path in sorted {
            if let last = result.last, isUnder(path, last) { continue }
            result.append(path)
        }
        return result
    }

    private func process() {
        guard !isStopped else { return }
        processRuns.wrappingAdd(1, ordering: .acquiringAndReleasing)
        // Changes arriving from now on need a batch of their own.
        batchQueued.store(false, ordering: .releasing)
        let taken = pending.withLock { current -> Pending in
            defer { current = Pending() }
            return current
        }
        var candidates = Set(taken.fullRescan.filter { !isSuppressed($0) && !isExcluded($0) })
        // Expensive full rescans (the root, huge subtrees) wait for the rate limit; they are kept
        // pending and coalesced, and run by themselves once the interval is up. Smaller rescans
        // below them run now (the later big rescan simply redoes them).
        let expensive = candidates.filter(isExpensiveRescan).sorted()
        let force = forceExpensive
        forceExpensive = false
        if !expensive.isEmpty {
            let now = clock()
            let readyAt = lastExpensiveRescan + minimumRootRescanInterval
            if now < readyAt && !force {
                candidates.subtract(expensive)
                pending.withLock { $0.fullRescan.formUnion(expensive) }
                trace("postponed full rescan of \(expensive) for \(String(format: "%.1f", readyAt - now)) s")
                schedulePostponedRescan(after: readyAt - now)
                if !announcedPending {
                    announcedPending = true
                    continuation.yield(.fullRescanPending(at: Date().addingTimeInterval(readyAt - now)))
                }
            } else {
                lastExpensiveRescan = now
                if announcedPending {
                    announcedPending = false
                    continuation.yield(.fullRescanPending(at: nil))
                }
            }
        }
        let full = minimal(candidates)
        // A shallow refresh covers one level only, so nested dirty folders are all kept.
        let shallow = taken.dirty.filter { !isSuppressed($0) && !isExcluded($0) }.sorted().filter { path in
            !full.contains { isUnder(path, $0) }
        }
        guard !full.isEmpty || !shallow.isEmpty else { return }
        trace("batch full=\(full) shallow=\(shallow.count) \(shallow.prefix(8))")
        let before = tree.generation
        var touched: [String] = []
        var refreshedIDs = Set<NodeID>()
        for path in full where !isStopped {
            if let refreshed = refresh(path: path, deep: true, done: &refreshedIDs) { touched.append(refreshed) }
        }
        for path in shallow where !isStopped {
            if let refreshed = refresh(path: path, deep: false, done: &refreshedIDs) { touched.append(refreshed) }
        }
        let after = tree.generation
        trace("batch done generation \(before)->\(after) epoch=\(tree.structureEpoch) touched=\(touched.count)")
        if after != before && !isStopped {
            continuation.yield(.updated(generation: after, paths: touched))
        }
    }

    /// A full rescan of `path` is expensive: the root, or a subtree with very many items.
    private func isExpensiveRescan(_ path: String) -> Bool {
        if path == treeRootPath { return true }
        guard let id = tree.node(atPath: path) else { return false }
        return tree.descendantCount(id) > largeSubtreeNodes
    }

    /// Runs the batch again when the rate limit allows the postponed full rescan (on `queue`).
    private func schedulePostponedRescan(after seconds: TimeInterval) {
        guard !expensiveRescanScheduled else { return }
        expensiveRescanScheduled = true
        let delay = max(0, seconds) + 0.05
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.expensiveRescanScheduled = false
            self.process()
        }
    }

    private func isInDataVolume(_ path: String) -> Bool {
        guard tree.dataVolumePath != nil else { return false }
        let data = VolumeProbe.dataVolumePath
        return path == data || path.hasPrefix(data + "/")
    }

    /// Finds the node for `path`, or its nearest existing directory ancestor.
    private func nearestNode(_ path: String) -> (NodeID, String)? {
        var candidate = path
        while true {
            if let id = tree.node(atPath: candidate) {
                let flags = tree.flags(id)
                if flags.contains(.directory) && (flags.contains(.mountPoint) || flags.contains(.firmlinkSkipped)) {
                    // Events behind a boundary belong to another part of the walk (or volume).
                    if flags.contains(.firmlinkSkipped), isInDataVolume(path) {
                        let natural = String(path.dropFirst(VolumeProbe.dataVolumePath.count))
                        if !natural.isEmpty, natural != path { return nearestNode(natural) }
                    }
                    return nil
                }
                if flags.contains(.directory) { return (id, candidate) }
            }
            if candidate == treeRootPath || candidate == "/" || candidate.isEmpty { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate.count < treeRootPath.count { return nil }
        }
    }

    /// Refreshes one directory (shallow listing, or a full rescan when `deep`). Returns the path
    /// that was refreshed.
    private func refresh(path: String, deep: Bool, done: inout Set<NodeID>) -> String? {
        guard let (id, nodePath) = nearestNode(path) else { return nil }
        let exact = nodePath == path
        guard !done.contains(id) else { return nil }
        done.insert(id)
        if deep { trace("deep path=\(path) node=\(nodePath) exact=\(exact) root=\(id == tree.root)") }
        if deep && exact {
            switch subscan(nodePath) {
            case .success(let subtree):
                if id == tree.root {
                    // A full rescan of the root replaces the tree's storage instead of growing it.
                    tree.adopt(subtree)
                    continuation.yield(.restructured(epoch: tree.structureEpoch))
                } else {
                    tree.replaceChildren(of: id, with: subtree)
                }
                return nodePath
            case .failure(.cancelled):
                return nil
            case .failure(.rootNotFound):
                if id == tree.root {
                    continuation.yield(.stale(reason: .rootChanged))
                    return nil
                }
                return refreshParent(of: id, done: &done)
            case .failure(.notResponding):
                tree.markNotResponding(id)
                return nodePath
            case .failure:
                tree.applyShallowRefresh(of: id, listing: [], names: [], subtrees: [:], restricted: true, inDataVolume: isInDataVolume(nodePath))
                return nodePath
            }
        }
        return shallowRefresh(id, path: nodePath, done: &done)
    }

    private func refreshParent(of id: NodeID, done: inout Set<NodeID>) -> String? {
        guard let parent = tree.parent(id) else { return nil }
        let parentPath = tree.path(parent)
        guard !done.contains(parent) else { return nil }
        done.insert(parent)
        return shallowRefresh(parent, path: parentPath, done: &done)
    }

    private enum Listing {
        case listed(entries: [ListedEntry], names: [UInt8], error: Int32)
        case openFailed(errno: Int32)
        case timedOut
        case stopped
    }

    /// Result slot shared with the listing thread.
    private final class ListingBox: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Listing?
        func set(_ listing: Listing) {
            lock.withLock { value = listing }
            done.signal()
        }
        func get() -> Listing? { lock.withLock { value } }
    }

    /// Lists one folder on a helper thread with a watchdog: a listing stuck in the kernel (hung
    /// share, privacy prompt) is given up after `listingTimeout`, and `stop()` is noticed at once.
    private func list(_ pathBytes: [UInt8], followFinal: Bool) -> Listing {
        let box = ListingBox()
        let lister = BulkLister(wantClones: wantClones)
        let hook = openHook
        let thread = Thread { [self] in
            hook?(pathBytes)
            let fd = openDirectory(pathBytes, followFinal: followFinal)
            guard fd >= 0 else {
                box.set(.openFailed(errno: errno))
                return
            }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BulkLister.bufferSize, alignment: 16)
            defer { buffer.deallocate() }
            var entries: [ListedEntry] = []
            var names: [UInt8] = []
            let error = lister.list(fd: fd, buffer: buffer, entries: &entries, names: &names) { !self.isStopped }
            close(fd)
            box.set(.listed(entries: entries, names: names, error: error))
        }
        thread.qualityOfService = .utility
        thread.start()
        let deadline = Date().addingTimeInterval(listingTimeout)
        while true {
            if box.done.wait(timeout: .now() + .milliseconds(20)) == .success, let result = box.get() { return result }
            if isStopped { return .stopped }
            if Date() >= deadline { return .timedOut }
        }
    }

    private func shallowRefresh(_ id: NodeID, path: String, done: inout Set<NodeID>) -> String? {
        let listing = list(Array(path.utf8), followFinal: id == tree.root)
        let entries: [ListedEntry]
        let names: [UInt8]
        let error: Int32
        switch listing {
        case .stopped:
            return nil
        case .timedOut:
            tree.markNotResponding(id)
            return path
        case .openFailed(let code):
            if code == EACCES || code == EPERM {
                tree.applyShallowRefresh(of: id, listing: [], names: [], subtrees: [:], restricted: true, inDataVolume: isInDataVolume(path))
                return path
            }
            if id == tree.root {
                continuation.yield(.stale(reason: .rootChanged))
                return nil
            }
            return refreshParent(of: id, done: &done)
        case .listed(let listed, let listedNames, let code):
            entries = withoutExcluded(listed, names: listedNames, parent: path)
            names = listedNames
            error = code
        }
        var subtrees: [Int: ScanTree] = [:]
        let unmatched = tree.unmatchedDirectories(of: id, listing: entries, names: names)
        trace("shallow path=\(path) listed=\(entries.count) unmatchedDirs=\(unmatched.count)")
        for index in unmatched {
            guard !isStopped else { return nil }
            let entry = entries[index]
            let name = String(decoding: names[entry.nameStart..<(entry.nameStart + entry.nameLength)], as: UTF8.self)
            let childPath = path == "/" ? "/" + name : path + "/" + name
            if case .success(let subtree) = subscan(childPath) { subtrees[index] = subtree }
        }
        guard !isStopped else { return nil }
        tree.applyShallowRefresh(
            of: id, listing: entries, names: names, subtrees: subtrees,
            restricted: error == EACCES || error == EPERM, inDataVolume: isInDataVolume(path)
        )
        return path
    }

    /// Drops listing entries whose path is one of the scan's excluded paths.
    private func withoutExcluded(_ entries: [ListedEntry], names: [UInt8], parent: String) -> [ListedEntry] {
        guard !tree.excludedPaths.isEmpty else { return entries }
        var prefix = Array(parent.utf8)
        if !(prefix.count == 1 && prefix[0] == 0x2F) { prefix.append(0x2F) }
        return entries.filter { entry in
            !tree.excludedPaths.contains(prefix + names[entry.nameStart..<(entry.nameStart + entry.nameLength)])
        }
    }

    /// Full scan of one directory with the tree's settings (exclusions included). Cancelled by
    /// `stop()`.
    private func subscan(_ path: String) -> Result<ScanTree, ScanError> {
        let options = ScanOptions(
            root: URL(fileURLWithPath: path, isDirectory: true), workers: 8,
            sizeMode: tree.sizeMode, countClonesOnce: tree.countClonesOnce,
            excludedPaths: tree.excludedPaths.map { String(decoding: $0, as: UTF8.self) }
        )
        switch EngineConfig.resolve(options) {
        case .failure(let error):
            return .failure(error)
        case .success(var config):
            config.objectCount = nil
            config.beforeOpen = openHook
            config.watchdogTimeout = .milliseconds(Int64(listingTimeout * 1000))
            if tree.dataVolumePath != nil {
                config.firmlinkSkip = tree.firmlinkSkip
                config.dataVolumePath = tree.dataVolumePath
                config.rootInDataVolume = isInDataVolume(path)
            }
            let scanner = Scanner(options)
            currentScan.withLock { $0 = scanner }
            defer { currentScan.withLock { $0 = nil } }
            if isStopped { return .failure(.cancelled) }
            let started = Date()
            let result = scanner.run(config: config)
            trace({
                let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                switch result {
                case .success(let subtree): return "subscan path=\(path) seconds=\(seconds) nodes=\(subtree.statistics().nodes)"
                case .failure(let error): return "subscan path=\(path) seconds=\(seconds) failed=\(error)"
                }
            }())
            return result
        }
    }
}
