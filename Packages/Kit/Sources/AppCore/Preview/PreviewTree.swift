import Foundation
import ScanKit

/// Immutable in-memory tree for previews and the placeholder app. Not a test fake:
/// tests use `TestSupport.InMemoryTree`, which also supports mutation and hard links.
public final class PreviewTree: TreeReading {
    /// Declarative description of a tree.
    public indirect enum Entry: Sendable {
        case folder(String, [Entry])
        case package(String, [Entry])
        case file(String, UInt64)
        case restricted(String)
    }

    private struct Node: Sendable {
        var name: String
        var size: UInt64
        var flags: NodeFlags
        var parent: NodeID?
        var children: [NodeID]
        var descendants: UInt32
    }

    private let nodes: [Node]
    private let rootPath: String
    public let generation: UInt64 = 1
    public var root: NodeID { 0 }

    /// - Parameters:
    ///   - rootPath: absolute path of the root.
    ///   - rootName: display name of the root (defaults to the last path component).
    public init(rootPath: String, rootName: String? = nil, entries: [Entry]) {
        var nodes: [Node] = []
        let name = rootName ?? ((rootPath as NSString).lastPathComponent)
        nodes.append(Node(name: name, size: 0, flags: .directory, parent: nil, children: [], descendants: 0))

        func add(_ entry: Entry, parent: NodeID) -> (size: UInt64, count: UInt32) {
            let id = NodeID(nodes.count)
            switch entry {
            case .file(let name, let size):
                nodes.append(Node(name: name, size: size, flags: [], parent: parent, children: [], descendants: 0))
                return (size, 1)
            case .restricted(let name):
                nodes.append(Node(name: name, size: 0, flags: [.directory, .restricted], parent: parent, children: [], descendants: 0))
                return (0, 1)
            case .folder(let name, let children), .package(let name, let children):
                var flags: NodeFlags = .directory
                if case .package = entry { flags.insert(.package) }
                nodes.append(Node(name: name, size: 0, flags: flags, parent: parent, children: [], descendants: 0))
                var total: UInt64 = 0
                var count: UInt32 = 0
                var ids: [NodeID] = []
                for child in children {
                    ids.append(NodeID(nodes.count))
                    let result = add(child, parent: id)
                    total += result.size
                    count += result.count
                }
                nodes[Int(id)].size = total
                nodes[Int(id)].descendants = count
                nodes[Int(id)].children = ids
                return (total, count + 1)
            }
        }

        var total: UInt64 = 0
        var count: UInt32 = 0
        var ids: [NodeID] = []
        for entry in entries {
            ids.append(NodeID(nodes.count))
            let result = add(entry, parent: 0)
            total += result.size
            count += result.count
        }
        nodes[0].size = total
        nodes[0].descendants = count
        nodes[0].children = ids
        // Children sorted by size, largest first (TreeReading convention).
        let sizes = nodes.map(\.size)
        let names = nodes.map(\.name)
        for index in nodes.indices where !nodes[index].children.isEmpty {
            nodes[index].children.sort {
                sizes[Int($0)] != sizes[Int($1)] ? sizes[Int($0)] > sizes[Int($1)] : names[Int($0)] < names[Int($1)]
            }
        }
        self.nodes = nodes
        self.rootPath = rootPath
    }

    public func name(_ id: NodeID) -> String { nodes[Int(id)].name }
    public func size(_ id: NodeID) -> UInt64 { nodes[Int(id)].size }
    public func flags(_ id: NodeID) -> NodeFlags { nodes[Int(id)].flags }
    public func parent(_ id: NodeID) -> NodeID? { nodes[Int(id)].parent }
    public func children(_ id: NodeID) -> [NodeID] { nodes[Int(id)].children }
    public func descendantCount(_ id: NodeID) -> UInt32 { nodes[Int(id)].descendants }
    public func identity(_ id: NodeID) -> FileIdentity? { nil }

    public func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 {
        size(id)
    }

    public func path(_ id: NodeID) -> String {
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

    public func node(atPath path: String) -> NodeID? {
        if path == rootPath { return root }
        // Prefix must end on a component boundary, so "/x" never matches "/xyz".
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = nodes[Int(current)].children.first(where: { nodes[Int($0)].name == component }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
