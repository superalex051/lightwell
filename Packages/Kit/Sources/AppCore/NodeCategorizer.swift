import Foundation
import RulesKit
import ScanKit
import Synchronization

/// Colour family of a scan node for the space map and the capacity bar (design A has nine).
/// The raw values are the ids the app's palette understands (`MapTile.category`).
public enum SpaceFamily: String, Sendable, Hashable, CaseIterable {
    case projects
    case developer
    case apps
    case appData
    case media
    case caches
    case downloads
    case system
    case other

    /// Family for a RulesKit category id (`Rule.categoryID`). Ids that already are families map to
    /// themselves; the others follow the app's palette vocabulary.
    public init(ruleCategory: String) {
        if let family = SpaceFamily(rawValue: ruleCategory) {
            self = family
            return
        }
        switch ruleCategory {
        case "packages": self = .caches
        case "logs", "trash": self = .system
        case "containers": self = .developer
        case "ai", "devices", "mail": self = .appData
        case "cloud": self = .projects
        default: self = .other
        }
    }
}

/// Classifies scan nodes into `SpaceFamily` values: knowledge-base categories first (a category
/// that only maps to `.other` never hides a name match), then a small name heuristic, looking at
/// the node and its ancestors. Lookups are memoized, so list rows and map tiles are amortized O(1).
/// Thread safe; the map may call it while laying out.
public final class NodeCategorizer: Sendable {
    public let tree: any TreeReading
    private let explicit: [NodeID: SpaceFamily]
    private let rootIsVolumeRoot: Bool
    private let memo = Mutex<[NodeID: SpaceFamily?]>([:])

    public init(tree: any TreeReading, categories: [CategoryResult]) {
        self.tree = tree
        var explicit: [NodeID: SpaceFamily] = [:]
        for category in categories {
            let family = SpaceFamily(ruleCategory: category.categoryID)
            for node in category.nodes where explicit[node] == nil { explicit[node] = family }
        }
        self.explicit = explicit
        self.rootIsVolumeRoot = tree.path(tree.root) == "/"
    }

    /// Family of `node`, from the node or its nearest classified ancestor. Nil when nothing is known.
    public func family(of node: NodeID) -> SpaceFamily? {
        if let hit = memo.withLock({ $0[node] }) { return hit }
        var visited: [NodeID] = []
        var cursor: NodeID? = node
        var found: SpaceFamily?
        while let id = cursor {
            if let hit = memo.withLock({ $0[id] }) {
                found = hit
                break
            }
            visited.append(id)
            if let own = own(id) {
                found = own
                break
            }
            cursor = tree.parent(id)
        }
        memo.withLock { table in for id in visited { table[id] = .some(found) } }
        return found
    }

    /// Bytes per family under `root`, walking down until each subtree has a family.
    public func breakdown(of root: NodeID, maxDepth: Int = 6) -> [SpaceFamily: UInt64] {
        var totals: [SpaceFamily: UInt64] = [:]
        var stack: [(NodeID, Int)] = tree.children(root).map { ($0, 1) }
        while let (id, depth) = stack.popLast() {
            if let family = own(id) {
                totals[family, default: 0] += tree.size(id)
                continue
            }
            let children = tree.children(id)
            if children.isEmpty || depth >= maxDepth {
                totals[.other, default: 0] += tree.size(id)
            } else {
                let childBytes = children.reduce(UInt64(0)) { $0 + tree.size($1) }
                let own = tree.size(id) > childBytes ? tree.size(id) - childBytes : 0
                if own > 0 { totals[.other, default: 0] += own }
                stack.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return totals
    }

    private func own(_ id: NodeID) -> SpaceFamily? {
        if let family = explicit[id], family != .other { return family }
        let isTopLevel = rootIsVolumeRoot && tree.parent(id) == tree.root
        return Self.heuristic(name: tree.name(id), isTopLevel: isTopLevel)
    }

    /// Name rules for nodes no knowledge-base category covers.
    public static func heuristic(name: String, isTopLevel: Bool) -> SpaceFamily? {
        let lower = name.lowercased()
        if lower.hasSuffix(".app") { return .apps }
        if lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".mov") || lower.hasSuffix(".mp4") { return .media }
        if lower.hasSuffix(".dmg") || lower.hasSuffix(".xip") || lower.hasSuffix(".pkg") { return .downloads }
        switch name {
        case "Applications": return .apps
        case "Caches", ".cache", ".npm": return .caches
        case "Developer", "DerivedData", "CoreSimulator", "node_modules", ".venv", ".gradle", ".cargo": return .developer
        case "Movies", "Pictures", "Music": return .media
        case "Downloads": return .downloads
        case "Documents", "Projects", "Developer Projects": return .projects
        case "Application Support", "Containers", "Group Containers", "Mail", "Messages": return .appData
        default: break
        }
        if isTopLevel, ["System", "private", "Library", "usr", "opt"].contains(name) { return .system }
        return nil
    }
}
