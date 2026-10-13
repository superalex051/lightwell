import Darwin
import Synchronization

/// One node of the scan arena (PLAN 2.4). The stride must stay at or below 32 bytes.
///
/// `firstChild` is an offset into the arena's child index (not a node id), so children can be
/// re-sorted or removed without moving nodes: node ids stay stable for the life of the tree.
struct Node {
    /// Aggregated bytes (files: their contribution after hard-link and clone dedupe).
    var size: UInt64
    /// Parent node id, `noNode` for the root.
    var parent: UInt32
    /// Offset of the first entry of this node's block in the child index.
    var firstChild: UInt32
    var childCount: UInt32
    /// Byte offset of the name in the name slab.
    var nameRef: UInt32
    var descendants: UInt32
    var nameLength: UInt16
    /// Public `NodeFlags` bits plus internal bits (see `NodeBits`).
    var flags: UInt16
}

/// Reserved "no node" id.
let noNode: UInt32 = .max

/// Internal flag bits stored next to the public `NodeFlags` in `Node.flags`.
enum NodeBits {
    /// Bits that belong to the public `NodeFlags` option set.
    static let publicMask: UInt16 = 0x13FF
    /// The node was removed from the tree (its id stays reserved).
    static let removed: UInt16 = 1 << 15
    /// Where the high 32 bits of the inode number live: 0 = zero, 1 or 2 = arena high slot,
    /// 3 = full value in `Arena.inodeExceptions`.
    static let inodeHigh: UInt16 = 0x0C00
    static let inodeHighShift: UInt16 = 10
}

/// Append-only storage split into lazily mapped chunks, so it can grow while other threads
/// read elements that were published earlier. Elements must be trivial types (zero-filled memory
/// is a valid value).
final class ChunkedBuffer<Element>: @unchecked Sendable {
    let chunkShift: Int
    let maxChunks: Int
    private let directory: UnsafeMutablePointer<UnsafeMutablePointer<Element>?>
    private let allocatedChunks = Atomic<Int>(0)
    private let reservedCount = Atomic<Int>(0)
    private let growLock = Mutex<Int>(0)

    var chunkCapacity: Int { 1 << chunkShift }
    private var chunkBytes: Int { chunkCapacity * MemoryLayout<Element>.stride }

    init(chunkShift: Int, maxChunks: Int) {
        self.chunkShift = chunkShift
        self.maxChunks = maxChunks
        directory = .allocate(capacity: maxChunks)
        directory.initialize(repeating: nil, count: maxChunks)
    }

    deinit {
        let chunks = allocatedChunks.load(ordering: .acquiring)
        for index in 0..<chunks {
            if let chunk = directory[index] { munmap(UnsafeMutableRawPointer(chunk), chunkBytes) }
        }
        directory.deallocate()
    }

    /// Number of elements reserved so far.
    var count: Int { reservedCount.load(ordering: .acquiring) }

    /// Bytes of the reserved elements.
    var reservedBytes: Int { count * MemoryLayout<Element>.stride }

    /// Reserves `n` consecutive elements and returns the index of the first. Thread safe.
    func reserve(_ n: Int) -> Int {
        let start = reservedCount.wrappingAdd(n, ordering: .relaxed).oldValue
        ensureCapacity(start + n)
        return start
    }

    /// Makes sure elements `0..<needed` are backed by memory. Thread safe.
    func ensureCapacity(_ needed: Int) {
        let neededChunks = (needed + chunkCapacity - 1) >> chunkShift
        if allocatedChunks.load(ordering: .acquiring) >= neededChunks { return }
        growLock.withLock { _ in
            var have = allocatedChunks.load(ordering: .relaxed)
            precondition(neededChunks <= maxChunks, "scan arena exhausted")
            while have < neededChunks {
                let raw = mmap(nil, chunkBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
                precondition(raw != MAP_FAILED && raw != nil, "scan arena could not map memory")
                directory[have] = raw!.bindMemory(to: Element.self, capacity: chunkCapacity)
                have += 1
            }
            allocatedChunks.store(have, ordering: .releasing)
        }
    }

    @inline(__always)
    func pointer(_ index: Int) -> UnsafeMutablePointer<Element> {
        directory[index >> chunkShift].unsafelyUnwrapped + (index & (chunkCapacity - 1))
    }

    @inline(__always)
    subscript(index: Int) -> Element {
        get { pointer(index).pointee }
        set { pointer(index).pointee = newValue }
    }
}

/// Writes names into the shared slab. Each writer owns whole chunks, so several writers can work
/// in parallel without locking. A name never spans two chunks. Short names are interned through a
/// small direct-mapped cache: repeated names (`index.js`, `Contents`, `.DS_Store`, ...) share one
/// copy in the slab, which is immutable once written.
struct NameWriter {
    private var next = 0
    private var end = 0
    /// Bytes written since the last `flush`.
    private var pendingBytes = 0
    /// Packed `ref (32) | length (8) | tag (24)`; 0 means empty.
    private var cache: [UInt64] = []
    private static let cacheSlots = 4096
    private static let maxInternedLength = 64

    mutating func write(_ bytes: UnsafeRawBufferPointer, into slab: ChunkedBuffer<UInt8>) -> UInt32 {
        let length = bytes.count
        var slot = -1
        var tag: UInt64 = 0
        if length > 0 && length <= Self.maxInternedLength, let base = bytes.baseAddress {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for index in 0..<length {
                hash = (hash ^ UInt64(base.load(fromByteOffset: index, as: UInt8.self))) &* 0x0000_0100_0000_01B3
            }
            if cache.isEmpty { cache = [UInt64](repeating: 0, count: Self.cacheSlots) }
            slot = Int(truncatingIfNeeded: hash) & (Self.cacheSlots - 1)
            tag = (hash >> 40) & 0xFF_FFFF
            let entry = cache[slot]
            if entry != 0, entry & 0xFF_FFFF == tag, Int((entry >> 24) & 0xFF) == length {
                let ref = Int(entry >> 32)
                if memcmp(slab.pointer(ref), base, length) == 0 { return UInt32(ref) }
            }
        }
        if next + length > end {
            let start = slab.reserve(slab.chunkCapacity)
            next = start
            end = start + slab.chunkCapacity
        }
        let offset = next
        if length > 0, let base = bytes.baseAddress {
            UnsafeMutableRawPointer(slab.pointer(offset)).copyMemory(from: base, byteCount: length)
        }
        next += length
        pendingBytes += length
        precondition(offset <= Int(UInt32.max), "name slab exhausted")
        if slot >= 0 {
            cache[slot] = UInt64(offset) << 32 | UInt64(length) << 24 | tag
        }
        return UInt32(offset)
    }

    mutating func write(_ bytes: [UInt8], into slab: ChunkedBuffer<UInt8>) -> UInt32 {
        bytes.withUnsafeBytes { write($0, into: slab) }
    }

    /// Adds the bytes written since the last flush to the arena's name byte count.
    mutating func flush(into arena: Arena) {
        if pendingBytes > 0 {
            arena.nameBytesUsed.wrappingAdd(pendingBytes, ordering: .relaxed)
            pendingBytes = 0
        }
    }

    /// Drops the intern cache (after a scan, to free its memory).
    mutating func dropCache() { cache = [] }
}

/// Chunked node storage, child index, inode numbers and name slab of one tree.
final class Arena: @unchecked Sendable {
    /// 2^20 nodes per chunk (PLAN 2.4); memory is mapped lazily, untouched pages cost nothing.
    let nodes = ChunkedBuffer<Node>(chunkShift: 20, maxChunks: 4096)
    /// Low 32 bits of each node's inode number (see `storeInode`).
    let inodes = ChunkedBuffer<UInt32>(chunkShift: 20, maxChunks: 4096)
    /// High 32 bits shared by many inodes (for example the System volume's 0x0FFFFFFF), plus one.
    private let highSlot1 = Atomic<UInt64>(0)
    private let highSlot2 = Atomic<UInt64>(0)
    /// Full inode numbers whose high bits fit no slot (rare).
    let inodeExceptions = Mutex<[NodeID: UInt64]>([:])
    let childIndex = ChunkedBuffer<UInt32>(chunkShift: 20, maxChunks: 4096)
    /// 1 MiB chunks; `nameRef` is a byte offset, so the slab holds up to 4 GiB of names.
    let names = ChunkedBuffer<UInt8>(chunkShift: 20, maxChunks: 4096)
    /// Name bytes actually written (interned names counted once), see `NameWriter.flush`.
    let nameBytesUsed = Atomic<Int>(0)

    /// Reserves `n` node ids (and their inode slots).
    func reserveNodes(_ n: Int) -> Int {
        let start = nodes.reserve(n)
        precondition(start + n < Int(noNode), "too many nodes")
        inodes.ensureCapacity(start + n)
        return start
    }

    var nodeCount: Int { nodes.count }

    /// Stores the inode number of `id` and returns the flag bits to merge into its node flags.
    func storeInode(_ id: NodeID, _ value: UInt64) -> UInt16 {
        inodes[Int(id)] = UInt32(truncatingIfNeeded: value)
        let high = value >> 32
        if high == 0 { return 0 }
        let tagged = high + 1
        if claimSlot(highSlot1, tagged) { return 1 << NodeBits.inodeHighShift }
        if claimSlot(highSlot2, tagged) { return 2 << NodeBits.inodeHighShift }
        inodeExceptions.withLock { $0[id] = value }
        return 3 << NodeBits.inodeHighShift
    }

    private func claimSlot(_ slot: borrowing Atomic<UInt64>, _ tagged: UInt64) -> Bool {
        let current = slot.load(ordering: .acquiring)
        if current == tagged { return true }
        guard current == 0 else { return false }
        let (exchanged, original) = slot.compareExchange(expected: 0, desired: tagged, ordering: .acquiringAndReleasing)
        return exchanged || original == tagged
    }

    /// The inode number of `id`, given its node flags.
    @inline(__always)
    func inode(_ id: NodeID, flags: UInt16) -> UInt64 {
        let low = UInt64(inodes[Int(id)])
        switch (flags & NodeBits.inodeHigh) >> NodeBits.inodeHighShift {
        case 0: return low
        case 1: return (highSlot1.load(ordering: .acquiring) &- 1) << 32 | low
        case 2: return (highSlot2.load(ordering: .acquiring) &- 1) << 32 | low
        default: return inodeExceptions.withLock { $0[id] } ?? low
        }
    }

    @inline(__always)
    func nameBytes(_ node: Node) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: names.pointer(Int(node.nameRef)), count: Int(node.nameLength))
    }

    @inline(__always)
    func child(_ node: Node, _ index: Int) -> NodeID {
        childIndex[Int(node.firstChild) + index]
    }

    /// Bytes held by the arena: reserved nodes, inodes and child index entries plus the name
    /// bytes written. Partly filled name chunks are mapped lazily, so their unused tail costs no
    /// memory and is not counted.
    var storageBytes: Int {
        // Inode slots are sized with the nodes (never reserved on their own).
        nodes.reservedBytes + nodes.count * MemoryLayout<UInt32>.stride + childIndex.reservedBytes
            + nameBytesUsed.load(ordering: .relaxed)
            + inodeExceptions.withLock { $0.count } * 24
    }
}

/// Lexicographic comparison of two byte buffers (UTF-8 byte order).
@inline(__always)
func bytesPrecede(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
    let common = min(a.count, b.count)
    if common > 0 {
        let result = memcmp(a.baseAddress!, b.baseAddress!, common)
        if result != 0 { return result < 0 }
    }
    return a.count < b.count
}

@inline(__always)
func bytesEqual(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
    guard a.count == b.count else { return false }
    if a.count == 0 { return true }
    return memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
}

/// Read-write lock around `pthread_rwlock_t`.
final class ReadWriteLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    @inline(__always)
    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    @inline(__always)
    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}
