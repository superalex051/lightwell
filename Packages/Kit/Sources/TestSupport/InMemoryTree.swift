import Foundation
import ScanKit
import Synchronization

/// Mutable in-memory `TreeReading` fake for tests that need a tree before (or without) the real scanner.
///
/// Accounting mirrors PLAN 2.4: every hard-linked inode counts once at its primary link (smallest
/// path, UTF-8 byte order; the others get `.hardLinkSecondary` and size 0); with `countClonesOnce`
/// each clone family contributes its shared bytes once, at its primary member, and every member
/// contributes its private bytes. Directory sizes are the sum of their children. `children(_:)` is
/// sorted by size (largest first, ties by name). Every mutation bumps `generation`.
///
/// ```swift
/// let tree = InMemoryTree(rootPath: "/fx", entries: [
///     .dir("Library", [.dir("Caches", [.file("a.bin", 4096)])]),
///     .file("big.mov", 1_000_000),
/// ])
/// let caches = tree.node(atPath: "/fx/Library/Caches")!
/// ```
public final class InMemoryTree: TreeReading {
    /// Declarative description used by `init(rootPath:entries:)`.
    public indirect enum Entry: Sendable {
        case dir(String, [Entry])
        case package(String, [Entry])
        case file(String, UInt64)
        case symlink(String)
        case restricted(String)
    }

    struct Node {
        var name: String
        var flags: NodeFlags
        var parent: NodeID?
        var children: [NodeID] = []
        /// Allocated bytes of the item itself (files and symlinks).
        var ownBytes: UInt64 = 0
        var identity: FileIdentity?
        var cloneFamily: UInt64?
        var privateBytes: UInt64 = 0
        var removed = false
        // Derived, recomputed lazily after mutations.
        var size: UInt64 = 0
        var descendants: UInt32 = 0
    }

    struct Storage {
        var rootPath: String
        var countClonesOnce: Bool
        var nodes: [Node]
        var generation: UInt64 = 0
        var dirty = true
        var nextSyntheticInode: UInt64 = 1
        var nextCloneFamily: UInt64 = 1

        func path(_ id: NodeID) -> String {
            var parts: [String] = []
            var cursor: NodeID? = id
            while let c = cursor, let parent = nodes[Int(c)].parent {
                parts.append(nodes[Int(c)].name)
                cursor = parent
            }
            guard !parts.isEmpty else { return rootPath }
            let suffix = parts.reversed().joined(separator: "/")
            return rootPath.hasSuffix("/") ? rootPath + suffix : rootPath + "/" + suffix
        }

        func isLive(_ id: NodeID) -> Bool {
            var cursor: NodeID? = id
            while let c = cursor {
                if nodes[Int(c)].removed { return false }
                cursor = nodes[Int(c)].parent
            }
            return true
        }

        func subtree(_ id: NodeID) -> [NodeID] {
            var result: [NodeID] = []
            var stack = [id]
            while let next = stack.popLast() {
                result.append(next)
                stack.append(contentsOf: nodes[Int(next)].children)
            }
            return result
        }

        func liveLeaves() -> [NodeID] {
            subtree(0).filter { !nodes[Int($0)].flags.contains(.directory) }
        }

        /// Hard-link groups (identity -> live members) with more than one member.
        func hardLinkGroups() -> [FileIdentity: [NodeID]] {
            var groups: [FileIdentity: [NodeID]] = [:]
            for id in liveLeaves() {
                if let identity = nodes[Int(id)].identity {
                    groups[identity, default: []].append(id)
                }
            }
            return groups.filter { $0.value.count > 1 }
        }

        func cloneFamilies() -> [UInt64: [NodeID]] {
            var families: [UInt64: [NodeID]] = [:]
            for id in liveLeaves() {
                if let family = nodes[Int(id)].cloneFamily { families[family, default: []].append(id) }
            }
            return families
        }

        func smallestPath(_ ids: [NodeID]) -> NodeID {
            ids.min { path($0).utf8.lexicographicallyPrecedes(path($1).utf8) }!
        }

        func familyShared(_ members: [NodeID]) -> UInt64 {
            members.map { nodes[Int($0)].ownBytes - min(nodes[Int($0)].privateBytes, nodes[Int($0)].ownBytes) }.max() ?? 0
        }

        mutating func refresh() {
            guard dirty else { return }
            dirty = false
            // Contribution of each leaf.
            var contribution: [NodeID: UInt64] = [:]
            for id in liveLeaves() {
                nodes[Int(id)].flags.remove([.hardLink, .hardLinkSecondary])
                contribution[id] = nodes[Int(id)].ownBytes
            }
            for (_, members) in hardLinkGroups() {
                let primary = smallestPath(members)
                for member in members {
                    nodes[Int(member)].flags.insert(.hardLink)
                    if member != primary {
                        nodes[Int(member)].flags.insert(.hardLinkSecondary)
                        contribution[member] = 0
                    }
                }
            }
            if countClonesOnce {
                for (_, members) in cloneFamilies() {
                    let primary = smallestPath(members)
                    let shared = familyShared(members)
                    for member in members where !nodes[Int(member)].flags.contains(.hardLinkSecondary) {
                        let privateBytes = min(nodes[Int(member)].privateBytes, nodes[Int(member)].ownBytes)
                        contribution[member] = privateBytes + (member == primary ? shared : 0)
                    }
                }
            }
            // Post-order sums, iteratively: `subtree(0)` lists every parent before its children,
            // so walking it backwards visits children first (no recursion on deep trees).
            for id in subtree(0).reversed() {
                let node = nodes[Int(id)]
                guard node.flags.contains(.directory) else {
                    nodes[Int(id)].size = contribution[id] ?? 0
                    nodes[Int(id)].descendants = 0
                    continue
                }
                var total: UInt64 = 0
                var count: UInt32 = 0
                for child in node.children {
                    total += nodes[Int(child)].size
                    count += nodes[Int(child)].descendants + 1
                }
                nodes[Int(id)].size = total
                nodes[Int(id)].descendants = count
            }
            let snapshot = nodes
            for index in nodes.indices where !nodes[index].children.isEmpty {
                nodes[index].children.sort {
                    let a = snapshot[Int($0)], b = snapshot[Int($1)]
                    return a.size != b.size ? a.size > b.size : a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
                }
            }
        }
    }

    private let storage: Mutex<Storage>

    /// Empty tree with only the root directory.
    public init(rootPath: String, countClonesOnce: Bool = true) {
        let name = (rootPath as NSString).lastPathComponent
        storage = Mutex(Storage(
            rootPath: rootPath,
            countClonesOnce: countClonesOnce,
            nodes: [Node(name: name.isEmpty ? rootPath : name, flags: .directory, parent: nil)]
        ))
    }

    /// Tree built from a declarative description.
    public convenience init(rootPath: String, countClonesOnce: Bool = true, entries: [Entry]) {
        self.init(rootPath: rootPath, countClonesOnce: countClonesOnce)
        func add(_ entry: Entry, under parent: NodeID) {
            switch entry {
            case .dir(let name, let children):
                let id = addDirectory(name, under: parent)
                children.forEach { add($0, under: id) }
            case .package(let name, let children):
                let id = addDirectory(name, under: parent, flags: .package)
                children.forEach { add($0, under: id) }
            case .file(let name, let size):
                addFile(name, size: size, under: parent)
            case .symlink(let name):
                addSymlink(name, under: parent)
            case .restricted(let name):
                addRestricted(name, under: parent)
            }
        }
        entries.forEach { add($0, under: root) }
    }

    /// Snapshot of a real directory via the oracle walk: identities, hard links and restricted
    /// directories carry over; packages are detected by extension (`.app`, `.bundle`, `.framework`, ...).
    /// Clones are not detected (each counts its full allocation).
    public static func snapshot(of url: URL) throws -> InMemoryTree {
        let result = try Oracle.walk(url)
        let tree = InMemoryTree(rootPath: result.root, countClonesOnce: false)
        var ids: [String: NodeID] = [result.root: tree.root]
        for entry in result.entries {
            let parentPath = (entry.path as NSString).deletingLastPathComponent
            guard let parent = ids[parentPath] else { continue }
            let name = (entry.path as NSString).lastPathComponent
            switch entry.kind {
            case .directory:
                var flags: NodeFlags = []
                if entry.isRestricted { flags.insert(.restricted) }
                if entry.isMountPoint { flags.insert(.mountPoint) }
                if packageExtensions.contains((name as NSString).pathExtension.lowercased()) { flags.insert(.package) }
                ids[entry.path] = tree.addDirectory(name, under: parent, flags: flags, identity: entry.identity)
            case .symlink:
                tree.addSymlink(name, under: parent, size: entry.allocatedBytes, identity: entry.identity)
            case .file, .other:
                tree.addFile(name, size: entry.allocatedBytes, under: parent, identity: entry.identity)
            }
        }
        return tree
    }

    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "photoslibrary", "xcarchive",
        "sparsebundle", "rtfd", "pages", "numbers", "key", "fcpbundle", "musiclibrary",
        "imovielibrary", "xcodeproj", "playground",
    ]

    // MARK: Mutation

    private func insert(_ node: Node, under parent: NodeID) -> NodeID {
        storage.withLock { s in
            precondition(s.nodes[Int(parent)].flags.contains(.directory), "parent must be a directory")
            let id = NodeID(s.nodes.count)
            s.nodes.append(node)
            s.nodes[Int(parent)].children.append(id)
            s.generation += 1
            s.dirty = true
            return id
        }
    }

    @discardableResult
    public func addDirectory(_ name: String, under parent: NodeID, flags: NodeFlags = [], identity: FileIdentity? = nil) -> NodeID {
        insert(Node(name: name, flags: flags.union(.directory), parent: parent, identity: identity), under: parent)
    }

    /// Adds a file with `size` allocated bytes. Files sharing an `identity` are hard links of one inode.
    @discardableResult
    public func addFile(_ name: String, size: UInt64, under parent: NodeID, identity: FileIdentity? = nil, flags: NodeFlags = []) -> NodeID {
        insert(Node(name: name, flags: flags.subtracting(.directory), parent: parent, ownBytes: size, identity: identity), under: parent)
    }

    /// Adds another link to the inode of `target` (a file). Assigns a synthetic identity if needed.
    @discardableResult
    public func addHardLink(_ name: String, under parent: NodeID, to target: NodeID) -> NodeID {
        let (identity, bytes, family, privateBytes) = storage.withLock { s -> (FileIdentity, UInt64, UInt64?, UInt64) in
            if s.nodes[Int(target)].identity == nil {
                s.nodes[Int(target)].identity = FileIdentity(device: -1, inode: s.nextSyntheticInode)
                s.nextSyntheticInode += 1
            }
            let node = s.nodes[Int(target)]
            return (node.identity!, node.ownBytes, node.cloneFamily, node.privateBytes)
        }
        var node = Node(name: name, flags: [], parent: parent, ownBytes: bytes, identity: identity)
        node.cloneFamily = family
        node.privateBytes = privateBytes
        return insert(node, under: parent)
    }

    /// Adds an APFS clone of `source` (a file) that owns `privateBytes` of its own allocation.
    @discardableResult
    public func addClone(_ name: String, under parent: NodeID, of source: NodeID, privateBytes: UInt64 = 0) -> NodeID {
        let (family, bytes) = storage.withLock { s -> (UInt64, UInt64) in
            if s.nodes[Int(source)].cloneFamily == nil {
                s.nodes[Int(source)].cloneFamily = s.nextCloneFamily
                s.nodes[Int(source)].flags.insert(.cloned)
                s.nextCloneFamily += 1
            }
            return (s.nodes[Int(source)].cloneFamily!, s.nodes[Int(source)].ownBytes)
        }
        var node = Node(name: name, flags: .cloned, parent: parent, ownBytes: bytes)
        node.cloneFamily = family
        node.privateBytes = privateBytes
        return insert(node, under: parent)
    }

    /// Sets how many bytes of a clone member are private (not shared with its family).
    public func setPrivateBytes(_ id: NodeID, _ bytes: UInt64) {
        storage.withLock { s in
            s.nodes[Int(id)].privateBytes = bytes
            s.generation += 1
            s.dirty = true
        }
    }

    @discardableResult
    public func addSymlink(_ name: String, under parent: NodeID, size: UInt64 = 0, identity: FileIdentity? = nil) -> NodeID {
        insert(Node(name: name, flags: .symlink, parent: parent, ownBytes: size, identity: identity), under: parent)
    }

    @discardableResult
    public func addRestricted(_ name: String, under parent: NodeID) -> NodeID {
        insert(Node(name: name, flags: [.directory, .restricted], parent: parent), under: parent)
    }

    /// Removes `id` and its descendants (ids stay reserved). Ancestor sizes update. Root cannot be removed.
    public func removeSubtree(_ id: NodeID) {
        storage.withLock { s in
            guard let parent = s.nodes[Int(id)].parent else { return }
            s.nodes[Int(id)].removed = true
            s.nodes[Int(parent)].children.removeAll { $0 == id }
            s.generation += 1
            s.dirty = true
        }
    }

    /// Flags `id` as missing (vanished from disk) without removing it.
    public func markMissing(_ id: NodeID) {
        storage.withLock { s in
            s.nodes[Int(id)].flags.insert(.missing)
            s.generation += 1
        }
    }

    // MARK: TreeReading

    private func read<T>(_ body: (Storage) -> T) -> T {
        storage.withLock { s in
            s.refresh()
            return body(s)
        }
    }

    public var root: NodeID { 0 }
    public var generation: UInt64 { storage.withLock { $0.generation } }

    public func name(_ id: NodeID) -> String { read { $0.nodes[Int(id)].name } }
    public func path(_ id: NodeID) -> String { read { $0.path(id) } }
    public func size(_ id: NodeID) -> UInt64 { read { $0.isLive(id) ? $0.nodes[Int(id)].size : 0 } }
    public func flags(_ id: NodeID) -> NodeFlags { read { $0.nodes[Int(id)].flags } }
    public func parent(_ id: NodeID) -> NodeID? { read { $0.nodes[Int(id)].parent } }
    public func children(_ id: NodeID) -> [NodeID] { read { $0.nodes[Int(id)].children } }
    public func descendantCount(_ id: NodeID) -> UInt32 { read { $0.nodes[Int(id)].descendants } }
    public func identity(_ id: NodeID) -> FileIdentity? { read { $0.nodes[Int(id)].identity } }

    public func node(atPath path: String) -> NodeID? {
        read { s in
            let rootPath = s.rootPath
            if path == rootPath { return 0 }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { return nil }
            var current: NodeID = 0
            for component in path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true) {
                guard let next = s.nodes[Int(current)].children.first(where: { s.nodes[Int($0)].name == component }) else {
                    return nil
                }
                current = next
            }
            return current
        }
    }

    public func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 {
        read { s in
            guard s.isLive(id) else { return 0 }
            let mine = s.subtree(id)
            var removal = Set(mine)
            for other in others where s.isLive(other) { removal.formUnion(s.subtree(other)) }
            let groups = s.hardLinkGroups()
            let families = s.countClonesOnce ? s.cloneFamilies() : [:]
            var seenInodes = Set<FileIdentity>()
            var seenFamilies = Set<UInt64>()
            var total: UInt64 = 0
            for leaf in mine where !s.nodes[Int(leaf)].flags.contains(.directory) {
                let node = s.nodes[Int(leaf)]
                if let identity = node.identity, let members = groups[identity] {
                    // A hard-linked inode is freed only when every link goes.
                    guard members.allSatisfy(removal.contains), seenInodes.insert(identity).inserted else { continue }
                }
                if let family = node.cloneFamily, let members = families[family] {
                    total += min(node.privateBytes, node.ownBytes)
                    if members.allSatisfy(removal.contains), seenFamilies.insert(family).inserted {
                        total += s.familyShared(members)
                    }
                } else {
                    total += node.ownBytes
                }
            }
            return total
        }
    }
}
