import Foundation
import ScanKit

/// What the app offers for a rule: move to Trash, or show guidance only (`guide`: the
/// `commandHint` is shown with a Copy button and never executed).
public enum RuleAction: String, Codable, Sendable {
    case trash
    case guide
}

/// How a `RuleMatch` path selects items (PLAN 2.6).
public enum MatchKind: String, Codable, Sendable, CaseIterable {
    /// Only the item at `path` (components may contain `*`; contents are not covered).
    case exact
    /// The item at `path` and everything inside it.
    case subtree
    /// Every direct child of `path` (and their contents); the folder itself stays.
    case childrenOf
    /// Like `subtree`, but components may contain `*` (one component, any characters).
    case glob
}

/// One path pattern of a rule. `path` is absolute or starts with `~/`.
public struct RuleMatch: Codable, Sendable, Hashable {
    public var path: String
    public var kind: MatchKind

    public init(path: String, kind: MatchKind) {
        self.path = path
        self.kind = kind
    }
}

/// Condition checked by the executor right before an item of this rule is removed.
public enum RulePrecondition: Sendable, Hashable, Codable {
    /// The app with this bundle identifier must not be running.
    case appNotRunning(bundleID: String)

    private enum CodingKeys: String, CodingKey { case type, bundleID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "appNotRunning":
            self = .appNotRunning(bundleID: try container.decode(String.self, forKey: .bundleID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown precondition type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appNotRunning(let bundleID):
            try container.encode("appNotRunning", forKey: .type)
            try container.encode(bundleID, forKey: .bundleID)
        }
    }
}

/// Code detectors that find items no path pattern can describe.
public enum RuleDetector: String, Codable, Sendable, CaseIterable {
    /// Regenerable build folders next to a project marker (`node_modules` + `package.json`, ...).
    case devArtifacts
    /// Installer files (`.dmg`, `.pkg`, `.zip`) directly in `~/Downloads`, older than `minAgeDays`.
    case oldInstallers
}

/// One knowledge base entry from `rules.json` (PLAN 2.6 schema).
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// JSON key `category`.
    public var categoryID: String
    public var risk: Risk
    public var title: String
    public var explanation: String
    public var match: [RuleMatch]
    /// JSON `{"type": "trash" | "guide"}`.
    public var action: RuleAction
    public var preconditions: [RulePrecondition]
    /// Only items at least this many days old belong to the rule (unknown age never counts as old).
    public var minAgeDays: Int?
    /// Keep the newest N children of each matched folder (for example one DeviceSupport per platform).
    public var keepNewest: Int?
    /// Command shown with a Copy button, never executed.
    public var commandHint: String?
    /// Set for rules whose items come from a code detector instead of `match`.
    public var detector: RuleDetector?

    public init(
        id: String,
        categoryID: String,
        risk: Risk,
        title: String,
        explanation: String,
        match: [RuleMatch],
        action: RuleAction,
        preconditions: [RulePrecondition] = [],
        minAgeDays: Int? = nil,
        keepNewest: Int? = nil,
        commandHint: String? = nil,
        detector: RuleDetector? = nil
    ) {
        self.id = id
        self.categoryID = categoryID
        self.risk = risk
        self.title = title
        self.explanation = explanation
        self.match = match
        self.action = action
        self.preconditions = preconditions
        self.minAgeDays = minAgeDays
        self.keepNewest = keepNewest
        self.commandHint = commandHint
        self.detector = detector
    }

    /// Match paths, for display.
    public var patterns: [String] { match.map(\.path) }

    /// Bundle identifiers that must not be running when items of this rule are removed.
    public var requiredQuitApps: [String] {
        preconditions.map { if case .appNotRunning(let id) = $0 { id } else { "" } }.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, risk, title, explanation, match, action, preconditions, minAgeDays, keepNewest, commandHint, detector
    }

    private struct ActionBox: Codable { var type: RuleAction }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        categoryID = try c.decode(String.self, forKey: .category)
        risk = try c.decode(Risk.self, forKey: .risk)
        title = try c.decode(String.self, forKey: .title)
        explanation = try c.decode(String.self, forKey: .explanation)
        match = try c.decodeIfPresent([RuleMatch].self, forKey: .match) ?? []
        action = try c.decode(ActionBox.self, forKey: .action).type
        preconditions = try c.decodeIfPresent([RulePrecondition].self, forKey: .preconditions) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        keepNewest = try c.decodeIfPresent(Int.self, forKey: .keepNewest)
        commandHint = try c.decodeIfPresent(String.self, forKey: .commandHint)
        detector = try c.decodeIfPresent(RuleDetector.self, forKey: .detector)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(categoryID, forKey: .category)
        try c.encode(risk, forKey: .risk)
        try c.encode(title, forKey: .title)
        try c.encode(explanation, forKey: .explanation)
        try c.encode(match, forKey: .match)
        try c.encode(ActionBox(type: action), forKey: .action)
        try c.encode(preconditions, forKey: .preconditions)
        try c.encode(minAgeDays, forKey: .minAgeDays)
        try c.encode(keepNewest, forKey: .keepNewest)
        try c.encode(commandHint, forKey: .commandHint)
        try c.encodeIfPresent(detector, forKey: .detector)
    }
}

struct RulesFile: Codable {
    var version: Int
    var rules: [Rule]
}

public enum RuleLoadError: Error, Sendable, CustomStringConvertible {
    case missingResource
    case unsupportedVersion(Int)
    case invalid([RuleValidationIssue])

    public var description: String {
        switch self {
        case .missingResource: "rules.json is missing from the RulesKit bundle"
        case .unsupportedVersion(let v): "rules.json version \(v) is not supported"
        case .invalid(let issues): "rules.json is invalid: " + issues.map(\.description).joined(separator: "; ")
        }
    }
}

/// Loads and validates rule files.
public enum RuleLoader {
    public static let supportedVersion = 1

    /// Decodes and validates a rules file. Throws on decode errors or validation issues.
    public static func decode(_ data: Data) throws -> [Rule] {
        let file = try JSONDecoder().decode(RulesFile.self, from: data)
        guard file.version == supportedVersion else { throw RuleLoadError.unsupportedVersion(file.version) }
        let issues = RuleValidator.validate(file.rules)
        guard issues.isEmpty else { throw RuleLoadError.invalid(issues) }
        return file.rules
    }

    /// Loads the bundled `rules.json`, throwing on any problem (tests use this to fail loudly).
    public static func loadBundled() throws -> [Rule] {
        guard let url = bundledURL else { throw RuleLoadError.missingResource }
        return try decode(Data(contentsOf: url))
    }

    static var bundledURL: URL? { Bundle.module.url(forResource: "rules", withExtension: "json") }

    static let bundledCache: [Rule] = {
        do {
            return try loadBundled()
        } catch {
            assertionFailure("Bundled rules.json failed to load: \(error)")
            return []
        }
    }()
}

extension Array where Element == Rule {
    /// Rules bundled in `RulesKit/Resources/rules.json` (loaded once). Empty only if the bundled
    /// file is broken, which the test suite rules out (`RuleLoader.loadBundled()` throws).
    public static var bundled: [Rule] { RuleLoader.bundledCache }
}

/// One problem found by `RuleValidator`.
public struct RuleValidationIssue: Sendable, Hashable, CustomStringConvertible {
    public var ruleID: String
    public var message: String

    public var description: String { "\(ruleID): \(message)" }
}

/// Structural checks for rule sets (PLAN 2.6 acceptance).
public enum RuleValidator {
    static let dashes: [Character] = ["\u{2013}", "\u{2014}"]

    public static func validate(_ rules: [Rule]) -> [RuleValidationIssue] {
        var issues: [RuleValidationIssue] = []
        var seen: Set<String> = []
        func issue(_ rule: Rule, _ message: String) {
            issues.append(RuleValidationIssue(ruleID: rule.id, message: message))
        }
        for rule in rules {
            if rule.id.isEmpty || !rule.id.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "." })
                || rule.id.hasPrefix(".") || rule.id.hasSuffix(".") || rule.id.contains("..") {
                issue(rule, "id must be lowercase words separated by dots")
            }
            if !seen.insert(rule.id).inserted { issue(rule, "duplicate id") }
            if rule.categoryID.trimmingCharacters(in: .whitespaces).isEmpty { issue(rule, "empty category") }
            if rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issue(rule, "empty title") }
            if rule.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issue(rule, "empty explanation") }
            for text in [rule.title, rule.explanation, rule.commandHint ?? ""] where text.contains(where: dashes.contains) {
                issue(rule, "contains an em or en dash")
            }
            for m in rule.match {
                if !(m.path.hasPrefix("/") || m.path.hasPrefix("~/")) { issue(rule, "match path must be absolute or start with ~/: \(m.path)") }
                if m.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { issue(rule, "match path has . or ..: \(m.path)") }
                if m.path.hasSuffix("/") { issue(rule, "match path ends with /: \(m.path)") }
                let hasGlob = m.path.contains("*")
                if m.kind == .glob && !hasGlob { issue(rule, "glob match without *: \(m.path)") }
                if (m.kind == .subtree || m.kind == .childrenOf) && hasGlob { issue(rule, "* is only allowed in glob and exact matches: \(m.path)") }
            }
            if rule.detector != nil && !rule.match.isEmpty { issue(rule, "detector rules have no match paths") }
            if rule.action == .trash && rule.match.isEmpty && rule.detector == nil { issue(rule, "trash rule needs match paths or a detector") }
            if rule.risk >= .dangerous && rule.action != .guide { issue(rule, "dangerous and never rules must be guide only") }
            if rule.action == .guide && rule.risk == .safe && !rule.match.isEmpty && rule.commandHint == nil {
                issue(rule, "safe guide rule needs a command hint")
            }
            if rule.action == .guide && !rule.preconditions.isEmpty { issue(rule, "guide rules are never executed, so preconditions have no effect") }
            if let k = rule.keepNewest, k < 1 { issue(rule, "keepNewest must be at least 1") }
            if let d = rule.minAgeDays, d < 1 { issue(rule, "minAgeDays must be at least 1") }
            if rule.detector == .oldInstallers && rule.minAgeDays == nil { issue(rule, "oldInstallers needs minAgeDays") }
            for case .appNotRunning(let bundleID) in rule.preconditions where bundleID.isEmpty {
                issue(rule, "empty bundleID in precondition")
            }
        }
        return issues
    }
}

/// Aggregated bytes for one rule over a scanned tree.
public struct CategoryResult: Sendable, Hashable, Identifiable {
    public var ruleID: String
    public var title: String
    public var categoryID: String
    public var risk: Risk
    public var bytes: UInt64
    public var count: Int
    /// Topmost matched nodes, largest first. Never nested inside each other.
    public var nodes: [NodeID]
    public var action: RuleAction
    public var explanation: String
    public var commandHint: String?
    /// Additive: age in days per node when known (project age for build folders, item age for
    /// rules with `minAgeDays`).
    public var ageDaysByNode: [NodeID: Int]

    public var id: String { ruleID }

    public init(ruleID: String, title: String, categoryID: String, risk: Risk, bytes: UInt64, count: Int, nodes: [NodeID], action: RuleAction, explanation: String, commandHint: String? = nil, ageDaysByNode: [NodeID: Int] = [:]) {
        self.ruleID = ruleID
        self.title = title
        self.categoryID = categoryID
        self.risk = risk
        self.bytes = bytes
        self.count = count
        self.nodes = nodes
        self.action = action
        self.explanation = explanation
        self.commandHint = commandHint
        self.ageDaysByNode = ageDaysByNode
    }
}
