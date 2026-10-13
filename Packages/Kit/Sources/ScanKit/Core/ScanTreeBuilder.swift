import Foundation

/// Builds a `ScanTree` in memory without touching the disk: tests, benchmarks and previews that
/// need the real arena (for example the 2M node footprint test).
///
/// ```swift
/// let builder = ScanTreeBuilder(rootPath: "/fx")
/// let caches = builder.addDirectory("Caches", under: builder.root)
/// builder.addFile("a.bin", size: 4096, under: caches)
/// let tree = builder.build()
/// ```
public final class ScanTreeBuilder {
    private let arena = Arena()
    private var writer = NameWriter()
    private var children: [NodeID: [NodeID]] = [:]
    private var hardLinkRecords: [HardLinkRecord] = []
    private var cloneRecords = ChunkedBuffer<CloneRecord>(chunkShift: 16, maxChunks: 65_536)
    private var nextInode: UInt64 = 1_000_000
    private let rootPath: String
    private let device: Int32
    private let sizeMode: SizeMode
    private let countClonesOnce: Bool
    private var built = false
    /// Directories whose device differs from their parent's (`addDirectory(device:)`).
    private var deviceChanges: [NodeID: Int32] = [:]

    public init(rootPath: String, device: Int32 = 1, sizeMode: SizeMode = .allocated, countClonesOnce: Bool = true) {
        self.rootPath = rootPath
        self.device = device
        self.sizeMode = sizeMode
        self.countClonesOnce = countClonesOnce
        ScanTree.writeRoot(into: arena, path: rootPath, inode: 2, writer: &writer)
    }

    public var root: NodeID { 0 }

    private func append(_ name: String, under parent: NodeID, size: UInt64, flags: UInt16, inode: UInt64) -> NodeID {
        precondition(!built, "builder already finished")
        precondition(arena.nodes[Int(parent)].flags & NodeFlags.directory.rawValue != 0, "parent must be a directory")
        let id = NodeID(arena.reserveNodes(1))
        let bytes = Array(name.utf8)
        let ref = writer.write(bytes, into: arena.names)
        let inodeBits = arena.storeInode(id, inode)
        arena.nodes[Int(id)] = Node(
            size: size, parent: parent, firstChild: 0, childCount: 0, nameRef: ref,
            descendants: 0, nameLength: UInt16(min(bytes.count, Int(UInt16.max))), flags: flags | inodeBits
        )
        children[parent, default: []].append(id)
        return id
    }

    /// Effective device of `id` (nearest recorded change on the way to the root).
    private func deviceOf(_ id: NodeID) -> Int32 {
        var cursor = id
        while cursor != noNode {
            if let changed = deviceChanges[cursor] { return changed }
            if cursor == 0 { break }
            cursor = arena.nodes[Int(cursor)].parent
        }
        return device
    }

    private func freshInode() -> UInt64 {
        nextInode += 1
        return nextInode
    }

    @discardableResult
    /// Adds a directory. Pass `device` for a directory on another device than its parent (the
    /// subtree inherits it).
    public func addDirectory(_ name: String, under parent: NodeID, flags: NodeFlags = [], device: Int32? = nil) -> NodeID {
        var bits = flags.union(.directory).rawValue
        if isPackageName(Array(name.utf8)[...]) { bits |= NodeFlags.package.rawValue }
        let id = append(name, under: parent, size: 0, flags: bits, inode: freshInode())
        if let device, device != deviceOf(parent) { deviceChanges[id] = device }
        return id
    }

    /// Adds a file. Files sharing an `inode` with `linkCount > 1` are hard links of one inode;
    /// files sharing a `cloneID` with `privateBytes < size` are members of one clone family.
    @discardableResult
    public func addFile(
        _ name: String, size: UInt64, under parent: NodeID,
        inode: UInt64? = nil, linkCount: UInt32 = 1,
        cloneID: UInt64? = nil, privateBytes: UInt64? = nil,
        flags: NodeFlags = []
    ) -> NodeID {
        var bits = flags.subtracting(.directory).rawValue
        let fileInode = inode ?? freshInode()
        if linkCount > 1 { bits |= NodeFlags.hardLink.rawValue }
        let privateSize = min(privateBytes ?? size, size)
        let isClone = cloneID != nil && privateSize < size
        if isClone { bits |= NodeFlags.cloned.rawValue }
        let id = append(name, under: parent, size: size, flags: bits, inode: fileInode)
        if linkCount > 1 {
            hardLinkRecords.append(HardLinkRecord(identity: FileIdentity(device: deviceOf(parent), inode: fileInode), node: id, linkCount: linkCount, alloc: size))
        }
        if isClone, let cloneID {
            cloneRecords[cloneRecords.reserve(1)] = CloneRecord(cloneID: cloneID, privateBytes: privateSize, node: id, device: deviceOf(parent))
        }
        return id
    }

    /// Finishes the tree: aggregates sizes, sorts children, applies hard-link and clone dedupe.
    public func build() -> ScanTree {
        precondition(!built, "builder already finished")
        built = true
        for (parent, list) in children {
            let start = arena.childIndex.reserve(list.count)
            for (offset, child) in list.enumerated() { arena.childIndex[start + offset] = child }
            arena.nodes[Int(parent)].firstChild = UInt32(start)
            arena.nodes[Int(parent)].childCount = UInt32(list.count)
        }
        children = [:]
        // Children always have larger ids than their parent, so a reverse sweep is post-order.
        var scratch: [UInt32] = []
        var id = arena.nodeCount - 1
        while id >= 0 {
            if arena.nodes[id].flags & NodeFlags.directory.rawValue != 0 {
                arena.finalizeDirectory(NodeID(id), scratch: &scratch)
            }
            id -= 1
        }
        writer.flush(into: arena)
        let tree = ScanTree(arena: arena, rootPath: rootPath, rootDevice: device, sizeMode: sizeMode, countClonesOnce: countClonesOnce)
        tree.installSharing(hardLinkRecords: hardLinkRecords, cloneRecords: cloneRecords, deviceExceptions: deviceChanges.map { ($0.key, $0.value) })
        cloneRecords = ChunkedBuffer<CloneRecord>(chunkShift: 0, maxChunks: 1)
        hardLinkRecords = []
        return tree
    }
}
