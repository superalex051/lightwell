import Foundation
import RulesKit
import ScanKit

/// Who put an item in the cleanup queue.
public enum QueueSource: Codable, Sendable, Hashable {
    case user
    /// Added from a Reclaim category (rule id).
    case category(String)
    /// Proposed by the assistant in `thread` with the model's stated reason.
    case assistant(thread: UUID, reason: String)

    public var isAssistant: Bool {
        if case .assistant = self { true } else { false }
    }
}

/// One row of the cleanup queue. Frozen contract (PLAN 4.3).
public struct QueueItem: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    public var nodeID: NodeID?
    /// `(dev, ino)` of the item at scan time. `CleanupExecutor` compares it with the item on disk
    /// right before acting and refuses on any mismatch (`changedSinceScan`). A nil identity is
    /// never trusted: the executor refuses the item (`notInScan`) instead of skipping the check.
    /// Build items from scan results (`init(node:in:...)` or `ItemSummary.identity`).
    public var identity: FileIdentity?
    public var bytes: UInt64
    public var freesAbout: UInt64
    public var risk: Risk
    public var ruleID: String?
    public var source: QueueSource
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        nodeID: NodeID? = nil,
        identity: FileIdentity? = nil,
        bytes: UInt64,
        freesAbout: UInt64,
        risk: Risk,
        ruleID: String? = nil,
        source: QueueSource,
        isSelected: Bool
    ) {
        self.id = id
        self.path = path
        self.nodeID = nodeID
        self.identity = identity
        self.bytes = bytes
        self.freesAbout = freesAbout
        self.risk = risk
        self.ruleID = ruleID
        self.source = source
        self.isSelected = isSelected
    }

    /// Additive: an item for `node`, with path, identity, size and reclaimable estimate taken from
    /// the tree. Assistant items start unselected; others start selected unless told otherwise.
    public init(node: NodeID, in tree: any TreeReading, risk: Risk, ruleID: String? = nil, source: QueueSource, isSelected: Bool? = nil) {
        self.init(
            path: tree.path(node),
            nodeID: node,
            identity: tree.identity(node),
            bytes: tree.size(node),
            freesAbout: tree.reclaimableBytes(node, ifAlsoRemoving: []),
            risk: risk,
            ruleID: ruleID,
            source: source,
            isSelected: source.isAssistant ? false : (isSelected ?? true)
        )
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Outcome of adding an item to the queue.
public enum AddResult: Sendable, Hashable {
    case added(UUID)
    case alreadyQueued(UUID)
    /// An ancestor folder is already queued (its path).
    case coveredByParent(String)
    case blocked(BlockReason)
    /// Additive: a dangerous item (or a folder holding one) proposed by the assistant. PLAN 2.5:
    /// assistant proposals of dangerous items are rejected; only the user can queue them.
    case needsUserChoice
    /// Additive: an assistant folder proposal that holds rows the user chose (queued by the user
    /// or from a category, or ticked by the user); their paths. The folder is not queued and the
    /// user's rows and ticks stay as they are.
    case containsUserItems([String])
}

/// Pure queue model (staging only, nothing touches the disk): dedupe parent and child, totals,
/// reclaimable estimates. Policy checks happen in the caller (`SafetyPolicy`) and again in the executor.
public struct CleanupQueue: Sendable, Hashable, Codable {
    public private(set) var items: [QueueItem] = []

    public init(items: [QueueItem] = []) {
        self.items = items
    }

    /// Adds `item`. A duplicate path is `alreadyQueued`; a child of a queued folder is
    /// `coveredByParent`; adding a folder absorbs (removes) its queued descendants.
    /// Assistant items always arrive unselected, and dangerous or never assistant items are refused.
    /// An assistant folder never absorbs the user's rows (`containsUserItems`): it is refused and
    /// the user's rows and ticks stay; it absorbs only unticked assistant rows.
    @discardableResult
    public mutating func add(_ item: QueueItem) -> AddResult {
        var item = item
        item.path = Self.normalized(item.path)
        if item.source.isAssistant && item.risk >= .dangerous { return .needsUserChoice }
        if let existing = items.first(where: { $0.path == item.path }) {
            return .alreadyQueued(existing.id)
        }
        if let parent = items.first(where: { Self.isDescendant(item.path, of: $0.path) }) {
            return .coveredByParent(parent.path)
        }
        if item.source.isAssistant {
            let usersRows = items.filter { Self.isDescendant($0.path, of: item.path) && (!$0.source.isAssistant || $0.isSelected) }
            if !usersRows.isEmpty { return .containsUserItems(usersRows.map(\.path)) }
            item.isSelected = false
        }
        items.removeAll { Self.isDescendant($0.path, of: item.path) }
        items.append(item)
        return .added(item.id)
    }

    /// Additive: checks `policy` first. Protected items, and folders with a protected path of the
    /// table inside, are `.blocked`; dangerous ones proposed by the assistant are `.needsUserChoice`.
    /// (For pattern classes found anywhere in a folder, also check
    /// `RuleEngine.protectedDescendant(of:in:)` with the scan tree.)
    @discardableResult
    public mutating func add(_ item: QueueItem, checkedBy policy: SafetyPolicy, volume: VolumeInfo? = nil) -> AddResult {
        let classification = policy.check(path: item.path, isDirectory: true, volume: volume)
        if let block = classification.block { return .blocked(block) }
        if item.source.isAssistant && classification.risk >= .dangerous { return .needsUserChoice }
        if let nested = policy.protectedDescendant(of: item.path) {
            if let block = nested.classification.block { return .blocked(block) }
            if item.source.isAssistant { return .needsUserChoice }
        }
        return add(item)
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func setSelected(_ id: UUID, _ selected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected = selected
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    /// Additive: removes the items a run succeeded on.
    public mutating func apply(_ report: DeletionReport) {
        let done = Set(report.succeeded.map(\.itemID))
        items.removeAll { done.contains($0.id) }
    }

    /// Additive: recomputes `freesAbout` against the tree (PLAN 2.7 step 2). A hard-linked file or
    /// a clone family frees its shared bytes only when every member is selected, and those bytes
    /// are credited once, to the last selected member in queue order, so the selected total never
    /// double counts. An unselected item shows what selecting it would add.
    public mutating func refreshEstimates(using tree: any TreeReading) {
        let allSelected = Set(items.filter(\.isSelected).compactMap(\.nodeID))
        var earlier: Set<NodeID> = []
        for index in items.indices {
            guard let node = items[index].nodeID else { continue }
            if items[index].isSelected {
                items[index].freesAbout = tree.reclaimableBytes(node, ifAlsoRemoving: earlier)
                earlier.insert(node)
            } else {
                items[index].freesAbout = tree.reclaimableBytes(node, ifAlsoRemoving: allSelected)
            }
        }
    }

    public var selected: [QueueItem] { items.filter(\.isSelected) }
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    public var selectedBytes: UInt64 { selected.reduce(0) { $0 + $1.bytes } }
    public var selectedFreesAbout: UInt64 { selected.reduce(0) { $0 + $1.freesAbout } }
    /// Additive: selected item count per risk (for the confirm sheet).
    public var selectedCountByRisk: [Risk: Int] { selected.reduce(into: [:]) { $0[$1.risk, default: 0] += 1 } }
    /// Additive: selected items that need a per-item acknowledgement before running.
    public var selectedNeedingAcknowledgement: [QueueItem] { selected.filter { $0.risk >= .dangerous } }

    static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        return path.count > prefix.count && path.hasPrefix(prefix)
    }
}
