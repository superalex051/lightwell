import Darwin
import Foundation
import IPCProtocol
import ScanKit

/// Read-only queries over any `TreeReading` for the assistant tools (PLAN 3.7). They rely only on
/// the tree conventions (aggregated sizes, children sorted by size descending), never touch the
/// disk and are safe to run off the main actor.
enum ToolQueries {
    /// Whether `node` passes the `kind` filter. Packages count as directories (one item).
    static func matches(_ flags: NodeFlags, kind: ItemKindFilter) -> Bool {
        switch kind {
        case .any: return true
        case .directory: return flags.contains(.directory) || flags.contains(.package)
        case .file: return !flags.contains(.directory) && !flags.contains(.package)
        }
    }

    /// Whether the walk goes inside `node`: real folders only (packages are one item, symlinks are
    /// never followed, mount points are leaves).
    static func descends(_ flags: NodeFlags) -> Bool {
        flags.contains(.directory) && !flags.contains(.package) && !flags.contains(.symlink)
    }

    /// The `count` largest items under `root` (not including it), largest first, ties by node id.
    /// `descendants` walks the whole subtree with pruning: a folder smaller than the current
    /// smallest kept item cannot hold anything larger, so its subtree is skipped.
    static func largest(in tree: any TreeReading, under root: NodeID, count: Int, minBytes: UInt64, kind: ItemKindFilter, descendants: Bool) -> [NodeID] {
        guard count > 0 else { return [] }
        if !descendants {
            return tree.children(root).filter { tree.size($0) >= minBytes && matches(tree.flags($0), kind: kind) }.prefix(count).map { $0 }
        }
        var heap = BoundedTopK(capacity: count)
        var stack: [NodeID] = [root]
        while let current = stack.popLast() {
            for child in tree.children(current) {
                let size = tree.size(child)
                // Children are sorted by size, so every later sibling is at most this big.
                if size < minBytes || !heap.couldAccept(size) { break }
                let flags = tree.flags(child)
                if matches(flags, kind: kind) { heap.insert(child, size: size) }
                if descends(flags) { stack.append(child) }
            }
        }
        return heap.sortedDescending()
    }

    /// Search under `root` by name glob, extension and size. Returns the `count` largest matches,
    /// largest first, keeping only a bounded top list while walking (no list of every match).
    static func search(in tree: any TreeReading, under root: NodeID, nameGlob: String?, extension ext: String?, minBytes: UInt64, count: Int) -> [NodeID] {
        guard count > 0 else { return [] }
        let glob = nameGlob.map { $0.lowercased() }
        let suffix = ext.map { "." + $0.lowercased() }
        var heap = BoundedTopK(capacity: count)
        var stack: [NodeID] = [root]
        while let current = stack.popLast() {
            for child in tree.children(current) {
                let size = tree.size(child)
                // Children are sorted by size: nothing later (or inside) can reach min_bytes or the top list.
                if size < minBytes || !heap.couldAccept(size) { break }
                let flags = tree.flags(child)
                if heap.couldAccept(size) {
                    let name = tree.name(child).lowercased()
                    var ok = true
                    if let suffix, !name.hasSuffix(suffix) { ok = false }
                    if ok, let glob, fnmatch(glob, name, 0) != 0 { ok = false }
                    if ok { heap.insert(child, size: size) }
                }
                if descends(flags) { stack.append(child) }
            }
        }
        return heap.sortedDescending()
    }

    /// Children of `node` in the requested order.
    static func children(in tree: any TreeReading, of node: NodeID, sort: ChildSort) -> [NodeID] {
        let children = tree.children(node)
        switch sort {
        case .size: return children
        case .name:
            return children
                .map { ($0, tree.name($0)) }
                .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
                .map(\.0)
        }
    }

    /// Offset encoded in a cursor (0 when absent or unreadable; `ToolOutput.page` reports bad cursors).
    static func offset(of cursor: String?) -> Int {
        guard let cursor, !cursor.isEmpty, let parsed = ToolCursor(token: cursor) else { return 0 }
        return max(parsed.offset, 0)
    }
}

/// Keeps the `capacity` largest (node, size) pairs.
struct BoundedTopK {
    let capacity: Int
    private var heap: [(node: NodeID, size: UInt64)] = []

    init(capacity: Int) {
        self.capacity = capacity
        heap.reserveCapacity(min(capacity, 4096))
    }

    /// False when full and `size` is not larger than the smallest kept item.
    func couldAccept(_ size: UInt64) -> Bool {
        heap.count < capacity || size > heap[0].size
    }

    mutating func insert(_ node: NodeID, size: UInt64) {
        if heap.count < capacity {
            heap.append((node, size))
            siftUp(heap.count - 1)
        } else if size > heap[0].size {
            heap[0] = (node, size)
            siftDown(0)
        }
    }

    func sortedDescending() -> [NodeID] {
        heap.sorted { $0.size != $1.size ? $0.size > $1.size : $0.node < $1.node }.map(\.node)
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].size < heap[parent].size else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].size < heap[smallest].size { smallest = left }
            if right < heap.count, heap[right].size < heap[smallest].size { smallest = right }
            guard smallest != parent else { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
