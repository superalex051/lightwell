import Foundation

/// Position in a paged child listing. A cursor is only valid for the tree generation it was
/// made for: after any mutation it is stale and the listing must restart.
public struct PageCursor: Sendable, Hashable, Codable {
    public var parent: NodeID
    public var generation: UInt64
    public var offset: Int

    public init(parent: NodeID, generation: UInt64, offset: Int) {
        self.parent = parent
        self.generation = generation
        self.offset = offset
    }

    /// Compact text form for tool results ("parent.generation.offset").
    public var token: String { "\(parent).\(generation).\(offset)" }

    public init?(token: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let parent = NodeID(parts[0]), let generation = UInt64(parts[1]), let offset = Int(parts[2]), offset >= 0
        else { return nil }
        self.init(parent: parent, generation: generation, offset: offset)
    }
}

/// One page of a directory's children (sorted largest first).
public struct ChildrenPage: Sendable, Hashable {
    public var parent: NodeID
    public var generation: UInt64
    public var offset: Int
    /// Total number of children of `parent`.
    public var total: Int
    public var items: [ItemSummary]
    /// Cursor for the next page, `nil` on the last page.
    public var next: PageCursor?
}

public enum QueryError: Error, Sendable, Hashable {
    /// The tree changed since the cursor was made; restart from the first page.
    case staleCursor(cursorGeneration: UInt64, treeGeneration: UInt64)
    /// The cursor belongs to another directory.
    case cursorMismatch
    case nodeNotFound(NodeID)
}

/// Flags of nodes that stand for content the scan could not read.
let placeholderFlags: NodeFlags = [.restricted, .mountPoint, .firmlinkSkipped, .notResponding]

// MARK: Access abstraction (fast path for ScanTree, generic path for any TreeReading)

protocol TreeAccess {
    func size(_ id: NodeID) -> UInt64
    func isDirectory(_ id: NodeID) -> Bool
    func isPackage(_ id: NodeID) -> Bool
    /// Placeholder nodes with no readable content: restricted, mount point, firmlink-skipped or
    /// not responding.
    func isPlaceholder(_ id: NodeID) -> Bool
    /// Calls `body` for each child, largest first, until it returns false.
    func forEachChild(_ id: NodeID, _ body: (NodeID) -> Bool)
    func withName<T>(_ id: NodeID, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T
}

/// Direct arena access; only valid while the tree's read lock is held.
struct ArenaAccess: TreeAccess {
    let tree: ScanTree

    func size(_ id: NodeID) -> UInt64 { tree.node(id).size }
    func isDirectory(_ id: NodeID) -> Bool { tree.node(id).flags & NodeFlags.directory.rawValue != 0 }
    func isPackage(_ id: NodeID) -> Bool { tree.node(id).flags & NodeFlags.package.rawValue != 0 }
    func isPlaceholder(_ id: NodeID) -> Bool { tree.node(id).flags & placeholderFlags.rawValue != 0 }

    func forEachChild(_ id: NodeID, _ body: (NodeID) -> Bool) {
        let node = tree.node(id)
        let first = Int(node.firstChild)
        for offset in 0..<Int(node.childCount) {
            if !body(tree.arena.childIndex[first + offset]) { return }
        }
    }

    func withName<T>(_ id: NodeID, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        body(tree.nameBytes(id))
    }
}

struct GenericAccess: TreeAccess {
    let tree: any TreeReading

    func size(_ id: NodeID) -> UInt64 { tree.size(id) }
    func isDirectory(_ id: NodeID) -> Bool { tree.flags(id).contains(.directory) }
    func isPackage(_ id: NodeID) -> Bool { tree.flags(id).contains(.package) }
    func isPlaceholder(_ id: NodeID) -> Bool { !tree.flags(id).isDisjoint(with: placeholderFlags) }

    func forEachChild(_ id: NodeID, _ body: (NodeID) -> Bool) {
        for child in tree.children(id) where !body(child) { return }
    }

    func withName<T>(_ id: NodeID, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        var name = tree.name(id)
        return name.withUTF8 { body($0) }
    }
}

/// Fixed-size min-heap that keeps the `limit` largest (size, id) pairs.
struct TopK {
    let limit: Int
    private(set) var items: [(size: UInt64, id: NodeID)] = []

    init(limit: Int) {
        self.limit = max(0, limit)
        items.reserveCapacity(self.limit)
    }

    var isFull: Bool { items.count >= limit }
    /// Smallest kept size (only meaningful when full).
    var floor: UInt64 { items.first?.size ?? 0 }

    mutating func offer(_ size: UInt64, _ id: NodeID) {
        guard limit > 0 else { return }
        if items.count < limit {
            items.append((size, id))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(items[child], items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        } else if precedes(items[0], (size, id)) {
            items[0] = (size, id)
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count && precedes(items[left], items[smallest]) { smallest = left }
                if right < items.count && precedes(items[right], items[smallest]) { smallest = right }
                if smallest == parent { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
    }

    /// Min-heap order: smaller size first; ties keep the lower id.
    private func precedes(_ a: (size: UInt64, id: NodeID), _ b: (size: UInt64, id: NodeID)) -> Bool {
        a.size != b.size ? a.size < b.size : a.id > b.id
    }

    /// Largest first; ties by id.
    func sorted() -> [NodeID] {
        items.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }.map(\.id)
    }
}

enum QueryAlgorithms {
    /// Largest leaf items (files, symlinks, packages as one item) under `id`.
    static func largest<A: TreeAccess>(_ access: A, under id: NodeID, limit: Int, minBytes: UInt64) -> [NodeID] {
        var top = TopK(limit: limit)
        var stack: [NodeID] = []
        access.forEachChild(id) { stack.append($0); return true }
        while let next = stack.popLast() {
            let size = access.size(next)
            if size < minBytes || (top.isFull && size <= top.floor) { continue }
            if access.isDirectory(next) && !access.isPackage(next) {
                access.forEachChild(next) { child in
                    let childSize = access.size(child)
                    // Children are sorted largest first: once one is too small, the rest are too.
                    if childSize < minBytes || (top.isFull && childSize <= top.floor) { return false }
                    stack.append(child)
                    return true
                }
            } else if !access.isPlaceholder(next) {
                // Placeholders themselves are never items, but a placeholder folder that kept
                // earlier children (a timed-out refresh) is still descended above.
                top.offer(size, next)
            }
        }
        return top.sorted()
    }

    /// Nodes under `id` whose name contains `text` (case-insensitive), largest first.
    static func search<A: TreeAccess>(_ access: A, text: String, under id: NodeID, limit: Int, minBytes: UInt64) -> [NodeID] {
        let needle = Array(text.utf8)
        guard !needle.isEmpty else { return [] }
        let isASCII = needle.allSatisfy { $0 < 0x80 }
        let lowered = needle.map(asciiLower)
        let matches: (UnsafeBufferPointer<UInt8>) -> Bool
        if isASCII {
            matches = { name in containsASCIIInsensitive(name, lowered) }
        } else {
            matches = { name in
                String(decoding: name, as: UTF8.self).range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        var top = TopK(limit: limit)
        var stack: [NodeID] = []
        access.forEachChild(id) { stack.append($0); return true }
        while let next = stack.popLast() {
            let size = access.size(next)
            if size < minBytes || (top.isFull && size <= top.floor) { continue }
            if access.withName(next, matches) { top.offer(size, next) }
            if access.isDirectory(next) {
                access.forEachChild(next) { child in
                    let childSize = access.size(child)
                    if childSize < minBytes || (top.isFull && childSize <= top.floor) { return false }
                    stack.append(child)
                    return true
                }
            }
        }
        return top.sorted()
    }

    @inline(__always)
    static func asciiLower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte }

    static func containsASCIIInsensitive(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = haystack.count
        guard n <= h else { return false }
        let first = needle[0]
        var start = 0
        while start <= h - n {
            if asciiLower(haystack[start]) == first {
                var matched = 1
                while matched < n && asciiLower(haystack[start + matched]) == needle[matched] { matched += 1 }
                if matched == n { return true }
            }
            start += 1
        }
        return false
    }
}

// MARK: Public query API (WS2)

extension TreeReading {
    /// The `limit` largest files under `id` (files, symlinks; packages count as one item and are
    /// not descended), largest first. Items smaller than `minBytes` are skipped.
    public func largest(
        under id: NodeID, limit: Int, minBytes: UInt64 = 0, builder: ItemSummaryBuilder = .standard
    ) -> [ItemSummary] {
        let ids: [NodeID]
        if let scan = self as? ScanTree {
            ids = scan.withReadLock { QueryAlgorithms.largest(ArenaAccess(tree: scan), under: id, limit: limit, minBytes: minBytes) }
        } else {
            ids = QueryAlgorithms.largest(GenericAccess(tree: self), under: id, limit: limit, minBytes: minBytes)
        }
        return ids.map { builder.summary(of: $0, in: self) }
    }

    /// Items under `id` (files and folders) whose name contains `text`, ignoring case
    /// (and diacritics for non-ASCII text), largest first.
    public func search(
        _ text: String, under id: NodeID, limit: Int, minBytes: UInt64 = 0, builder: ItemSummaryBuilder = .standard
    ) -> [ItemSummary] {
        let ids: [NodeID]
        if let scan = self as? ScanTree {
            ids = scan.withReadLock { QueryAlgorithms.search(ArenaAccess(tree: scan), text: text, under: id, limit: limit, minBytes: minBytes) }
        } else {
            ids = QueryAlgorithms.search(GenericAccess(tree: self), text: text, under: id, limit: limit, minBytes: minBytes)
        }
        return ids.map { builder.summary(of: $0, in: self) }
    }

    /// One page of the children of `id`, largest first. Pass the previous page's `next` cursor
    /// to continue; a cursor from an older generation throws `QueryError.staleCursor`.
    public func children(
        of id: NodeID, limit: Int, after cursor: PageCursor? = nil, builder: ItemSummaryBuilder = .standard
    ) throws -> ChildrenPage {
        if let cursor, cursor.parent != id { throw QueryError.cursorMismatch }
        let (generation, all): (UInt64, [NodeID])
        if let scan = self as? ScanTree {
            (generation, all) = scan.withReadLock { (scan.generation, scan.isValid(id) && !scan.isRemoved(id) ? scan.childIDs(id) : []) }
        } else {
            var snapshot = (self.generation, children(id))
            if snapshot.0 != self.generation { snapshot = (self.generation, children(id)) }
            (generation, all) = snapshot
        }
        if let cursor, cursor.generation != generation {
            throw QueryError.staleCursor(cursorGeneration: cursor.generation, treeGeneration: generation)
        }
        let offset = min(cursor?.offset ?? 0, all.count)
        let end = min(all.count, offset + max(0, limit))
        let items = all[offset..<end].map { builder.summary(of: $0, in: self) }
        let next = end < all.count ? PageCursor(parent: id, generation: generation, offset: end) : nil
        return ChildrenPage(parent: id, generation: generation, offset: offset, total: all.count, items: items, next: next)
    }
}
