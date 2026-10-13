import Foundation

/// Counts over a tree, for benchmarks and diagnostics. Added by WS1.
public struct ScanStatistics: Sendable, Hashable, Codable {
    /// Live nodes including the root.
    public var nodes: Int
    public var directories: Int
    public var files: Int
    public var symlinks: Int
    public var restricted: Int
    public var mountPoints: Int
    public var packages: Int
    /// Hard-linked inodes with more than one link inside the tree.
    public var hardLinkGroups: Int
    /// Clone families with more than one member inside the tree.
    public var cloneFamilies: Int
    /// Bytes held by the tree (`ScanTree.storageBytes`).
    public var storageBytes: Int
}

extension ScanTree {
    public func statistics() -> ScanStatistics {
        let storage = storageBytes
        return lock.read {
            var stats = ScanStatistics(
                nodes: 0, directories: 0, files: 0, symlinks: 0, restricted: 0, mountPoints: 0, packages: 0,
                hardLinkGroups: hardLinks.values.filter { $0.members.count > 1 }.count,
                cloneFamilies: cloneFamilies.filter { $0.members.count > 1 }.count,
                storageBytes: storage
            )
            for index in 0..<arena.nodeCount {
                let flags = arena.nodes[index].flags
                if flags & NodeBits.removed != 0 { continue }
                stats.nodes += 1
                if flags & NodeFlags.directory.rawValue != 0 {
                    stats.directories += 1
                    if flags & NodeFlags.restricted.rawValue != 0 { stats.restricted += 1 }
                    if flags & NodeFlags.mountPoint.rawValue != 0 { stats.mountPoints += 1 }
                    if flags & NodeFlags.package.rawValue != 0 { stats.packages += 1 }
                } else if flags & NodeFlags.symlink.rawValue != 0 {
                    stats.symlinks += 1
                } else {
                    stats.files += 1
                }
            }
            return stats
        }
    }
}
