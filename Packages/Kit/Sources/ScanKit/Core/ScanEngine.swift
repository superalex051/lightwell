import CoreServices
import Darwin
import Foundation
import Synchronization

/// Resolved settings for one scan.
struct EngineConfig: Sendable {
    var rootPath: String
    var rootBytes: [UInt8]
    var rootDevice: Int32
    var rootInode: UInt64
    var workers: Int
    var sizeMode: SizeMode
    var countClonesOnce: Bool
    var wantClones: Bool
    var excluded: Set<[UInt8]>
    /// Firmlink targets to skip inside the Data volume (scans of `/`).
    var firmlinkSkip: Set<FileIdentity>
    /// Mount point that is entered instead of being a leaf (`/System/Volumes/Data` for `/`).
    var dataVolumePath: [UInt8]?
    /// The root itself lies inside the Data volume walk (refreshes of a `/` scan).
    var rootInDataVolume: Bool
    /// Total objects for absolute progress, when known.
    var objectCount: UInt64?
    /// No progress for this long: stuck folders are given up (flagged `notResponding`) so the
    /// scan can finish; if nothing was scanned at all the scan fails with `notResponding`.
    var watchdogTimeout: Duration
    /// Test hook, called before each directory is opened.
    var beforeOpen: (@Sendable ([UInt8]) -> Void)?

    /// Default worker count (PLAN 2.4): 32 on SSD, 4 on rotational or network volumes.
    static let ssdWorkers = 32
    static let slowWorkers = 4

    static func resolve(_ options: ScanOptions) -> Result<EngineConfig, ScanError> {
        var path = options.root.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            return .failure(code == ENOENT || code == ENOTDIR ? .rootNotFound(path: path) : .rootNotReadable(path: path, errno: code))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return .failure(.rootNotReadable(path: path, errno: ENOTDIR))
        }
        let fileSystem = VolumeProbe.fileSystem(at: path)
        let isLocal = fileSystem?.isLocal ?? true
        let sizeMode = options.sizeMode ?? (isLocal ? .allocated : .logical)
        let workers: Int
        if let requested = options.workers {
            workers = max(1, min(requested, 256))
        } else if !isLocal {
            workers = slowWorkers
        } else if let device = fileSystem?.deviceName, VolumeProbe.isSolidState(deviceName: device) == false {
            workers = slowWorkers
        } else {
            workers = ssdWorkers
        }
        // Clone math uses allocated bytes, so it is off in logical size mode.
        let wantClones = isLocal && sizeMode == .allocated && VolumeProbe.supportsClones(at: path)
        var firmlinkSkip = Set<FileIdentity>()
        var dataVolume: [UInt8]?
        if path == "/" {
            firmlinkSkip = Firmlinks.skipSet()
            if VolumeProbe.fileSystem(at: VolumeProbe.dataVolumePath)?.mountPoint == VolumeProbe.dataVolumePath {
                dataVolume = Array(VolumeProbe.dataVolumePath.utf8)
            }
        }
        var objectCount: UInt64?
        if let fileSystem, fileSystem.mountPoint == path, let count = fileSystem.objectsInUse, count > 0 {
            objectCount = count
            if dataVolume != nil, let data = VolumeProbe.fileSystem(at: VolumeProbe.dataVolumePath)?.objectsInUse {
                objectCount = count + data
            }
        }
        let excluded = Set(options.excludedPaths.map { raw -> [UInt8] in
            var item = raw
            while item.count > 1 && item.hasSuffix("/") { item.removeLast() }
            return Array(item.utf8)
        })
        return .success(EngineConfig(
            rootPath: path,
            rootBytes: Array(path.utf8),
            rootDevice: info.st_dev,
            rootInode: UInt64(info.st_ino),
            workers: workers,
            sizeMode: sizeMode,
            countClonesOnce: options.countClonesOnce,
            wantClones: wantClones,
            excluded: excluded,
            firmlinkSkip: firmlinkSkip,
            dataVolumePath: dataVolume,
            rootInDataVolume: false,
            objectCount: objectCount,
            watchdogTimeout: .seconds(30),
            beforeOpen: nil
        ))
    }
}

/// One directory waiting to be enumerated.
final class DirTask: @unchecked Sendable {
    let node: NodeID
    let parent: DirTask?
    let path: [UInt8]
    let share: Double
    let inDataVolume: Bool
    /// Device of this directory; children on another device are recorded as exceptions.
    let device: Int32
    /// Child directories not yet complete.
    let pending = Atomic<Int>(0)
    /// `unclaimed`, then `claimed` by the worker that commits it or `abandoned` by the watchdog.
    let claim = Atomic<UInt8>(DirTask.unclaimed)
    static let unclaimed: UInt8 = 0
    static let claimed: UInt8 = 1
    static let abandoned: UInt8 = 2

    init(node: NodeID, parent: DirTask?, path: [UInt8], share: Double, inDataVolume: Bool, device: Int32) {
        self.node = node
        self.parent = parent
        self.path = path
        self.share = share
        self.inDataVolume = inDataVolume
        self.device = device
    }
}

/// Per-thread scratch and results.
final class WorkerState: @unchecked Sendable {
    let buffer: UnsafeMutableRawBufferPointer
    var entries: [ListedEntry] = []
    var names: [UInt8] = []
    var nameWriter = NameWriter()
    var hardLinks: [HardLinkRecord] = []
    var deviceExceptions: [(NodeID, Int32)] = []
    var sortScratch: [UInt32] = []
    var keep: [Bool] = []
    let currentPath = Mutex<[UInt8]>([])
    /// Task being processed (read by the watchdog).
    let inFlight = Mutex<DirTask?>(nil)
    /// Set when the watchdog gave up on this worker's task; its thread exits when it returns.
    let retired = Atomic<Bool>(false)
    /// Ensures the worker leaves the dispatch group exactly once.
    let leftGroup = Atomic<Bool>(false)

    init() {
        buffer = .allocate(byteCount: BulkLister.bufferSize, alignment: 16)
    }

    deinit { buffer.deallocate() }
}

/// The multi-threaded scan (PLAN 2.4): a fixed pool of OS threads sharing a LIFO stack of
/// directory tasks. Each worker continues depth-first with one child and pushes the rest.
/// A directory is finalized (sizes summed, children sorted) when its last child completes,
/// so there is no second pass. Cancellation is checked per batch.
final class ScanEngine: @unchecked Sendable {
    let config: EngineConfig
    let arena = Arena()
    /// Clone facts from all workers (lazily mapped, dropped after the tree is built).
    private var cloneRecords = ChunkedBuffer<CloneRecord>(chunkShift: 18, maxChunks: 16_384)
    private let lister: BulkLister
    private let condition = NSCondition()
    private var stack: [DirTask] = []
    private var idle = 0
    private var done = false
    private let cancelled = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private let workerGroup = DispatchGroup()
    private var workers: [WorkerState] = []
    let itemsScanned = Atomic<UInt64>(0)
    let bytesScanned = Atomic<UInt64>(0)
    /// Relative progress in units of 2^-40.
    private let progressUnits = Atomic<UInt64>(0)
    private let lastActivity = Atomic<UInt64>(0)
    private static let progressScale = Double(1 << 40)
    private var startEventID: UInt64 = 0
    /// Folders the watchdog gave up on (coordinator thread only).
    private var abandoned: [NodeID] = []

    init(config: EngineConfig) {
        self.config = config
        lister = BulkLister(wantClones: config.wantClones)
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        condition.lock()
        condition.broadcast()
        condition.unlock()
        finished.signal()
    }

    @inline(__always)
    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @inline(__always)
    private func heartbeat() { lastActivity.store(Self.now(), ordering: .relaxed) }

    /// Runs the scan on the calling thread (which coordinates while workers walk).
    /// `progress` is called at most 10 times per second.
    func run(progress: ((ScanProgress) -> Void)? = nil) -> Result<ScanTree, ScanError> {
        startEventID = FSEventsGetCurrentEventId()
        // The root must be readable before workers start.
        let probe = openDirectory(config.rootBytes, followFinal: true)
        guard probe >= 0 else { return .failure(.rootNotReadable(path: config.rootPath, errno: errno)) }
        close(probe)

        var rootWriter = NameWriter()
        ScanTree.writeRoot(into: arena, path: config.rootPath, inode: config.rootInode, writer: &rootWriter)
        let rootTask = DirTask(
            node: 0, parent: nil, path: config.rootBytes, share: 1, inDataVolume: config.rootInDataVolume, device: config.rootDevice
        )
        stack = [rootTask]
        heartbeat()

        let count = max(1, config.workers)
        workers = (0..<count).map { _ in WorkerState() }
        workers[0].nameWriter = rootWriter
        for worker in workers { startWorker(worker) }

        var lastFraction = 0.0
        var lastReport = Self.now()
        var watchedPathIndex = 0
        let timeoutNanos = UInt64(config.watchdogTimeout.components.seconds) * 1_000_000_000
            + UInt64(config.watchdogTimeout.components.attoseconds / 1_000_000_000)
        while true {
            let result = finished.wait(timeout: .now() + .milliseconds(50))
            if isCancelled { return .failure(.cancelled) }
            if result == .success { break }
            let now = Self.now()
            if now &- lastActivity.load(ordering: .relaxed) > timeoutNanos {
                if itemsScanned.load(ordering: .relaxed) == 0 {
                    let path = currentPath(&watchedPathIndex)
                    cancel()
                    return .failure(.notResponding(path: path))
                }
                abandonStuckTasks()
                heartbeat()
                continue
            }
            if let progress, now &- lastReport >= 100_000_000 {
                lastReport = now
                lastFraction = max(lastFraction, fraction())
                progress(ScanProgress(
                    fraction: lastFraction,
                    itemsScanned: itemsScanned.load(ordering: .relaxed),
                    bytesScanned: bytesScanned.load(ordering: .relaxed),
                    currentPath: currentPath(&watchedPathIndex),
                    unresponsiveFolders: abandoned.count
                ))
            }
        }
        workerGroup.wait()
        if isCancelled { return .failure(.cancelled) }
        return .success(makeTree())
    }

    private func startWorker(_ worker: WorkerState) {
        workerGroup.enter()
        let thread = Thread { [self] in
            workerLoop(worker)
            leaveGroup(worker)
        }
        thread.stackSize = 1 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func leaveGroup(_ worker: WorkerState) {
        if worker.leftGroup.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            workerGroup.leave()
        }
    }

    /// Watchdog: gives up on folders whose listing has not returned (for example a privacy
    /// prompt or a hung network share). They are flagged `notResponding` with no children, their
    /// worker is replaced and the walk goes on. A late return of the stuck call is discarded.
    /// The tree lists them in `ScanTree.unresponsiveNodes`.
    private func abandonStuckTasks() {
        var scratch: [UInt32] = []
        for worker in workers where !worker.retired.load(ordering: .acquiring) {
            guard let task = worker.inFlight.withLock({ $0 }) else { continue }
            guard task.claim.compareExchange(expected: DirTask.unclaimed, desired: DirTask.abandoned, ordering: .acquiringAndReleasing).exchanged
            else { continue }
            worker.retired.store(true, ordering: .releasing)
            arena.nodes[Int(task.node)].flags |= NodeFlags.notResponding.rawValue
            abandoned.append(task.node)
            let replacement = WorkerState()
            workers.append(replacement)
            startWorker(replacement)
            leaveGroup(worker)
            addProgress(task.share)
            complete(task, scratch: &scratch)
        }
    }

    private func fraction() -> Double {
        if let total = config.objectCount, total > 0 {
            return min(0.99, Double(itemsScanned.load(ordering: .relaxed)) / Double(total))
        }
        return min(0.99, Double(progressUnits.load(ordering: .relaxed)) / Self.progressScale)
    }

    private func currentPath(_ index: inout Int) -> String {
        guard !workers.isEmpty else { return config.rootPath }
        for _ in 0..<workers.count {
            index = (index + 1) % workers.count
            let bytes = workers[index].currentPath.withLock { $0 }
            if !bytes.isEmpty { return String(decoding: bytes, as: UTF8.self) }
        }
        return config.rootPath
    }

    private func makeTree() -> ScanTree {
        let tree = ScanTree(
            arena: arena,
            rootPath: config.rootPath,
            rootDevice: config.rootDevice,
            sizeMode: config.sizeMode,
            countClonesOnce: config.countClonesOnce,
            firmlinkSkip: config.firmlinkSkip,
            dataVolumePath: config.dataVolumePath,
            excludedPaths: config.excluded
        )
        tree.unresponsiveNodes = abandoned
        var hardLinks: [HardLinkRecord] = []
        var exceptions: [(NodeID, Int32)] = []
        for worker in workers {
            worker.nameWriter.flush(into: arena)
            worker.nameWriter.dropCache()
            hardLinks.append(contentsOf: worker.hardLinks)
            exceptions.append(contentsOf: worker.deviceExceptions)
            worker.hardLinks = []
            // A retired worker's thread may still be stuck inside a listing that writes its
            // scratch buffers; leave those alone.
            if !worker.retired.load(ordering: .acquiring) {
                worker.entries = []
                worker.names = []
                worker.sortScratch = []
            }
        }
        workers = []
        // Hand freed scan scratch back to the system before the side tables are built.
        malloc_zone_pressure_relief(nil, 0)
        tree.eventIDAtScanStart = startEventID
        tree.installSharing(hardLinkRecords: hardLinks, cloneRecords: cloneRecords, deviceExceptions: exceptions)
        cloneRecords = ChunkedBuffer<CloneRecord>(chunkShift: 0, maxChunks: 1)
        malloc_zone_pressure_relief(nil, 0)
        return tree
    }

    // MARK: Workers

    private func workerLoop(_ worker: WorkerState) {
        var held: DirTask?
        while !isCancelled && !worker.retired.load(ordering: .acquiring) {
            let task: DirTask
            if let next = held {
                task = next
                held = nil
            } else if let next = pop() {
                task = next
            } else {
                break
            }
            var children = process(task, worker)
            if worker.retired.load(ordering: .acquiring) {
                if !children.isEmpty { push(children) }
                break
            }
            if !children.isEmpty {
                held = children.removeLast()
                if !children.isEmpty { push(children) }
            }
        }
        worker.currentPath.withLock { $0 = [] }
    }

    private func pop() -> DirTask? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && !done && !isCancelled {
            idle += 1
            condition.wait()
            idle -= 1
        }
        if isCancelled || stack.isEmpty { return nil }
        return stack.removeLast()
    }

    private func push(_ tasks: [DirTask]) {
        condition.lock()
        stack.append(contentsOf: tasks.reversed())
        if idle > 0 {
            if tasks.count >= idle {
                condition.broadcast()
            } else {
                for _ in 0..<tasks.count { condition.signal() }
            }
        }
        condition.unlock()
    }

    private func markDone() {
        condition.lock()
        done = true
        condition.broadcast()
        condition.unlock()
        finished.signal()
    }

    /// Enumerates one directory, commits its entries to the arena and returns child tasks.
    private func process(_ task: DirTask, _ worker: WorkerState) -> [DirTask] {
        heartbeat()
        worker.currentPath.withLock { $0 = task.path }
        worker.inFlight.withLock { $0 = task }
        defer { worker.inFlight.withLock { $0 = nil } }
        config.beforeOpen?(task.path)
        let fd = openDirectory(task.path, followFinal: task.parent == nil)
        if fd < 0 {
            let code = errno
            guard claim(task) else { return [] }
            if code == EACCES || code == EPERM {
                arena.nodes[Int(task.node)].flags |= NodeFlags.restricted.rawValue
            }
            addProgress(task.share)
            complete(task, scratch: &worker.sortScratch)
            return []
        }
        // Keep scratch capacity for typical folders, release it after very large ones.
        if worker.entries.capacity > 4096 { worker.entries = [] } else { worker.entries.removeAll(keepingCapacity: true) }
        if worker.names.capacity > 256 * 1024 { worker.names = [] } else { worker.names.removeAll(keepingCapacity: true) }
        let listError = lister.list(fd: fd, buffer: worker.buffer, entries: &worker.entries, names: &worker.names) {
            heartbeat()
            return !isCancelled && task.claim.load(ordering: .relaxed) == DirTask.unclaimed
        }
        close(fd)
        if isCancelled { return [] }
        // The watchdog may have given up on this folder while the call was stuck.
        guard claim(task) else { return [] }
        if listError == EACCES || listError == EPERM {
            arena.nodes[Int(task.node)].flags |= NodeFlags.restricted.rawValue
        }
        return commit(task, worker)
    }

    private func childPath(_ parent: [UInt8], _ name: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var path = parent
        path.reserveCapacity(parent.count + name.count + 1)
        if !(parent.count == 1 && parent[0] == 0x2F) { path.append(0x2F) }
        path.append(contentsOf: name)
        return path
    }

    private func commit(_ task: DirTask, _ worker: WorkerState) -> [DirTask] {
        let entryCount = worker.entries.count
        // Exclusions are rare: only build per-entry paths when there are any.
        worker.keep.removeAll(keepingCapacity: true)
        var keptCount = entryCount
        if !config.excluded.isEmpty {
            worker.names.withUnsafeBufferPointer { names in
                for entry in worker.entries {
                    let name = UnsafeBufferPointer(rebasing: names[entry.nameStart..<(entry.nameStart + entry.nameLength)])
                    let excluded = config.excluded.contains(childPath(task.path, name))
                    worker.keep.append(!excluded)
                    if excluded { keptCount -= 1 }
                }
            }
        }
        guard keptCount > 0 else {
            addProgress(task.share)
            complete(task, scratch: &worker.sortScratch)
            return []
        }

        let base = arena.reserveNodes(keptCount)
        let indexBase = arena.childIndex.reserve(keptCount)
        var childSpecs: [(NodeID, [UInt8], Bool, Int32)] = []
        var fileBytes: UInt64 = 0
        var slot = 0
        let sizeMode = config.sizeMode
        let parentDevice = task.device
        worker.names.withUnsafeBufferPointer { names in
            for (index, entry) in worker.entries.enumerated() {
                if !worker.keep.isEmpty && !worker.keep[index] { continue }
                let id = NodeID(base + slot)
                let name = UnsafeBufferPointer(rebasing: names[entry.nameStart..<(entry.nameStart + entry.nameLength)])
                let nameRef = worker.nameWriter.write(UnsafeRawBufferPointer(name), into: arena.names)
                var flags: UInt16 = 0
                var size: UInt64 = 0
                if entry.error != 0 {
                    // The entry's attributes could not be read: keep it, empty, as restricted.
                    flags |= NodeFlags.restricted.rawValue
                    if entry.isDirectory { flags |= NodeFlags.directory.rawValue }
                } else if entry.isDirectory {
                    flags |= NodeFlags.directory.rawValue
                    if isPackageName(ArraySlice(name)) { flags |= NodeFlags.package.rawValue }
                    let path = childPath(task.path, name)
                    let isDataVolume = config.dataVolumePath.map { $0 == path } ?? false
                    if entry.isMountBoundary && !isDataVolume {
                        flags |= NodeFlags.mountPoint.rawValue
                    } else if task.inDataVolume && !config.firmlinkSkip.isEmpty
                                && config.firmlinkSkip.contains(FileIdentity(device: entry.device, inode: entry.fileID)) {
                        flags |= NodeFlags.firmlinkSkipped.rawValue
                    } else {
                        childSpecs.append((id, path, task.inDataVolume || isDataVolume, entry.device))
                    }
                } else {
                    if entry.isSymlink { flags |= NodeFlags.symlink.rawValue }
                    size = entry.size(sizeMode)
                    fileBytes &+= size
                    if entry.linkCount > 1 {
                        flags |= NodeFlags.hardLink.rawValue
                        worker.hardLinks.append(HardLinkRecord(
                            identity: FileIdentity(device: entry.device, inode: entry.fileID),
                            node: id, linkCount: entry.linkCount, alloc: size
                        ))
                    }
                    let shared = entry.sharedBytes
                    if shared > 0 {
                        flags |= NodeFlags.cloned.rawValue
                        let slot = cloneRecords.reserve(1)
                        cloneRecords[slot] = CloneRecord(
                            cloneID: entry.cloneID, privateBytes: entry.privateSize, node: id, device: entry.device
                        )
                    }
                }
                // Devices are inherited from the parent; only changes are recorded.
                if entry.device != parentDevice && entry.error == 0 { worker.deviceExceptions.append((id, entry.device)) }
                flags |= arena.storeInode(id, entry.fileID)
                arena.nodes[Int(id)] = Node(
                    size: size, parent: task.node, firstChild: 0, childCount: 0, nameRef: nameRef,
                    descendants: 0, nameLength: UInt16(min(name.count, Int(UInt16.max))), flags: flags
                )
                arena.childIndex[indexBase + slot] = id
                slot += 1
            }
        }
        var parentNode = arena.nodes[Int(task.node)]
        parentNode.firstChild = UInt32(indexBase)
        parentNode.childCount = UInt32(keptCount)
        arena.nodes[Int(task.node)] = parentNode
        itemsScanned.wrappingAdd(UInt64(keptCount), ordering: .relaxed)
        bytesScanned.wrappingAdd(fileBytes, ordering: .relaxed)

        if childSpecs.isEmpty {
            addProgress(task.share)
            complete(task, scratch: &worker.sortScratch)
            return []
        }
        let share = task.share / Double(childSpecs.count)
        let children = childSpecs.map {
            DirTask(node: $0.0, parent: task, path: $0.1, share: share, inDataVolume: $0.2, device: $0.3)
        }
        task.pending.store(children.count, ordering: .releasing)
        return children
    }

    private func addProgress(_ share: Double) {
        let units = UInt64(max(0, share * Self.progressScale))
        if units > 0 { progressUnits.wrappingAdd(units, ordering: .relaxed) }
    }

    private func claim(_ task: DirTask) -> Bool {
        task.claim.compareExchange(expected: DirTask.unclaimed, desired: DirTask.claimed, ordering: .acquiringAndReleasing).exchanged
    }

    /// Finalizes `task` and walks up while parents become complete.
    private func complete(_ task: DirTask, scratch: inout [UInt32]) {
        var current = task
        while true {
            arena.finalizeDirectory(current.node, scratch: &scratch)
            guard let parent = current.parent else {
                markDone()
                return
            }
            let remaining = parent.pending.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue
            guard remaining == 0 else { return }
            current = parent
        }
    }
}
