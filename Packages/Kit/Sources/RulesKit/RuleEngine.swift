import Foundation
import ScanKit

/// Path classifier and category aggregation. Frozen contract (PLAN 4.3) plus additive overloads.
///
/// Matching semantics (shared by `classify` and `categories`):
/// - The SafetyPolicy is evaluated first; a block always wins (the matching rule, if any, still
///   provides the explanation, so blocked items can show guidance).
/// - Among rules, the deepest anchor wins (the matched item closest to the path); at the same
///   anchor a code detector beats a path rule, then the more literal pattern wins
///   (`~/Library/Caches/com.apple.dt.Xcode` beats `~/Library/Caches/com.apple.*` beats `~/Library/Caches/*`).
public final class RuleEngine: Sendable {
    public let home: String
    public let rules: [Rule]
    public let policy: SafetyPolicy
    let metadata: any FileMetadataProviding
    let now: @Sendable () -> Date
    let compiled: CompiledRules

    public convenience init(home: String, rules: [Rule] = .bundled) {
        self.init(home: home, rules: rules, policy: nil, metadata: LiveFileMetadata())
    }

    /// Additive: inject the policy (for example with scan roots), file metadata and the clock.
    public init(
        home: String,
        rules: [Rule] = .bundled,
        policy: SafetyPolicy? = nil,
        metadata: any FileMetadataProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.rules = rules
        self.policy = policy ?? SafetyPolicy(home: home)
        self.metadata = metadata
        self.now = now
        self.compiled = CompiledRules(rules: rules, home: home)
    }

    /// The rule with this id, if bundled.
    public func rule(withID id: String) -> Rule? {
        compiled.indexByID[id].map { rules[$0] }
    }

    // MARK: Classify

    /// Classifies one path. Symlinks in the parent directory are resolved first.
    public func classify(path: String) -> Classification {
        classify(path: path, resolveSymlinks: true)
    }

    /// Additive: `resolveSymlinks == false` skips the parent `realpath` (for paths that come from a
    /// scanned tree, which never contains followed symlinks).
    public func classify(path: String, resolveSymlinks: Bool) -> Classification {
        guard let comps = CanonicalPath.components(path, home: home, resolveParent: resolveSymlinks) else {
            return Classification(risk: .never, block: .notInScan)
        }
        let lower = comps.map { $0.lowercased() }
        let protection = policy.evaluate(loweredCanonical: lower)
        let winner = bestMatch(comps: comps, lower: lower)
        return combine(protection, winner.map { rules[$0.rule] })
    }

    func combine(_ protection: Classification, _ rule: Rule?) -> Classification {
        if let block = protection.block {
            return Classification(ruleID: rule?.id, risk: .never, categoryID: rule?.categoryID, explanation: rule?.explanation, block: block)
        }
        guard let rule else { return protection }
        var risk = rule.risk
        if protection.risk == .dangerous { risk = max(risk, .dangerous) }
        // Defensive: a never rule always carries a block, even if the table missed it.
        let block: BlockReason? = risk == .never ? .systemPath : nil
        return Classification(ruleID: rule.id, risk: risk, categoryID: rule.categoryID, explanation: rule.explanation, block: block)
    }

    struct Candidate {
        var depth: Int
        var priority: Int
        var specificity: Int32
        var rule: Int

        func beats(_ other: Candidate) -> Bool {
            if depth != other.depth { return depth > other.depth }
            if priority != other.priority { return priority > other.priority }
            if specificity != other.specificity { return specificity > other.specificity }
            return rule < other.rule
        }
    }

    /// Best rule for a canonical path (`comps` original case, `lower` lowercased).
    func bestMatch(comps: [String], lower: [String]) -> Candidate? {
        let n = lower.count
        var best: Candidate?
        func consider(_ c: Candidate) {
            if best.map({ c.beats($0) }) ?? true { best = c }
        }
        let trie = compiled.trie
        var states: [Int32] = [PathTrie<RulePayload>.rootState]
        for (index, comp) in lower.enumerated() {
            states = trie.step(states, comp)
            if states.isEmpty { break }
            let depth = index + 1
            for state in states {
                for payload in trie.payloads(state) where payload.covers || depth == n {
                    consider(Candidate(depth: depth, priority: 0, specificity: payload.specificity, rule: Int(payload.rule)))
                }
            }
        }
        if let devRule = compiled.devArtifactsRule, n >= 2 {
            for index in 1..<n {
                guard let spec = DevArtifacts.specs[comps[index]] else { continue }
                let parent = CanonicalPath.join(Array(comps[0..<index]))
                let folder = CanonicalPath.join(Array(comps[0...index]))
                let found = spec.siblingMarkers.contains { metadata.itemExists(atPath: parent + "/" + $0) }
                    || spec.childMarkers.contains { metadata.itemExists(atPath: folder + "/" + $0) }
                if found {
                    consider(Candidate(depth: index + 1, priority: 1, specificity: 0, rule: devRule))
                }
            }
        }
        if let installerRule = compiled.oldInstallersRule,
           n == compiled.downloads.count + 1, lower.starts(with: compiled.downloads),
           OldInstallers.isInstallerName(comps[n - 1]),
           let age = ageDays(of: CanonicalPath.join(comps), preferAdded: true),
           age >= rules[installerRule].minAgeDays ?? OldInstallers.defaultMinAgeDays {
            consider(Candidate(depth: n, priority: 1, specificity: 0, rule: installerRule))
        }
        return best
    }

    func ageDays(of path: String, preferAdded: Bool) -> Int? {
        let date = (preferAdded ? metadata.addedDate(atPath: path) : nil) ?? metadata.modificationDate(atPath: path)
        return date.map { Self.days(from: $0, to: now()) }
    }

    static func days(from date: Date, to now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(date) / 86_400).rounded(.down)))
    }

    // MARK: Categories

    private struct Region {
        var rule: Int
        var node: NodeID
        var bytes: UInt64
        /// The region this one was carved out of, if any.
        var enclosing: Int?
    }

    private struct Frame {
        var node: NodeID
        var states: [Int32]
        var region: Int?
        var inArtifact: Bool
        /// Progress through `System/Volumes/Data` when the canonical root is `/`; -1 when not tracking.
        var alias: Int8
    }

    private static let dataAlias = ["system", "volumes", "data"]

    /// Reclaimable categories in `tree`. Each node belongs to at most one rule: a nested match of a
    /// different rule is carved out of the enclosing match's bytes, and a nested match of the same
    /// rule is ignored (topmost node only), so the category totals never double count.
    /// The scan root itself is never offered; if the root sits inside a rule's area, its children
    /// are offered instead. For trash rules, items that are blocked, dangerous, contain a protected
    /// item (`protectedDescendant(of:in:)`) or sit inside an item already in the Trash are never
    /// offered; guide rules still report them.
    public func categories(in tree: any TreeReading) -> [CategoryResult] {
        categories(in: tree, isCancelled: { false }) ?? []
    }

    /// Additive: `categories(in:)` that stops early. `isCancelled` is polled every
    /// `cancellationCheckInterval` folders and once before the final pass; when it returns true the
    /// walk ends and the result is nil (a superseded live-refresh walk must not run to the end).
    public func categories(in tree: any TreeReading, isCancelled: () -> Bool) -> [CategoryResult]? {
        let rootID = tree.root
        let rootPath = tree.path(rootID)
        guard let rootCanon = CanonicalPath.fullyResolved(rootPath) else { return [] }
        let rootLower = rootCanon.map { $0.lowercased() }
        let trie = compiled.trie

        var rootStates: [Int32] = [PathTrie<RulePayload>.rootState]
        for comp in rootLower {
            rootStates = trie.step(rootStates, comp)
            if rootStates.isEmpty { break }
        }
        let rootOwner = rootLower.isEmpty ? nil : bestMatch(comps: rootCanon, lower: rootLower)

        var regions: [Region] = []
        var stack = [Frame(
            node: rootID,
            states: rootStates,
            region: nil,
            inArtifact: rootOwner.map { $0.rule == compiled.devArtifactsRule } ?? false,
            alias: rootLower.isEmpty ? 0 : -1
        )]

        var visited = 0
        while let frame = stack.popLast() {
            visited &+= 1
            if visited % Self.cancellationCheckInterval == 0, isCancelled() { return nil }
            let children = tree.children(frame.node)
            if children.isEmpty { continue }
            let isRoot = frame.node == rootID
            let atDownloads = compiled.oldInstallersRule != nil && compiled.downloadsState.map(frame.states.contains) == true
            var siblingNames: Set<String>?

            for child in children {
                let name = tree.name(child)
                let isDirectory = tree.flags(child).contains(.directory)
                var alias: Int8 = -1
                var childStates: [Int32] = []
                if frame.alias >= 0, frame.alias < 3, name.lowercased() == Self.dataAlias[Int(frame.alias)] {
                    alias = frame.alias + 1
                }
                if alias == 3 {
                    childStates = [PathTrie<RulePayload>.rootState]
                } else if !frame.states.isEmpty {
                    childStates = trie.step(frame.states, name.lowercased())
                }

                var best: Candidate?
                func consider(_ c: Candidate) {
                    if best.map({ c.beats($0) }) ?? true { best = c }
                }
                if alias != 3 {
                    for state in childStates {
                        for payload in trie.payloads(state) {
                            consider(Candidate(depth: 0, priority: 0, specificity: payload.specificity, rule: Int(payload.rule)))
                        }
                    }
                }
                if !frame.inArtifact, isDirectory, let devRule = compiled.devArtifactsRule, let spec = DevArtifacts.specs[name] {
                    if siblingNames == nil { siblingNames = Set(children.map { tree.name($0) }) }
                    let found = spec.siblingMarkers.contains { siblingNames?.contains($0) == true }
                        || (!spec.childMarkers.isEmpty && tree.children(child).contains { spec.childMarkers.contains(tree.name($0)) })
                    if found { consider(Candidate(depth: 0, priority: 1, specificity: 0, rule: devRule)) }
                }
                if atDownloads, !isDirectory, let installerRule = compiled.oldInstallersRule, OldInstallers.isInstallerName(name),
                   let age = ageDays(of: tree.path(child), preferAdded: true),
                   age >= rules[installerRule].minAgeDays ?? OldInstallers.defaultMinAgeDays {
                    consider(Candidate(depth: 0, priority: 1, specificity: 0, rule: installerRule))
                }
                if best == nil, isRoot, let rootOwner {
                    best = rootOwner
                }

                var region = frame.region
                var inArtifact = frame.inArtifact
                if let winner = best, region.map({ regions[$0].rule != winner.rule }) ?? true,
                   anchorAllowed(rules[winner.rule], node: child, tree: tree, rootID: rootID, rootCanon: rootCanon) {
                    let size = tree.size(child)
                    if let enclosing = region {
                        regions[enclosing].bytes -= min(regions[enclosing].bytes, size)
                    }
                    regions.append(Region(rule: winner.rule, node: child, bytes: size, enclosing: region))
                    region = regions.count - 1
                    if winner.rule == compiled.devArtifactsRule { inArtifact = true }
                }

                if isDirectory && (!childStates.isEmpty || !inArtifact || alias >= 0) {
                    stack.append(Frame(node: child, states: childStates, region: region, inArtifact: inArtifact, alias: alias))
                }
            }
        }

        if isCancelled() { return nil }
        return finish(regions, tree: tree)
    }

    /// Folders visited between two polls of the cancellation check in `categories(in:isCancelled:)`.
    public static let cancellationCheckInterval = 512

    private func canonicalComponents(of node: NodeID, tree: any TreeReading, rootID: NodeID, rootCanon: [String]) -> [String] {
        var relative: [String] = []
        var cursor: NodeID? = node
        while let current = cursor, current != rootID {
            relative.append(tree.name(current))
            cursor = tree.parent(current)
        }
        return CanonicalPath.fold(rootCanon + relative.reversed())
    }

    private func anchorAllowed(_ rule: Rule, node: NodeID, tree: any TreeReading, rootID: NodeID, rootCanon: [String]) -> Bool {
        if rule.action == .guide { return true }
        let comps = canonicalComponents(of: node, tree: tree, rootID: rootID, rootCanon: rootCanon)
        let lower = comps.map { $0.lowercased() }
        let protection = policy.evaluate(loweredCanonical: lower)
        if protection.block != nil { return false }
        if protection.risk == .dangerous && rule.risk < .dangerous { return false }
        if isInsideTrashedItem(lower) { return false }
        if let nested = protectedDescendant(of: node, in: tree, canonical: comps) {
            if nested.isBlocked || rule.risk < .dangerous { return false }
        }
        return true
    }

    /// True for paths below an item in the Trash (moving those to the Trash frees nothing).
    private func isInsideTrashedItem(_ lower: [String]) -> Bool {
        let homeLower = policy.table.homeLower
        let homeTrash = homeLower + [".trash"]
        if !homeLower.isEmpty, lower.count > homeTrash.count + 1, lower.starts(with: homeTrash) { return true }
        if let index = lower.firstIndex(of: ".trashes"), lower.count > index + 3 { return true }
        return false
    }

    // MARK: Protected descendants

    /// Additive: the first protected item inside `node` (never class first, then dangerous), from
    /// scan data only. Checks the absolute protected paths of the SafetyPolicy table by prefix and
    /// walks the node's directories for patterns that can sit anywhere (`*.photoslibrary`,
    /// `*.backupdb`, device backups, browser profiles). Use it to refuse a queued folder at add time.
    public func protectedDescendant(of node: NodeID, in tree: any TreeReading) -> ProtectedDescendant? {
        guard let comps = CanonicalPath.components(tree.path(node), home: home, resolveParent: false) else { return nil }
        return protectedDescendant(of: node, in: tree, canonical: comps)
    }

    func protectedDescendant(of node: NodeID, in tree: any TreeReading, canonical comps: [String]) -> ProtectedDescendant? {
        var dangerous: ProtectedDescendant?
        if let entry = policy.table.protectedDescendant(comps) {
            if entry.isBlocked { return entry }
            dangerous = entry
        }
        var stack: [(node: NodeID, parentName: String)] = []
        let rootName = tree.name(node)
        for child in tree.children(node) where tree.flags(child).contains(.directory) {
            stack.append((child, rootName))
        }
        while let (current, parentName) = stack.popLast() {
            let name = tree.name(current)
            if let found = SafetyPolicy.nestedDirectoryClass(name: name, parentName: parentName) {
                let hit = ProtectedDescendant(path: tree.path(current), classification: found)
                if hit.isBlocked { return hit }
                if dangerous == nil { dangerous = hit }
                continue
            }
            for child in tree.children(current) where tree.flags(child).contains(.directory) {
                stack.append((child, name))
            }
        }
        return dangerous
    }

    private func finish(_ regions: [Region], tree: any TreeReading) -> [CategoryResult] {
        var byRule: [Int: [Int]] = [:]
        for (index, region) in regions.enumerated() { byRule[region.rule, default: []].append(index) }

        var kept = [Bool](repeating: true, count: regions.count)
        var ages: [NodeID: Int] = [:]
        for (ruleIndex, indices) in byRule {
            let rule = rules[ruleIndex]
            if rule.detector == .devArtifacts {
                for index in indices {
                    let node = regions[index].node
                    let project = (tree.path(node) as NSString).deletingLastPathComponent
                    let spec = DevArtifacts.specs[tree.name(node)]
                    let dates = ([project] + (spec?.siblingMarkers ?? []).map { project + "/" + $0 })
                        .compactMap { metadata.modificationDate(atPath: $0) }
                    if let newest = dates.max() { ages[node] = Self.days(from: newest, to: now()) }
                }
            }
            if let minAge = rule.minAgeDays ?? (rule.detector == .oldInstallers ? OldInstallers.defaultMinAgeDays : nil) {
                for index in indices {
                    let node = regions[index].node
                    if let age = ageDays(of: tree.path(node), preferAdded: rule.detector == .oldInstallers) {
                        ages[node] = age
                        if age < minAge { kept[index] = false }
                    } else {
                        kept[index] = false
                    }
                }
            }
            if let keep = rule.keepNewest {
                var groups: [NodeID: [Int]] = [:]
                for index in indices where kept[index] {
                    groups[tree.parent(regions[index].node) ?? tree.root, default: []].append(index)
                }
                for members in groups.values {
                    let newestFirst = members.sorted { a, b in
                        let da = metadata.modificationDate(atPath: tree.path(regions[a].node))
                        let db = metadata.modificationDate(atPath: tree.path(regions[b].node))
                        if da != db {
                            switch (da, db) {
                            case let (x?, y?): return x > y
                            case (.some, nil): return true
                            default: return false
                            }
                        }
                        return tree.name(regions[a].node).localizedStandardCompare(tree.name(regions[b].node)) == .orderedDescending
                    }
                    for index in newestFirst.prefix(keep) { kept[index] = false }
                }
            }
        }

        // Bytes of a dropped region go back to the nearest kept region it was carved out of.
        var bytes = regions.map(\.bytes)
        for index in regions.indices where !kept[index] {
            var cursor = regions[index].enclosing
            while let enclosing = cursor, !kept[enclosing] { cursor = regions[enclosing].enclosing }
            if let target = cursor { bytes[target] += bytes[index] }
        }

        var results: [CategoryResult] = []
        for (ruleIndex, indices) in byRule {
            let rule = rules[ruleIndex]
            var members = indices.filter { kept[$0] }
            guard !members.isEmpty else { continue }
            members.sort { bytes[$0] != bytes[$1] ? bytes[$0] > bytes[$1] : tree.name(regions[$0].node) < tree.name(regions[$1].node) }
            let nodes = members.map { regions[$0].node }
            results.append(CategoryResult(
                ruleID: rule.id,
                title: rule.title,
                categoryID: rule.categoryID,
                risk: rule.risk,
                bytes: members.reduce(0) { $0 + bytes[$1] },
                count: members.count,
                nodes: nodes,
                action: rule.action,
                explanation: rule.explanation,
                commandHint: rule.commandHint,
                ageDaysByNode: ages.filter { nodes.contains($0.key) }
            ))
        }
        return results.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.ruleID < $1.ruleID }
    }
}

struct RulePayload: Sendable {
    var rule: Int32
    var covers: Bool
    var specificity: Int32
}

/// Rules compiled into a trie against the canonical home.
final class CompiledRules: Sendable {
    let trie: PathTrie<RulePayload>
    let indexByID: [String: Int]
    let downloads: [String]
    let downloadsState: Int32?
    let devArtifactsRule: Int?
    let oldInstallersRule: Int?

    init(rules: [Rule], home: String) {
        let homeComps = CanonicalPath.fullyResolved(home) ?? CanonicalPath.lexicalComponents(home) ?? []
        func expand(_ pattern: String) -> [String] {
            if pattern == "~" { return homeComps }
            if pattern.hasPrefix("~/") {
                return homeComps + pattern.dropFirst(2).split(separator: "/").map(String.init)
            }
            return CanonicalPath.fold(CanonicalPath.lexicalComponents(pattern) ?? [])
        }
        var trie = PathTrie<RulePayload>()
        var index: [String: Int] = [:]
        var dev: Int?
        var installers: Int?
        for (i, rule) in rules.enumerated() {
            index[rule.id] = index[rule.id] ?? i
            if rule.detector == .devArtifacts, dev == nil { dev = i }
            if rule.detector == .oldInstallers, installers == nil { installers = i }
            for m in rule.match {
                var comps = expand(m.path)
                if m.kind == .childrenOf { comps.append("*") }
                let specificity = Int32(comps.reduce(0) { $0 + $1.filter { $0 != "*" }.count })
                trie.insert(comps, payload: RulePayload(rule: Int32(i), covers: m.kind != .exact, specificity: specificity))
            }
        }
        let downloads = (homeComps + ["Downloads"]).map { $0.lowercased() }
        self.downloadsState = installers == nil ? nil : trie.literalNode(downloads)
        self.downloads = downloads
        self.trie = trie
        self.indexByID = index
        self.devArtifactsRule = dev
        self.oldInstallersRule = installers
    }
}

/// Regenerable build folders and the project markers that must sit next to them.
enum DevArtifacts {
    struct Spec {
        var siblingMarkers: [String]
        var childMarkers: [String] = []
    }

    static let buildMarkers = ["package.json", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "pyproject.toml", "setup.py"]

    /// Keyed by exact folder name (case-sensitive, as the tools create them).
    static let specs: [String: Spec] = [
        "node_modules": Spec(siblingMarkers: ["package.json"]),
        ".next": Spec(siblingMarkers: ["package.json"]),
        ".expo": Spec(siblingMarkers: ["package.json", "app.json"]),
        "dist": Spec(siblingMarkers: buildMarkers),
        "build": Spec(siblingMarkers: buildMarkers),
        "target": Spec(siblingMarkers: ["Cargo.toml", "pom.xml"]),
        "Pods": Spec(siblingMarkers: ["Podfile"]),
        ".venv": Spec(siblingMarkers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"], childMarkers: ["pyvenv.cfg"]),
    ]
}

/// Installer files left in Downloads.
enum OldInstallers {
    static let extensions: Set<String> = ["dmg", "pkg", "zip"]
    static let defaultMinAgeDays = 30

    static func isInstallerName(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }
}
