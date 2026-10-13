import Darwin
import Foundation
import Synchronization

/// Hard-linked inode: every link found in the scan, the inode's link count and its allocation.
struct HardLinkGroup {
    var linkCount: UInt32
    var alloc: UInt64
    var members: [NodeID]
}

/// Clone family key: same device, same `ATTR_CMNEXT_CLONEID`.
struct CloneKey: Hashable {
    var device: Int32
    var cloneID: UInt64
}

/// Index of a clone family in `ScanTree.cloneFamilies`.
typealias FamilyID = UInt32

/// One clone family member (12 bytes): sizes are kept in 512-byte units, the allocation unit of
/// `st_blocks`; APFS allocations are multiples of 4 KiB.
struct CloneMember {
    static let unit: UInt64 = 512
    var node: NodeID
    private var allocUnits: UInt32
    private var privateUnits: UInt32

    /// `nil` when the sizes are not whole units or too large (the file then counts as a plain file).
    init?(node: NodeID, alloc: UInt64, privateBytes: UInt64) {
        let privateClamped = min(privateBytes, alloc)
        guard alloc % Self.unit == 0, privateClamped % Self.unit == 0, alloc / Self.unit <= UInt64(UInt32.max) else { return nil }
        self.node = node
        allocUnits = UInt32(alloc / Self.unit)
        privateUnits = UInt32(privateClamped / Self.unit)
    }

    var alloc: UInt64 { UInt64(allocUnits) * Self.unit }
    var privateBytes: UInt64 { UInt64(privateUnits) * Self.unit }
    var shared: UInt64 { alloc - privateBytes }
}

struct CloneFamily {
    var key: CloneKey
    var members: [CloneMember]
    /// Shared bytes of the family: the largest shared part of any member.
    var shared: UInt64 { members.lazy.map(\.shared).max() ?? 0 }
}

/// Raw sharing facts gathered while scanning, turned into side tables by `installSharing`.
struct HardLinkRecord {
    var identity: FileIdentity
    var node: NodeID
    var linkCount: UInt32
    var alloc: UInt64
}

/// Compact (24-byte) clone fact from the scan; the allocation is the node's size at install time.
struct CloneRecord {
    var cloneID: UInt64
    var privateBytes: UInt64
    var node: NodeID
    var device: Int32

    var key: CloneKey { CloneKey(device: device, cloneID: cloneID) }
}

/// The tree produced by `Scanner` (PLAN 2.4): a chunked arena of 32-byte nodes with names in a
/// UTF-8 slab, side tables for hard links and clones, and an internal read-write lock.
/// Read-mostly after the scan; every mutation bumps `generation`. Node ids are never reused,
/// except after a full rescan of the root swapped in by `adopt(_:)`: then `structureEpoch`
/// changes, `TreeRefresher` emits `.restructured(epoch:)`, and holders of node ids must resolve
/// them again by path.
public final class ScanTree: TreeReading, @unchecked Sendable {
    /// Replaced only by `adopt(_:)` (full rescan of the root), under the write lock.
    var arena: Arena
    /// Absolute path of the root as given to the scanner.
    public let rootPath: String
    let rootPathBytes: [UInt8]
    /// Device of the root; other nodes inherit their parent's device unless listed in
    /// `deviceExceptions` (only the points where the device changes).
    var rootDevice: Int32
    public let sizeMode: SizeMode
    public let countClonesOnce: Bool
    /// Firmlink targets skipped inside the Data volume (scans of `/`), kept for refreshes.
    let firmlinkSkip: Set<FileIdentity>
    let dataVolumePath: [UInt8]?
    /// `ScanOptions.excludedPaths` of the scan, honored by refreshes.
    let excludedPaths: Set<[UInt8]>
    /// FSEvents event id taken when the scan started (0 when unknown). `TreeRefresher` replays
    /// events from there, so changes made while the scan was running are not lost.
    var eventIDAtScanStart: UInt64 = 0
    let lock = ReadWriteLock()
    private let generationCounter = Atomic<UInt64>(0)
    private let epochCounter = Atomic<UInt64>(0)
    private let nameIndexCache = Mutex<NameIndexCache>(NameIndexCache())

    // Guarded by `lock`.
    var deviceExceptions: [NodeID: Int32] = [:]
    var hardLinks: [FileIdentity: HardLinkGroup] = [:]
    /// Clone families by `FamilyID`; a family whose members are all gone keeps its slot, empty.
    var cloneFamilies: [CloneFamily] = []
    var cloneFamilyIndex: [CloneKey: FamilyID] = [:]
    var cloneOf = NodeFamilyMap()
    var nameWriter = NameWriter()
    var sortScratch: [UInt32] = []
    /// Folders the scan's watchdog gave up on (flag `notResponding`).
    var unresponsiveNodes: [NodeID] = []

    struct NameIndexCache {
        var generation: UInt64 = .max
        var indexes: [NodeID: [[UInt8]: NodeID]] = [:]
    }

    /// Directories with more children than this get a lazy name index for path lookups.
    static let nameIndexThreshold = 256

    init(
        arena: Arena,
        rootPath: String,
        rootDevice: Int32,
        sizeMode: SizeMode,
        countClonesOnce: Bool,
        firmlinkSkip: Set<FileIdentity> = [],
        dataVolumePath: [UInt8]? = nil,
        excludedPaths: Set<[UInt8]> = []
    ) {
        self.arena = arena
        self.rootPath = rootPath
        rootPathBytes = Array(rootPath.utf8)
        self.rootDevice = rootDevice
        self.sizeMode = sizeMode
        self.countClonesOnce = countClonesOnce
        self.firmlinkSkip = firmlinkSkip
        self.dataVolumePath = dataVolumePath
        self.excludedPaths = excludedPaths
    }

    /// A tree holding only the root directory at `path`.
    public convenience init(emptyRootAt path: String) {
        let arena = Arena()
        var info = stat()
        let found = stat(path, &info) == 0
        var writer = NameWriter()
        Self.writeRoot(into: arena, path: path, inode: found ? UInt64(info.st_ino) : 0, writer: &writer)
        writer.flush(into: arena)
        self.init(arena: arena, rootPath: path, rootDevice: found ? info.st_dev : 0, sizeMode: .allocated, countClonesOnce: true)
    }

    /// Writes node 0 (the root directory) into an empty arena.
    static func writeRoot(into arena: Arena, path: String, inode: UInt64, writer: inout NameWriter) {
        let id = arena.reserveNodes(1)
        precondition(id == 0, "root must be node 0")
        let name = displayName(forRoot: path)
        let ref = writer.write(Array(name.utf8), into: arena.names)
        var flags = NodeFlags.directory.rawValue
        if isPackageName(Array(name.utf8)[...]) { flags |= NodeFlags.package.rawValue }
        flags |= arena.storeInode(0, inode)
        arena.nodes[0] = Node(
            size: 0, parent: noNode, firstChild: 0, childCount: 0, nameRef: ref,
            descendants: 0, nameLength: UInt16(min(name.utf8.count, Int(UInt16.max))), flags: flags
        )
    }

    static func displayName(forRoot path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    // MARK: Generation

    public var root: NodeID { 0 }
    public var generation: UInt64 { generationCounter.load(ordering: .acquiring) }

    /// Changes when node ids are reassigned (a full rescan of the root was swapped in). Holders
    /// of node ids must resolve them again by path when it changes. Added by WS2.
    public var structureEpoch: UInt64 { epochCounter.load(ordering: .acquiring) }

    /// Takes over the contents of `other` (a fresh scan of the same root) instead of grafting
    /// it, so a full rescan does not grow the arena. All node ids change; bumps `generation`
    /// and `structureEpoch`.
    func adopt(_ other: ScanTree) {
        guard other !== self else { return }
        other.lock.write {
            lock.write {
                arena = other.arena
                rootDevice = other.rootDevice
                deviceExceptions = other.deviceExceptions
                hardLinks = other.hardLinks
                cloneFamilies = other.cloneFamilies
                cloneFamilyIndex = other.cloneFamilyIndex
                cloneOf = other.cloneOf
                nameWriter = other.nameWriter
                unresponsiveNodes = other.unresponsiveNodes
                eventIDAtScanStart = other.eventIDAtScanStart
                epochCounter.wrappingAdd(1, ordering: .acquiringAndReleasing)
                bumpGeneration()
            }
        }
    }

    /// Called at the end of every mutation (inside the write lock).
    func bumpGeneration() {
        nameWriter.flush(into: arena)
        generationCounter.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }

    // MARK: Unlocked accessors (caller holds the lock)

    @inline(__always) func isValid(_ id: NodeID) -> Bool { Int(id) < arena.nodeCount }
    @inline(__always) func node(_ id: NodeID) -> Node { arena.nodes[Int(id)] }
    @inline(__always) func isRemoved(_ id: NodeID) -> Bool { node(id).flags & NodeBits.removed != 0 }
    @inline(__always) func nameBytes(_ id: NodeID) -> UnsafeBufferPointer<UInt8> { arena.nameBytes(node(id)) }

    func childIDs(_ id: NodeID) -> [NodeID] {
        let n = node(id)
        guard n.childCount > 0 else { return [] }
        let first = Int(n.firstChild)
        return (0..<Int(n.childCount)).map { arena.childIndex[first + $0] }
    }

    func pathBytesUnlocked(_ id: NodeID) -> [UInt8] {
        guard id != 0 else { return rootPathBytes }
        var chain: [NodeID] = []
        var cursor = id
        while cursor != 0 && cursor != noNode {
            chain.append(cursor)
            cursor = node(cursor).parent
        }
        var out = rootPathBytes
        out.reserveCapacity(out.count + chain.count * 16)
        for item in chain.reversed() {
            if !(out.count == 1 && out[0] == 0x2F) { out.append(0x2F) }
            out.append(contentsOf: nameBytes(item))
        }
        return out
    }

    func identityUnlocked(_ id: NodeID) -> FileIdentity {
        FileIdentity(device: deviceOf(id), inode: inodeOf(id))
    }

    /// Device of `id`: the nearest exception on the way to the root, else the root's device.
    func deviceOf(_ id: NodeID) -> Int32 {
        guard !deviceExceptions.isEmpty else { return rootDevice }
        var cursor = id
        while cursor != noNode {
            if let device = deviceExceptions[cursor] { return device }
            if cursor == 0 { break }
            cursor = node(cursor).parent
        }
        return rootDevice
    }

    @inline(__always)
    func inodeOf(_ id: NodeID) -> UInt64 { arena.inode(id, flags: node(id).flags) }

    /// True when `id` is `ancestor` or lies below it.
    func isWithin(_ id: NodeID, _ ancestor: NodeID) -> Bool {
        var cursor = id
        while true {
            if cursor == ancestor { return true }
            if cursor == 0 || cursor == noNode { return false }
            cursor = node(cursor).parent
        }
    }

    // MARK: TreeReading

    public func name(_ id: NodeID) -> String {
        lock.read {
            guard isValid(id) else { return "" }
            return String(decoding: nameBytes(id), as: UTF8.self)
        }
    }

    public func path(_ id: NodeID) -> String {
        lock.read {
            guard isValid(id) else { return "" }
            return String(decoding: pathBytesUnlocked(id), as: UTF8.self)
        }
    }

    public func size(_ id: NodeID) -> UInt64 {
        lock.read {
            guard isValid(id), !isRemoved(id) else { return 0 }
            return node(id).size
        }
    }

    public func flags(_ id: NodeID) -> NodeFlags {
        lock.read {
            guard isValid(id) else { return [] }
            return NodeFlags(rawValue: node(id).flags & NodeBits.publicMask)
        }
    }

    public func parent(_ id: NodeID) -> NodeID? {
        lock.read {
            guard isValid(id), id != 0 else { return nil }
            let parent = node(id).parent
            return parent == noNode ? nil : parent
        }
    }

    public func children(_ id: NodeID) -> [NodeID] {
        lock.read {
            guard isValid(id), !isRemoved(id) else { return [] }
            return childIDs(id)
        }
    }

    public func descendantCount(_ id: NodeID) -> UInt32 {
        lock.read {
            guard isValid(id), !isRemoved(id) else { return 0 }
            return node(id).descendants
        }
    }

    public func identity(_ id: NodeID) -> FileIdentity? {
        lock.read {
            guard isValid(id) else { return nil }
            let identity = identityUnlocked(id)
            return identity.inode == 0 ? nil : identity
        }
    }

    public func node(atPath path: String) -> NodeID? {
        lock.read { lookupUnlocked(Array(path.utf8)) }
    }

    func lookupUnlocked(_ input: [UInt8]) -> NodeID? {
        var bytes = input
        while bytes.count > 1 && bytes.last == 0x2F { bytes.removeLast() }
        if bytes == rootPathBytes { return 0 }
        let isSlashRoot = rootPathBytes == [0x2F]
        let prefixLength = isSlashRoot ? 1 : rootPathBytes.count + 1
        guard bytes.count > prefixLength,
              bytes.starts(with: rootPathBytes),
              bytes[prefixLength - 1] == 0x2F
        else { return nil }
        var current: NodeID = 0
        for component in bytes[prefixLength...].split(separator: 0x2F, omittingEmptySubsequences: true) {
            guard let next = childNamed(current, component) else { return nil }
            current = next
        }
        return current
    }

    func childNamed(_ directory: NodeID, _ component: ArraySlice<UInt8>) -> NodeID? {
        let parent = node(directory)
        let count = Int(parent.childCount)
        guard count > 0 else { return nil }
        if count > Self.nameIndexThreshold {
            let generation = generation
            let index: [[UInt8]: NodeID] = nameIndexCache.withLock { cache in
                if cache.generation != generation {
                    cache.generation = generation
                    cache.indexes.removeAll()
                }
                if let existing = cache.indexes[directory] { return existing }
                var built: [[UInt8]: NodeID] = [:]
                built.reserveCapacity(count)
                for child in childIDs(directory) { built[Array(nameBytes(child))] = child }
                cache.indexes[directory] = built
                return built
            }
            return index[Array(component)]
        }
        return component.withUnsafeBufferPointer { wanted in
            for offset in 0..<count {
                let child = arena.childIndex[Int(parent.firstChild) + offset]
                if bytesEqual(nameBytes(child), wanted) { return child }
            }
            return nil
        }
    }

    // MARK: Extra read API (additive)

    /// Size of one hard link or clone member on its own, before dedupe (the bytes the item
    /// occupies when looked at alone). `nil` for items that do not share storage.
    public func sizeInLinks(_ id: NodeID) -> UInt64? {
        lock.read {
            guard isValid(id) else { return nil }
            let flags = node(id).flags
            if flags & NodeFlags.hardLink.rawValue != 0, let group = hardLinks[identityUnlocked(id)] {
                return group.alloc
            }
            if let (_, member) = cloneMember(id) { return member.alloc }
            return nil
        }
    }

    /// Folders the scan's watchdog gave up on (flag `notResponding`, size 0): show "some folders
    /// did not respond". Added by WS1.
    public var unresponsiveFolders: [NodeID] {
        lock.read {
            var seen = Set<NodeID>()
            return unresponsiveNodes.filter { id in
                isValid(id) && !isRemoved(id) && node(id).flags & NodeFlags.notResponding.rawValue != 0
                    && seen.insert(id).inserted
            }
        }
    }

    /// Number of node slots in the arena (live and removed).
    public var nodeCapacity: Int { lock.read { arena.nodeCount } }

    /// Bytes held by the tree: arena, name slab and side tables (estimate for the side tables).
    public var storageBytes: Int {
        lock.read {
            let hardLinkBytes = hardLinks.reduce(0) { $0 + 48 + $1.value.members.count * 4 }
            let cloneBytes = cloneFamilies.reduce(0) { $0 + 72 + $1.members.count * MemoryLayout<CloneMember>.stride }
                + cloneOf.storageBytes + cloneFamilyIndex.capacity * 21
            return arena.storageBytes + hardLinkBytes + cloneBytes + deviceExceptions.count * 16
        }
    }

    /// Clone family and member record of file `id` (caller holds the lock).
    func cloneMember(_ id: NodeID) -> (FamilyID, CloneMember)? {
        guard let family = cloneOf[id], let member = cloneFamilies[Int(family)].members.first(where: { $0.node == id }) else { return nil }
        return (family, member)
    }

    /// Runs `body` with the read lock held. Internal fast path for queries.
    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.read(body)
    }
}

// MARK: Packages

/// Directory extensions treated as packages (one item until "Show Package Contents").
let packageExtensions: Set<[UInt8]> = Set([
    "app", "appex", "bundle", "framework", "plugin", "kext", "photoslibrary", "xcarchive",
    "sparsebundle", "rtfd", "pages", "numbers", "key", "fcpbundle", "musiclibrary",
    "imovielibrary", "xcodeproj", "xcworkspace", "playground", "prefPane", "qlgenerator",
    "mdimporter", "saver", "wdgt", "component", "docset",
].map { Array($0.lowercased().utf8) })

/// True for names ending in a known package extension (ASCII case-insensitive).
func isPackageName(_ name: ArraySlice<UInt8>) -> Bool {
    guard let dot = name.lastIndex(of: 0x2E), dot > name.startIndex, dot < name.endIndex - 1 else { return false }
    let ext = name[(dot + 1)...]
    guard ext.count <= 16 else { return false }
    var lowered: [UInt8] = []
    lowered.reserveCapacity(ext.count)
    for byte in ext { lowered.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte) }
    return packageExtensions.contains(lowered)
}
