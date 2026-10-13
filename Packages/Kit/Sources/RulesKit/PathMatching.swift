import Darwin
import Foundation

/// Path canonicalization shared by `SafetyPolicy`, `RuleEngine` and CleanupKit (PLAN 2.5).
///
/// Steps: expand `~` against the injected home, normalize lexically (`//`, `.`, `..`), optionally
/// resolve symlinks in the parent directory only (never the item itself), then fold firmlink and
/// alias prefixes: `/System/Volumes/Data/x` becomes `/x`, and `/var`, `/tmp`, `/etc` become
/// `/private/...`.
public enum CanonicalPath {
    /// Expands a leading `~` or `~/` against `home`.
    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// Lexically normalized components of an absolute path, or nil when the path is relative.
    public static func lexicalComponents(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !out.isEmpty { out.removeLast() }
                continue
            }
            out.append(String(part))
        }
        return out
    }

    /// Canonical components of `path`. `resolveParent` resolves symlinks in the parent directory
    /// (deepest existing ancestor); the last component is never resolved.
    public static func components(_ path: String, home: String, resolveParent: Bool) -> [String]? {
        guard var comps = lexicalComponents(expandTilde(path, home: home)) else { return nil }
        if resolveParent { comps = resolvingParent(comps) }
        return fold(comps)
    }

    /// Canonical string form of `components(_:home:resolveParent:)`.
    public static func string(_ path: String, home: String, resolveParent: Bool) -> String? {
        components(path, home: home, resolveParent: resolveParent).map(join)
    }

    /// Canonical components of a directory that is resolved completely (used for home and roots).
    static func fullyResolved(_ path: String) -> [String]? {
        guard let lexical = lexicalComponents(path) else { return nil }
        if let real = realpathString(join(lexical)), let comps = lexicalComponents(real) {
            return fold(comps)
        }
        return fold(resolvingParent(lexical))
    }

    /// Canonical string of a directory resolved completely (symlinks included), folded.
    public static func fullyResolvedString(_ path: String) -> String? {
        fullyResolved(path).map(join)
    }

    public static func join(_ comps: [String]) -> String {
        comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
    }

    static func fold(_ comps: [String]) -> [String] {
        var c = comps
        if c.count >= 3,
           c[0].caseInsensitiveCompare("System") == .orderedSame,
           c[1].caseInsensitiveCompare("Volumes") == .orderedSame,
           c[2].caseInsensitiveCompare("Data") == .orderedSame {
            c.removeFirst(3)
        }
        if let first = c.first {
            let lower = first.lowercased()
            if lower == "var" || lower == "tmp" || lower == "etc" {
                c.insert("private", at: 0)
            }
        }
        return c
    }

    static func resolvingParent(_ comps: [String]) -> [String] {
        guard comps.count >= 2, let last = comps.last else { return comps }
        let parent = comps.dropLast()
        var k = parent.count
        while k > 0 {
            let prefix = parent.prefix(k)
            if let real = realpathString("/" + prefix.joined(separator: "/")),
               let resolved = lexicalComponents(real) {
                return resolved + parent.dropFirst(k) + [last]
            }
            k -= 1
        }
        return comps
    }

    /// `realpath(3)` of an existing path, nil when it cannot be resolved.
    public static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// `*` wildcard matching within one path component (case handled by the caller).
struct ComponentGlob: Sendable, Hashable {
    let pattern: String
    private let parts: [String]

    init(_ pattern: String) {
        self.pattern = pattern
        parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    }

    static func isGlob(_ component: String) -> Bool { component.contains("*") }

    func matches(_ s: String) -> Bool {
        guard parts.count > 1 else { return s == pattern }
        guard s.hasPrefix(parts[0]) else { return false }
        var rest = s.dropFirst(parts[0].count)
        for middle in parts[1..<(parts.count - 1)] where !middle.isEmpty {
            guard let range = rest.range(of: middle) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.hasSuffix(parts[parts.count - 1])
    }
}

/// Trie over lowercased path components with per-component globs. Walking a path yields the
/// payloads attached to every prefix, so matching costs one dictionary lookup per component.
struct PathTrie<Payload: Sendable>: Sendable {
    struct Node: Sendable {
        var literals: [String: Int32] = [:]
        var globs: [(glob: ComponentGlob, next: Int32)] = []
        var payloads: [Payload] = []
    }

    private(set) var nodes: [Node] = [Node()]

    static var rootState: Int32 { 0 }

    mutating func insert(_ components: [String], payload: Payload) {
        var cursor: Int32 = 0
        for raw in components {
            let comp = raw.lowercased()
            if ComponentGlob.isGlob(comp) {
                if let existing = nodes[Int(cursor)].globs.first(where: { $0.glob.pattern == comp }) {
                    cursor = existing.next
                } else {
                    let next = Int32(nodes.count)
                    nodes.append(Node())
                    nodes[Int(cursor)].globs.append((ComponentGlob(comp), next))
                    cursor = next
                }
            } else if let next = nodes[Int(cursor)].literals[comp] {
                cursor = next
            } else {
                let next = Int32(nodes.count)
                nodes.append(Node())
                nodes[Int(cursor)].literals[comp] = next
                cursor = next
            }
        }
        nodes[Int(cursor)].payloads.append(payload)
    }

    /// Index of the node reached by literal (lowercased) components, created if needed.
    mutating func literalNode(_ components: [String]) -> Int32 {
        var cursor: Int32 = 0
        for comp in components {
            if let next = nodes[Int(cursor)].literals[comp] {
                cursor = next
            } else {
                let next = Int32(nodes.count)
                nodes.append(Node())
                nodes[Int(cursor)].literals[comp] = next
                cursor = next
            }
        }
        return cursor
    }

    /// Advances every state by one lowercased component.
    func step(_ states: [Int32], _ lowered: String) -> [Int32] {
        var next: [Int32] = []
        for state in states {
            let node = nodes[Int(state)]
            if let literal = node.literals[lowered] { next.append(literal) }
            for entry in node.globs where entry.glob.matches(lowered) {
                next.append(entry.next)
            }
        }
        return next
    }

    func payloads(_ state: Int32) -> [Payload] { nodes[Int(state)].payloads }
}
