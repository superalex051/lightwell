import Foundation

/// Flat description of one node, used by lists, the queue and assistant tools. Frozen contract (PLAN 4.3).
public struct ItemSummary: Sendable, Codable, Hashable {
    public var nodeID: NodeID
    public var path: String
    public var name: String
    public var bytes: UInt64
    /// Reclaimable estimate if this item alone were removed.
    public var freesAbout: UInt64
    public var kind: ItemKind
    /// Number of descendants (0 for files).
    public var items: UInt32
    /// Scan-time `(dev, ino)`, so the cleanup executor can refuse items that changed since the
    /// scan. Added by WS1 (controller request).
    public var identity: FileIdentity?

    public init(
        nodeID: NodeID, path: String, name: String, bytes: UInt64, freesAbout: UInt64, kind: ItemKind, items: UInt32,
        identity: FileIdentity? = nil
    ) {
        self.nodeID = nodeID
        self.path = path
        self.name = name
        self.bytes = bytes
        self.freesAbout = freesAbout
        self.kind = kind
        self.items = items
        self.identity = identity
    }
}

/// Builds `ItemSummary` values. `freesAbout` is a hook for the reclaimable estimate: by default it
/// is `reclaimableBytes(id, ifAlsoRemoving: [])`; CleanupKit can pass one that accounts for the
/// items already queued.
public struct ItemSummaryBuilder: Sendable {
    public var freesAbout: (@Sendable (any TreeReading, NodeID) -> UInt64)?

    public init(freesAbout: (@Sendable (any TreeReading, NodeID) -> UInt64)? = nil) {
        self.freesAbout = freesAbout
    }

    public static let standard = ItemSummaryBuilder()

    public func summary(of id: NodeID, in tree: any TreeReading) -> ItemSummary {
        ItemSummary(
            nodeID: id,
            path: tree.path(id),
            name: tree.name(id),
            bytes: tree.size(id),
            freesAbout: freesAbout?(tree, id) ?? tree.reclaimableBytes(id, ifAlsoRemoving: []),
            kind: ItemKind(flags: tree.flags(id)),
            items: tree.descendantCount(id),
            identity: tree.identity(id)
        )
    }
}

extension TreeReading {
    /// Summary of one node.
    public func summary(of id: NodeID) -> ItemSummary {
        ItemSummaryBuilder.standard.summary(of: id, in: self)
    }

    /// Summary of one node with a custom `freesAbout` hook.
    public func summary(of id: NodeID, using builder: ItemSummaryBuilder) -> ItemSummary {
        builder.summary(of: id, in: self)
    }

    /// Ancestors from the root down to and including `id`.
    public func ancestry(of id: NodeID) -> [NodeID] {
        var chain: [NodeID] = [id]
        var cursor = parent(id)
        while let c = cursor {
            chain.append(c)
            cursor = parent(c)
        }
        return chain.reversed()
    }
}
