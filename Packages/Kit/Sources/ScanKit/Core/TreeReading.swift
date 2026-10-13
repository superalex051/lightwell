import Foundation

/// Read access to a scanned tree. Implemented by `ScanTree` (real scanner) and
/// `TestSupport.InMemoryTree` (fake for tests). Frozen contract (PLAN 4.3).
///
/// Conventions every implementation follows:
/// - `children(_:)` is sorted by size, largest first (ties by name).
/// - `size(_:)` is the aggregated size with hard-link and clone dedupe applied.
/// - `path(_:)` is an absolute POSIX path.
/// - `generation` increases on every mutation.
/// - Node ids stay valid for the life of the tree, with one exception: a full rescan of the root
///   swapped in by `TreeRefresher` reassigns every id. It is signalled by
///   `RefreshEvent.restructured(epoch:)` and by a change of `ScanTree.structureEpoch`; holders of
///   node ids (selection, navigation stacks, queue items) must resolve them again by path then.
public protocol TreeReading: AnyObject, Sendable {
    var root: NodeID { get }
    var generation: UInt64 { get }

    func name(_ id: NodeID) -> String
    func path(_ id: NodeID) -> String
    func size(_ id: NodeID) -> UInt64
    func flags(_ id: NodeID) -> NodeFlags
    func parent(_ id: NodeID) -> NodeID?
    func children(_ id: NodeID) -> [NodeID]
    func descendantCount(_ id: NodeID) -> UInt32
    func node(atPath path: String) -> NodeID?

    /// Bytes freed by removing `id`, given that the nodes in `ifAlsoRemoving` are removed too
    /// (hard links and clone families only free their shared bytes when every member goes).
    func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64
    func identity(_ id: NodeID) -> FileIdentity?
}
