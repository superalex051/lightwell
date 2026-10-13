import Foundation
import ScanKit

/// Protected paths (PLAN 2.5). Frozen contract (PLAN 4.3) plus the additive `scanRoot`.
///
/// Evaluated when an item is added to the queue, when the assistant proposes a deletion, and again
/// by the deletion executor right before each move or delete.
///
/// Matching works on canonical paths (see `CanonicalPath`), case-insensitively on every volume
/// (strictly safer: a case-sensitive volume can only see more blocks, never fewer).
///
/// Resolution walks the matching entries from the shallowest to the deepest:
/// - a block applies to the path and (for subtree entries) everything below it;
/// - only an explicit allowed exception (PLAN 2.5) at a deeper level lifts a block;
/// - "dangerous" never lifts a block from an ancestor, it only marks otherwise allowed paths;
/// - at equal depth a block beats dangerous, which beats an allowed exception.
/// Exact entries (protected roots) only match the path itself, so their contents stay available.
public struct SafetyPolicy: Sendable {
    public let home: String
    /// Folders being scanned. Each one is protected itself (`BlockReason.scanRoot`), its contents are not.
    public let scanRoots: [String]

    let table: ProtectionTable

    public init(home: String) {
        self.init(home: home, scanRoot: nil)
    }

    /// Additive: pass the scan root so the policy can protect it.
    public init(home: String, scanRoot: String?) {
        self.init(home: home, scanRoots: scanRoot.map { [$0] } ?? [])
    }

    /// Additive: several scan roots (one per open scan session).
    public init(home: String, scanRoots: [String]) {
        self.home = home
        self.scanRoots = scanRoots
        self.table = ProtectionTable(home: home, scanRoots: scanRoots)
    }

    /// Returns a copy that also protects `scanRoot`.
    public func addingScanRoot(_ scanRoot: String) -> SafetyPolicy {
        SafetyPolicy(home: home, scanRoots: scanRoots + [scanRoot])
    }

    /// Classifies `path` against the protected-path table. Symlinks in the parent directory are
    /// resolved first; the item itself is never resolved (a symlink is judged as the link).
    ///
    /// - Returns: `risk == .never` with a `block` reason when the item must not be removed,
    ///   `risk == .dangerous` when it needs a per-item acknowledgement, otherwise `.unclassified`.
    ///   `isDirectory` is accepted for API stability; the table does not depend on it.
    public func check(path: String, isDirectory: Bool, volume: VolumeInfo?) -> Classification {
        if volume?.isReadOnly == true {
            return Classification(risk: .never, block: .readOnlyVolume)
        }
        guard let comps = CanonicalPath.components(path, home: home, resolveParent: true) else {
            return Classification(risk: .never, block: .notInScan)
        }
        if let volume, let volumeComps = CanonicalPath.fullyResolved(volume.url.path),
           Self.lowered(volumeComps) == Self.lowered(comps) {
            return Classification(risk: .never, block: .protectedRoot)
        }
        return table.evaluate(Self.lowered(comps))
    }

    /// Additive, pure (only the parent `realpath` touches the file system): the first absolute
    /// protected path of the table (never or dangerous class) that lies strictly inside `path`, by
    /// prefix comparison. Blocks are reported before dangerous entries. Pattern classes that can
    /// appear anywhere (`*.photoslibrary`, `*.backupdb`, browser profiles, device backups) need a
    /// walk of the item: see `nestedDirectoryClass(name:parentName:)`.
    public func protectedDescendant(of path: String) -> ProtectedDescendant? {
        guard let comps = CanonicalPath.components(path, home: home, resolveParent: true) else { return nil }
        return table.protectedDescendant(comps)
    }

    /// Additive: class of a directory found inside a queued item, judged by its own name and its
    /// parent's name only (patterns that can sit anywhere). nil when the name matches no pattern.
    public static func nestedDirectoryClass(name: String, parentName: String?) -> Classification? {
        let lower = name.lowercased()
        if lower.hasSuffix(".backupdb") || lower.hasSuffix(".backupbundle") {
            return Classification(risk: .never, block: .backup)
        }
        if lower.hasSuffix(".photoslibrary") {
            return Classification(risk: .dangerous)
        }
        if let parent = parentName?.lowercased(), nestedDangerousPairs.contains(NamePair(parent: parent, name: lower)) {
            return Classification(risk: .dangerous)
        }
        return nil
    }

    struct NamePair: Hashable { var parent: String; var name: String }

    /// Device backups and browser profiles, wherever they appear (for example a copied old home).
    static let nestedDangerousPairs: Set<NamePair> = [
        NamePair(parent: "mobilesync", name: "backup"),
        NamePair(parent: "google", name: "chrome"),
        NamePair(parent: "firefox", name: "profiles"),
        NamePair(parent: "bravesoftware", name: "brave-browser"),
    ]

    /// Evaluates already canonical, lowercased components (no file system access).
    func evaluate(loweredCanonical comps: [String]) -> Classification {
        table.evaluate(comps)
    }

    static func lowered(_ comps: [String]) -> [String] { comps.map { $0.lowercased() } }
}

/// A protected item found inside another item.
public struct ProtectedDescendant: Sendable, Hashable {
    /// Absolute path of the protected item (canonical form for table entries).
    public var path: String
    /// `risk == .never` with a block, or `risk == .dangerous`.
    public var classification: Classification

    public init(path: String, classification: Classification) {
        self.path = path
        self.classification = classification
    }

    public var isBlocked: Bool { classification.block != nil }
}

enum ProtectionEffect: Sendable, Hashable {
    case block(BlockReason)
    case dangerous
    case allow

    var priority: Int {
        switch self {
        case .block: 2
        case .dangerous: 1
        case .allow: 0
        }
    }
}

struct Protection: Sendable {
    var effect: ProtectionEffect
    /// false: matches only the path itself (protected roots). true: the path and everything below.
    var coversDescendants: Bool
}

/// Compiled protection table. Built once per `SafetyPolicy`.
final class ProtectionTable: Sendable {
    let trie: PathTrie<Protection>
    let scanRoots: [[String]]
    let homeLower: [String]
    /// Lowercased canonical components of every never or dangerous entry (globs kept as `*`).
    let protectedEntries: [(comps: [String], display: [String], effect: ProtectionEffect)]

    /// Top-level dot folders in home that hold only re-downloadable data (R3 B1): not blocked at all.
    static let homeDotExceptions: Set<String> = [".pnpm-store"]

    private enum Kind { case exact, subtree, childrenOf }

    init(home: String, scanRoots: [String]) {
        var trie = PathTrie<Protection>()
        var entries: [(comps: [String], display: [String], effect: ProtectionEffect)] = []
        let homeComps = CanonicalPath.fullyResolved(home) ?? CanonicalPath.lexicalComponents(home) ?? []

        func add(_ pattern: String, _ kind: Kind, _ effect: ProtectionEffect) {
            let expanded: [String]
            if pattern == "~" {
                expanded = homeComps
            } else if pattern.hasPrefix("~/") {
                expanded = homeComps + pattern.dropFirst(2).split(separator: "/").map(String.init)
            } else {
                expanded = CanonicalPath.fold(CanonicalPath.lexicalComponents(pattern) ?? [])
            }
            switch kind {
            case .exact: trie.insert(expanded, payload: Protection(effect: effect, coversDescendants: false))
            case .subtree: trie.insert(expanded, payload: Protection(effect: effect, coversDescendants: true))
            case .childrenOf: trie.insert(expanded + ["*"], payload: Protection(effect: effect, coversDescendants: true))
            }
            if effect != .allow {
                let full = expanded + (kind == .childrenOf ? ["*"] : [])
                entries.append((full.map { $0.lowercased() }, full, effect))
            }
        }

        let system = ProtectionEffect.block(.systemPath)
        let root = ProtectionEffect.block(.protectedRoot)
        let user = ProtectionEffect.block(.userData)
        let cloud = ProtectionEffect.block(.cloudSynced)
        let backup = ProtectionEffect.block(.backup)

        // Never: system (subtree).
        for path in [
            "/System", "/usr", "/bin", "/sbin", "/private/var/db", "/private/var/vm", "/private/etc",
            "/private/var/folders", "/Library/Apple", "/Library/Extensions", "/Library/Keychains",
            "/Library/Preferences/SystemConfiguration", "/dev", "/.Spotlight-V100", "/.fseventsd",
            "/.DocumentRevisions-V100", "/.vol",
            "/Volumes/*/.Spotlight-V100", "/Volumes/*/.fseventsd", "/Volumes/*/.DocumentRevisions-V100",
        ] { add(path, .subtree, system) }
        // `/cores` itself is protected; core dumps inside are review items.
        add("/cores", .exact, system)

        // Never: roots (exact, contents allowed). The last group goes beyond PLAN 2.5: folders that
        // only hold other folders, so removing them whole is never what the user means.
        for path in [
            "/", "/Applications", "/Library", "/Users", "/Volumes", "/Volumes/*",
            "~", "~/Library", "~/Documents", "~/Desktop", "~/Downloads", "~/Pictures", "~/Movies", "~/Music",
            "/private", "/private/var", "/opt", "/Users/*", "/Library/Application Support",
            "~/Applications", "~/Public", "~/Library/Application Support", "~/Library/Caches",
            "~/Library/Containers", "~/Library/Group Containers", "~/Library/Developer", "~/Library/Logs",
        ] { add(path, .exact, root) }

        // Never: user data (subtree; "bulk" entries too, their exceptions follow). Top-level dot
        // folders and dotfiles in home are added in code (see `evaluate`).
        for path in [
            "~/Library/Keychains", "~/Library/Mail", "~/Library/Messages", "~/Library/Photos",
            "~/Library/Application Support/AddressBook", "~/Library/Calendars", "~/Library/Safari",
            "~/Library/Accounts", "~/Library/Cookies", "~/Library/IdentityServices", "~/Library/Sharing",
            "~/Library/Biome", "~/Library/Daemon Containers", "~/Library/Autosave Information",
            "~/Library/Containers/com.apple.*", "~/Library/Group Containers/group.com.apple.*",
            "~/Library/Preferences", "~/.ssh", "~/.gnupg", "~/.config", "~/.claude", "~/.local/bin",
            "~/.local/share/claude",
        ] { add(path, .subtree, user) }
        add("~/Library/Mobile Documents", .subtree, cloud)
        add("~/Library/CloudStorage", .subtree, cloud)

        // Never: backups.
        for path in [
            "/Volumes/.timemachine", "/Volumes/com.apple.TimeMachine.localsnapshots",
            "/Volumes/*/*.sparsebundle", "/Volumes/*/*.backupbundle",
        ] { add(path, .subtree, backup) }

        // Dangerous: whole item only after an explicit per-item acknowledgement.
        for path in [
            "~/Library/Application Support/MobileSync/Backup",
            "~/Library/Application Support/Google/Chrome",
            "~/Library/Application Support/Firefox",
            "~/Library/Application Support/BraveSoftware",
            "~/Library/Application Support/Microsoft Edge",
            "~/Library/Application Support/Arc",
        ] { add(path, .subtree, .dangerous) }

        // Allowed exceptions (beat a shorter never-prefix).
        for path in ["/usr/local", "/private/var/log", "/private/var/tmp", "/private/tmp"] {
            add(path, .subtree, .allow)
        }
        add("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .childrenOf, .allow)
        // Re-downloadable caches that live inside protected top-level dot folders (R3 B1).
        for path in [
            "~/.npm/_cacache", "~/.yarn/berry/cache", "~/.bun/install/cache", "~/.cache/uv",
            "~/.cache/huggingface", "~/.gradle/caches", "~/.m2/repository", "~/.cargo/registry",
            "~/.ollama/models", "~/.lmstudio/models",
        ] { add(path, .subtree, .allow) }
        add("~/.Trash", .childrenOf, .allow)

        // Home itself is an exception so a home that lives under a protected temporary area (test
        // fixtures in $TMPDIR) still gets home rules. Never applied to a home inside system folders.
        if Self.homeMayBeException(homeComps) {
            trie.insert(homeComps, payload: Protection(effect: .allow, coversDescendants: true))
        }

        self.trie = trie
        self.protectedEntries = entries
        self.homeLower = homeComps.map { $0.lowercased() }
        self.scanRoots = scanRoots.compactMap { CanonicalPath.fullyResolved($0) }.map(SafetyPolicy.lowered)
    }

    private static func homeMayBeException(_ comps: [String]) -> Bool {
        guard comps.count >= 2 else { return false }
        let lower = comps.map { $0.lowercased() }
        let forbiddenFirst: Set<String> = ["system", "usr", "bin", "sbin", "dev", "library", "applications", "volumes"]
        if forbiddenFirst.contains(lower[0]) { return false }
        if lower.starts(with: ["private", "etc"]) || lower.starts(with: ["private", "var", "db"])
            || lower.starts(with: ["private", "var", "vm"]) { return false }
        return true
    }

    /// Classifies lowercased canonical components. A candidate applies when the path has at least
    /// `depth` components and either covers descendants or ends exactly at `depth`.
    func evaluate(_ comps: [String]) -> Classification {
        let n = comps.count
        var candidates: [(depth: Int, effect: ProtectionEffect)] = []

        func consider(_ depth: Int, _ effect: ProtectionEffect, covers: Bool) {
            guard depth <= n, covers || depth == n else { return }
            candidates.append((depth, effect))
        }

        var states: [Int32] = [PathTrie<Protection>.rootState]
        for payload in trie.payloads(PathTrie<Protection>.rootState) {
            consider(0, payload.effect, covers: payload.coversDescendants)
        }
        for (index, comp) in comps.enumerated() {
            states = trie.step(states, comp)
            if states.isEmpty { break }
            for state in states {
                for payload in trie.payloads(state) {
                    consider(index + 1, payload.effect, covers: payload.coversDescendants)
                }
            }
        }

        // Top-level dotfiles and dot folders in home, with everything inside (user data). Cache
        // paths inside them are allowed exceptions in the table; `.pnpm-store` is not blocked.
        if !homeLower.isEmpty, n > homeLower.count, comps.starts(with: homeLower) {
            let top = comps[homeLower.count]
            if top.hasPrefix("."), !Self.homeDotExceptions.contains(top) {
                consider(homeLower.count + 1, .block(.userData), covers: true)
            }
        }

        // Unanchored patterns: Photos libraries, Time Machine backups, app bundle internals.
        for (index, comp) in comps.enumerated() {
            if comp.hasSuffix(".photoslibrary") {
                consider(index + 1, .dangerous, covers: false)
                consider(index + 2, .block(.userData), covers: true)
            } else if comp.hasSuffix(".backupdb") || comp.hasSuffix(".backupbundle") {
                consider(index + 1, .block(.backup), covers: true)
            } else if comp.hasSuffix(".app"), index + 1 < n, comps[index + 1] == "contents" {
                consider(index + 2, .block(.systemPath), covers: true)
            }
        }

        // Fold from the shallowest entry to the deepest; at equal depth the stronger effect last.
        candidates.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.effect.priority < $1.effect.priority }
        var blockReason: BlockReason?
        var dangerous = false
        var depthOfBlock = -1
        for candidate in candidates {
            switch candidate.effect {
            case .block(let reason):
                blockReason = reason
                depthOfBlock = candidate.depth
            case .allow:
                // An exception lifts only a shallower block, never one at its own depth.
                if blockReason != nil && candidate.depth > depthOfBlock { blockReason = nil }
            case .dangerous:
                // Dangerous never lifts a block from an ancestor.
                if blockReason == nil { dangerous = true }
            }
        }

        if let blockReason {
            return Classification(risk: .never, block: blockReason)
        }
        if scanRoots.contains(comps) {
            return Classification(risk: .never, block: .scanRoot)
        }
        return dangerous ? Classification(risk: .dangerous) : .unclassified
    }

    /// First never or dangerous table entry strictly inside `comps` (original case), blocks first.
    func protectedDescendant(_ comps: [String]) -> ProtectedDescendant? {
        let lower = comps.map { $0.lowercased() }
        var dangerous: ProtectedDescendant?
        for entry in protectedEntries where entry.comps.count > lower.count {
            var matches = true
            for (index, comp) in lower.enumerated() {
                let pattern = entry.comps[index]
                let ok = ComponentGlob.isGlob(pattern) ? ComponentGlob(pattern).matches(comp) : pattern == comp
                if !ok { matches = false; break }
            }
            guard matches else { continue }
            let path = CanonicalPath.join(comps + entry.display[lower.count...])
            switch entry.effect {
            case .block(let reason):
                return ProtectedDescendant(path: path, classification: Classification(risk: .never, block: reason))
            case .dangerous:
                if dangerous == nil { dangerous = ProtectedDescendant(path: path, classification: Classification(risk: .dangerous)) }
            case .allow:
                break
            }
        }
        return dangerous
    }
}
