import Foundation

// MCP tool catalog shared by the app (AppCore ToolHandler) and the `lightwell-mcp` helper (PLAN 3.7).
//
// Conventions for every tool:
// - Paths are accepted as absolute paths or `~/...`; outputs use `~` for the home folder.
// - Every result is compact JSON text of at most `ToolCatalog.maxResultBytes` bytes, paginated with an
//   opaque `cursor` / `next_cursor` pair.
// - No tool ever reads file contents.
// The descriptions below are read by the model, not shown in the UI.

/// One MCP tool exposed by the helper.
public struct ToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue, annotations: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    /// The tool as it appears in an MCP `tools/list` result.
    public var mcpListEntry: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": annotations,
        ]
    }

    /// Name the CLI uses for permission rules: `mcp__disk__<name>`.
    public var qualifiedName: String { "mcp__\(ToolCatalog.serverName)__\(name)" }
}

/// Names of the tools (PLAN 3.7).
public enum ToolName: String, CaseIterable, Sendable, Codable {
    case getDiskOverview = "get_disk_overview"
    case getLargestItems = "get_largest_items"
    case listChildren = "list_children"
    case getCategorySummary = "get_category_summary"
    case inspectPath = "inspect_path"
    case searchItems = "search_items"
    case getCleanupQueue = "get_cleanup_queue"
    case proposeDeletion = "propose_deletion"
}

/// Static tool catalog (PLAN 3.7). Frozen contract: `ToolCatalog.all`.
public enum ToolCatalog {
    /// MCP server name used in the CLI config (tools appear as `mcp__disk__<name>`).
    public static let serverName = "disk"

    /// Upper bound for the JSON text of one tool result (24 KiB, well under the CLI's MCP output cap).
    public static let maxResultBytes = 24 * 1024

    /// Maximum number of paths in one `propose_deletion` call.
    public static let maxProposalItems = 50

    /// Fixed note returned with every proposal.
    public static let proposalNote = "Nothing was deleted. The user reviews and confirms in the app."

    /// Text returned by the helper for every call while the app cannot be reached.
    public static let appUnavailableText = "Open Lightwell and scan a disk first."

    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: ToolName.getDiskOverview.rawValue,
            description: "Totals for the scanned volume: capacity, used, free and purgeable bytes, space on other volumes, space the scan could not see (hidden), the scanned root, how old the scan is in seconds, Full Disk Access state and the local snapshot count. Call this first.",
            inputSchema: Schema.object([:]),
            annotations: Annotations.readOnly(title: "Disk overview")
        ),
        ToolDefinition(
            name: ToolName.getLargestItems.rawValue,
            description: "Largest files or folders from the latest scan, biggest first. Defaults to the whole scan and every descendant. frees_bytes estimates what removing the item would really free (hard links and clones shared with other items are not counted).",
            inputSchema: Schema.object([
                "path": Schema.path("Folder to look inside. Absolute or ~/... Defaults to the scanned root."),
                "limit": Schema.integer("Number of items to return.", minimum: 1, maximum: 100, defaultValue: 20),
                "min_bytes": Schema.integer("Skip items smaller than this many bytes.", minimum: 0),
                "kind": Schema.enumeration("Only files, only directories, or both.", ["file", "directory", "any"], defaultValue: "any"),
                "scope": Schema.enumeration("children: direct children only. descendants: anything below the path.", ["children", "descendants"], defaultValue: "descendants"),
                "cursor": Schema.cursor,
            ]),
            annotations: Annotations.readOnly(title: "Largest items")
        ),
        ToolDefinition(
            name: ToolName.listChildren.rawValue,
            description: "Direct children of one folder from the latest scan, with sizes.",
            inputSchema: Schema.object([
                "path": Schema.path("Folder to list. Absolute or ~/..."),
                "limit": Schema.integer("Number of items to return.", minimum: 1, maximum: 200, defaultValue: 50),
                "sort": Schema.enumeration("Sort order.", ["size", "name"], defaultValue: "size"),
                "cursor": Schema.cursor,
            ], required: ["path"]),
            annotations: Annotations.readOnly(title: "List folder")
        ),
        ToolDefinition(
            name: ToolName.getCategorySummary.rawValue,
            description: "Known reclaimable categories found in the scan (caches, build products, simulators, installers and so on) with their rule id, risk level, total bytes and item count. action is trash when the app can move the items to the Trash, guide when the user should run command_hint instead.",
            inputSchema: Schema.object([:]),
            annotations: Annotations.readOnly(title: "Category summary")
        ),
        ToolDefinition(
            name: ToolName.inspectPath.rawValue,
            description: "Details for one path: size, what removing it would free, item count, dates, owning app, matching rule, risk level with an explanation, and whether the app protects it from deletion. Use this before proposing anything.",
            inputSchema: Schema.object([
                "path": Schema.path("Path to inspect. Absolute or ~/..."),
            ], required: ["path"]),
            annotations: Annotations.readOnly(title: "Inspect path")
        ),
        ToolDefinition(
            name: ToolName.searchItems.rawValue,
            description: "Find items in the scan by name pattern, extension, size or age. Dates are checked for at most 2000 candidates.",
            inputSchema: Schema.object([
                "under": Schema.path("Folder to search in. Absolute or ~/... Defaults to the scanned root."),
                "name_glob": .object(["type": "string", "description": "Shell-style pattern for the item name, for example *.dmg."]),
                "extension": .object(["type": "string", "description": "File extension without the dot, for example zip."]),
                "min_bytes": Schema.integer("Skip items smaller than this many bytes.", minimum: 0),
                "older_than_days": Schema.integer("Only items not modified for this many days.", minimum: 0),
                "limit": Schema.integer("Number of items to return.", minimum: 1, maximum: 100, defaultValue: 30),
                "cursor": Schema.cursor,
            ]),
            annotations: Annotations.readOnly(title: "Search items")
        ),
        ToolDefinition(
            name: ToolName.getCleanupQueue.rawValue,
            description: "What is currently waiting in the user's cleanup queue, with sizes, risk, where each item came from and whether it is selected.",
            inputSchema: Schema.object([:]),
            annotations: Annotations.readOnly(title: "Cleanup queue")
        ),
        ToolDefinition(
            name: ToolName.proposeDeletion.rawValue,
            description: "Suggest items for the user to remove. This never deletes anything: accepted items are added to the cleanup queue unselected, and the user reviews and confirms them in the app. Protected or dangerous paths are rejected with a reason. At most 50 items per call; give a short reason for each item and a one-sentence summary.",
            inputSchema: Schema.object([
                "items": .object([
                    "type": "array",
                    "minItems": 1,
                    "maxItems": .int(Int64(maxProposalItems)),
                    "description": "Items to suggest.",
                    "items": Schema.object([
                        "path": Schema.path("Path from the scan. Absolute or ~/..."),
                        "reason": .object(["type": "string", "description": "Why this item is worth removing."]),
                    ], required: ["path", "reason"]),
                ]),
                "summary": .object(["type": "string", "description": "One sentence the user sees above the suggestions."]),
            ], required: ["items", "summary"]),
            annotations: [
                "title": "Suggest cleanup",
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ]
        ),
    ]

    /// Looks up a tool by its short name.
    public static func definition(named name: String) -> ToolDefinition? {
        all.first { $0.name == name }
    }

    /// Value of `--allowedTools`: every tool, qualified, space separated.
    public static var allowedToolsArgument: String {
        all.map(\.qualifiedName).joined(separator: " ")
    }

    private enum Schema {
        static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            var schema: [String: JSONValue] = [
                "type": "object",
                "properties": .object(properties),
                "additionalProperties": false,
            ]
            if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
            return .object(schema)
        }

        static func path(_ description: String) -> JSONValue {
            ["type": "string", "description": .string(description)]
        }

        static func integer(_ description: String, minimum: Int64, maximum: Int64? = nil, defaultValue: Int64? = nil) -> JSONValue {
            var schema: [String: JSONValue] = ["type": "integer", "description": .string(description), "minimum": .int(minimum)]
            if let maximum { schema["maximum"] = .int(maximum) }
            if let defaultValue { schema["default"] = .int(defaultValue) }
            return .object(schema)
        }

        static func enumeration(_ description: String, _ values: [String], defaultValue: String) -> JSONValue {
            [
                "type": "string",
                "description": .string(description),
                "enum": .array(values.map { .string($0) }),
                "default": .string(defaultValue),
            ]
        }

        static let cursor: JSONValue = [
            "type": "string",
            "description": "Opaque next_cursor value from a previous call, to get the next page.",
        ]
    }

    private enum Annotations {
        static func readOnly(title: String) -> JSONValue {
            ["title": .string(title), "readOnlyHint": true, "openWorldHint": false]
        }
    }
}

// MARK: - Arguments

/// A tool argument problem, reported back to the model as an error result.
public struct ToolArgumentError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Decoding of tool arguments with the defaults and limits from the catalog.
public enum ToolArguments {
    /// Decodes `arguments` (a JSON object, or null for none) into `type`. Out-of-range limits are clamped.
    public static func decode<T: ToolArgumentsType>(_ type: T.Type, from arguments: JSONValue) throws(ToolArgumentError) -> T {
        let object: JSONValue = arguments == .null ? .object([:]) : arguments
        guard case .object = object else { throw ToolArgumentError("arguments must be a JSON object") }
        let value: T
        do {
            let data = try JSONEncoder().encode(object)
            value = try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw ToolArgumentError(describe(error))
        } catch {
            throw ToolArgumentError("arguments could not be read")
        }
        return try value.validated()
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "arguments" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, _): return "missing required argument \(key.stringValue)"
        case .typeMismatch(_, let context): return "wrong type for \(path(context))"
        case .valueNotFound(_, let context): return "missing value for \(path(context))"
        case .dataCorrupted(let context): return "invalid value for \(path(context))"
        @unknown default: return "arguments could not be read"
        }
    }
}

/// Arguments of one tool. `validated()` applies defaults and limits.
public protocol ToolArgumentsType: Decodable, Encodable, Sendable, Hashable {
    static var tool: ToolName { get }
    func validated() throws(ToolArgumentError) -> Self
}

extension ToolArgumentsType {
    public func validated() throws(ToolArgumentError) -> Self { self }
}

func clamp(_ value: Int?, _ range: ClosedRange<Int>, default defaultValue: Int) -> Int {
    min(max(value ?? defaultValue, range.lowerBound), range.upperBound)
}

public struct GetDiskOverviewArguments: ToolArgumentsType {
    public static let tool = ToolName.getDiskOverview
    public init() {}
}

public struct GetCategorySummaryArguments: ToolArgumentsType {
    public static let tool = ToolName.getCategorySummary
    public init() {}
}

public struct GetCleanupQueueArguments: ToolArgumentsType {
    public static let tool = ToolName.getCleanupQueue
    public init() {}
}

public enum ItemKindFilter: String, Codable, Sendable, Hashable { case file, directory, any }
public enum ItemScope: String, Codable, Sendable, Hashable { case children, descendants }
public enum ChildSort: String, Codable, Sendable, Hashable { case size, name }

public struct GetLargestItemsArguments: ToolArgumentsType {
    public static let tool = ToolName.getLargestItems
    public var path: String?
    public var limit: Int?
    public var minBytes: UInt64?
    public var kind: ItemKindFilter?
    public var scope: ItemScope?
    public var cursor: String?

    enum CodingKeys: String, CodingKey {
        case path, limit, kind, scope, cursor
        case minBytes = "min_bytes"
    }

    public init(path: String? = nil, limit: Int? = nil, minBytes: UInt64? = nil, kind: ItemKindFilter? = nil, scope: ItemScope? = nil, cursor: String? = nil) {
        self.path = path
        self.limit = limit
        self.minBytes = minBytes
        self.kind = kind
        self.scope = scope
        self.cursor = cursor
    }

    public func validated() throws(ToolArgumentError) -> Self {
        var copy = self
        copy.limit = clamp(limit, 1...100, default: 20)
        copy.kind = kind ?? .any
        copy.scope = scope ?? .descendants
        return copy
    }
}

public struct ListChildrenArguments: ToolArgumentsType {
    public static let tool = ToolName.listChildren
    public var path: String
    public var limit: Int?
    public var sort: ChildSort?
    public var cursor: String?

    public init(path: String, limit: Int? = nil, sort: ChildSort? = nil, cursor: String? = nil) {
        self.path = path
        self.limit = limit
        self.sort = sort
        self.cursor = cursor
    }

    public func validated() throws(ToolArgumentError) -> Self {
        guard !path.isEmpty else { throw ToolArgumentError("path must not be empty") }
        var copy = self
        copy.limit = clamp(limit, 1...200, default: 50)
        copy.sort = sort ?? .size
        return copy
    }
}

public struct InspectPathArguments: ToolArgumentsType {
    public static let tool = ToolName.inspectPath
    public var path: String

    public init(path: String) { self.path = path }

    public func validated() throws(ToolArgumentError) -> Self {
        guard !path.isEmpty else { throw ToolArgumentError("path must not be empty") }
        return self
    }
}

public struct SearchItemsArguments: ToolArgumentsType {
    public static let tool = ToolName.searchItems
    /// Dates are stat'ed lazily for at most this many candidates.
    public static let maxDateCandidates = 2000
    public var under: String?
    public var nameGlob: String?
    public var `extension`: String?
    public var minBytes: UInt64?
    public var olderThanDays: Int?
    public var limit: Int?
    public var cursor: String?

    enum CodingKeys: String, CodingKey {
        case under, `extension`, limit, cursor
        case nameGlob = "name_glob"
        case minBytes = "min_bytes"
        case olderThanDays = "older_than_days"
    }

    public init(under: String? = nil, nameGlob: String? = nil, extension: String? = nil, minBytes: UInt64? = nil, olderThanDays: Int? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.under = under
        self.nameGlob = nameGlob
        self.extension = `extension`
        self.minBytes = minBytes
        self.olderThanDays = olderThanDays
        self.limit = limit
        self.cursor = cursor
    }

    public func validated() throws(ToolArgumentError) -> Self {
        if let olderThanDays, olderThanDays < 0 { throw ToolArgumentError("older_than_days must not be negative") }
        var copy = self
        copy.limit = clamp(limit, 1...100, default: 30)
        if let ext = `extension`, ext.hasPrefix(".") { copy.extension = String(ext.dropFirst()) }
        return copy
    }
}

public struct ProposedPath: Codable, Sendable, Hashable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ProposeDeletionArguments: ToolArgumentsType {
    public static let tool = ToolName.proposeDeletion
    public var items: [ProposedPath]
    public var summary: String

    public init(items: [ProposedPath], summary: String) {
        self.items = items
        self.summary = summary
    }

    public func validated() throws(ToolArgumentError) -> Self {
        guard !items.isEmpty else { throw ToolArgumentError("items must contain at least one path") }
        guard items.count <= ToolCatalog.maxProposalItems else {
            throw ToolArgumentError("items holds \(items.count) paths, the limit is \(ToolCatalog.maxProposalItems) per call")
        }
        if items.contains(where: { $0.path.isEmpty }) { throw ToolArgumentError("every item needs a path") }
        return self
    }
}

// MARK: - Results

/// Item shape shared by `get_largest_items`, `list_children` and `search_items`.
public struct ToolItem: Codable, Sendable, Hashable {
    public var path: String
    public var bytes: UInt64
    public var freesBytes: UInt64
    /// "file", "directory", "package", "symlink" or "other".
    public var kind: String
    /// Number of descendants (0 for files).
    public var items: Int
    public var ruleID: String?
    /// "safe", "review", "dangerous" or "never".
    public var risk: String?

    enum CodingKeys: String, CodingKey {
        case path, bytes, kind, items, risk
        case freesBytes = "frees_bytes"
        case ruleID = "rule_id"
    }

    public init(path: String, bytes: UInt64, freesBytes: UInt64, kind: String, items: Int, ruleID: String? = nil, risk: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.freesBytes = freesBytes
        self.kind = kind
        self.items = items
        self.ruleID = ruleID
        self.risk = risk
    }
}

public struct ToolItemList: Codable, Sendable, Hashable {
    public var items: [ToolItem]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }

    public init(items: [ToolItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct DiskOverviewResult: Codable, Sendable, Hashable {
    public var volume: String
    public var capacity: UInt64
    public var used: UInt64
    public var free: UInt64
    public var purgeable: UInt64
    public var otherVolumes: UInt64
    public var hidden: UInt64
    public var scannedRoot: String
    public var scanAgeSeconds: Int
    /// "granted", "denied" or "unknown".
    public var fda: String
    public var snapshotsCount: Int

    enum CodingKeys: String, CodingKey {
        case volume, capacity, used, free, purgeable, hidden, fda
        case otherVolumes = "other_volumes"
        case scannedRoot = "scanned_root"
        case scanAgeSeconds = "scan_age_s"
        case snapshotsCount = "snapshots_count"
    }

    public init(volume: String, capacity: UInt64, used: UInt64, free: UInt64, purgeable: UInt64, otherVolumes: UInt64, hidden: UInt64, scannedRoot: String, scanAgeSeconds: Int, fda: String, snapshotsCount: Int) {
        self.volume = volume
        self.capacity = capacity
        self.used = used
        self.free = free
        self.purgeable = purgeable
        self.otherVolumes = otherVolumes
        self.hidden = hidden
        self.scannedRoot = scannedRoot
        self.scanAgeSeconds = scanAgeSeconds
        self.fda = fda
        self.snapshotsCount = snapshotsCount
    }
}

public struct CategorySummaryEntry: Codable, Sendable, Hashable {
    public var ruleID: String
    public var title: String
    public var risk: String
    public var bytes: UInt64
    public var count: Int
    /// "trash" or "guide".
    public var action: String
    public var commandHint: String?

    enum CodingKeys: String, CodingKey {
        case title, risk, bytes, count, action
        case ruleID = "rule_id"
        case commandHint = "command_hint"
    }

    public init(ruleID: String, title: String, risk: String, bytes: UInt64, count: Int, action: String, commandHint: String? = nil) {
        self.ruleID = ruleID
        self.title = title
        self.risk = risk
        self.bytes = bytes
        self.count = count
        self.action = action
        self.commandHint = commandHint
    }
}

public struct CategorySummaryResult: Codable, Sendable, Hashable {
    public var categories: [CategorySummaryEntry]
    public init(categories: [CategorySummaryEntry]) { self.categories = categories }
}

public struct PathInspectionResult: Codable, Sendable, Hashable {
    public var path: String
    public var bytes: UInt64
    public var freesBytes: UInt64
    public var kind: String
    public var items: Int
    /// ISO 8601.
    public var modified: String?
    public var lastUsed: String?
    public var bundleID: String?
    public var ruleID: String?
    public var risk: String
    public var explanation: String
    public var protected: Bool
    public var protectionReason: String?
    public var hardLinks: Int?
    public var cloneSharedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case path, bytes, kind, items, modified, risk, explanation, protected
        case freesBytes = "frees_bytes"
        case lastUsed = "last_used"
        case bundleID = "bundle_id"
        case ruleID = "rule_id"
        case protectionReason = "protection_reason"
        case hardLinks = "hard_links"
        case cloneSharedBytes = "clone_shared_bytes"
    }

    public init(path: String, bytes: UInt64, freesBytes: UInt64, kind: String, items: Int, modified: String?, lastUsed: String? = nil, bundleID: String? = nil, ruleID: String? = nil, risk: String, explanation: String, protected: Bool, protectionReason: String? = nil, hardLinks: Int? = nil, cloneSharedBytes: UInt64? = nil) {
        self.path = path
        self.bytes = bytes
        self.freesBytes = freesBytes
        self.kind = kind
        self.items = items
        self.modified = modified
        self.lastUsed = lastUsed
        self.bundleID = bundleID
        self.ruleID = ruleID
        self.risk = risk
        self.explanation = explanation
        self.protected = protected
        self.protectionReason = protectionReason
        self.hardLinks = hardLinks
        self.cloneSharedBytes = cloneSharedBytes
    }
}

public struct CleanupQueueEntry: Codable, Sendable, Hashable {
    public var path: String
    public var bytes: UInt64
    public var risk: String
    /// "user", "category:<rule id>" or "assistant".
    public var source: String
    public var selected: Bool

    public init(path: String, bytes: UInt64, risk: String, source: String, selected: Bool) {
        self.path = path
        self.bytes = bytes
        self.risk = risk
        self.source = source
        self.selected = selected
    }
}

public struct CleanupQueueResult: Codable, Sendable, Hashable {
    public var items: [CleanupQueueEntry]
    public var totalBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case items
        case totalBytes = "total_bytes"
    }

    public init(items: [CleanupQueueEntry], totalBytes: UInt64) {
        self.items = items
        self.totalBytes = totalBytes
    }
}

public struct QueuedProposal: Codable, Sendable, Hashable {
    public var path: String
    public var bytes: UInt64
    public var risk: String

    public init(path: String, bytes: UInt64, risk: String) {
        self.path = path
        self.bytes = bytes
        self.risk = risk
    }
}

public struct RejectedProposalEntry: Codable, Sendable, Hashable {
    public var path: String
    /// Machine readable reason, e.g. a `BlockReason` raw value, "not_in_scan" or "dangerous".
    public var code: String
    public var message: String

    public init(path: String, code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
}

public struct ProposeDeletionResult: Codable, Sendable, Hashable {
    public var queued: [QueuedProposal]
    public var rejected: [RejectedProposalEntry]
    public var note: String

    public init(queued: [QueuedProposal], rejected: [RejectedProposalEntry], note: String = ToolCatalog.proposalNote) {
        self.queued = queued
        self.rejected = rejected
        self.note = note
    }
}

// MARK: - Output helpers

/// Encoding, size limit and pagination for tool results.
public enum ToolOutput {
    /// Compact JSON text (sorted keys, unescaped slashes) of a result.
    public static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Successful result.
    public static func result(_ value: some Encodable) -> ToolCallResult {
        ToolCallResult(text: encode(value), isError: false)
    }

    /// Error result with a plain message for the model.
    public static func error(_ message: String) -> ToolCallResult {
        ToolCallResult(text: message, isError: true)
    }

    /// Backstop for the result size cap: any text over `ToolCatalog.maxResultBytes` becomes an error
    /// result that tells the model how to ask for less. Applied by the app's IPC server and by the helper.
    public static func enforceSizeLimit(_ result: ToolCallResult, limit: Int = ToolCatalog.maxResultBytes) -> ToolCallResult {
        let size = result.text.utf8.count
        guard size > limit else { return result }
        return ToolCallResult(text: tooLargeMessage(size: size, limit: limit), isError: true)
    }

    public static func tooLargeMessage(size: Int, limit: Int = ToolCatalog.maxResultBytes) -> String {
        "The result was too large to return (\(size) bytes, the limit is \(limit)). Narrow the query: use a smaller limit, a more specific path or filter, or fetch the next page with cursor."
    }

    /// One page of `all`, starting at the cursor, holding at most `limit` items and keeping the
    /// encoded page within `budget` bytes. Throws when the cursor is malformed or from another scan,
    /// and when the next item alone does not fit the budget (the error carries a cursor that skips it).
    public static func page<T: Encodable>(_ all: [T], cursor: String?, limit: Int, generation: UInt64, budget: Int = ToolCatalog.maxResultBytes) throws(ToolArgumentError) -> (items: [T], nextCursor: String?) {
        var offset = 0
        if let cursor, !cursor.isEmpty {
            guard let parsed = ToolCursor(token: cursor) else { throw ToolArgumentError("cursor is not valid, repeat the call without it") }
            guard parsed.generation == generation else { throw ToolArgumentError("cursor belongs to an older scan, repeat the call without it") }
            offset = min(max(parsed.offset, 0), all.count)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Room for the wrapper object and a cursor.
        var used = 128
        var page: [T] = []
        var index = offset
        while index < all.count, page.count < max(limit, 1) {
            let size = ((try? encoder.encode(all[index]))?.count ?? 0) + 1
            if used + size > budget {
                guard page.isEmpty else { break }
                let skip = ToolCursor(offset: index + 1, generation: generation).token
                throw ToolArgumentError("The item at position \(index) is larger than the \(budget) byte result limit and was left out. Continue with cursor \(skip), or inspect a deeper folder.")
            }
            used += size
            page.append(all[index])
            index += 1
        }
        let next = index < all.count ? ToolCursor(offset: index, generation: generation).token : nil
        return (page, next)
    }
}

/// Opaque pagination cursor: scan generation plus offset.
public struct ToolCursor: Sendable, Hashable {
    public var offset: Int
    public var generation: UInt64

    public init(offset: Int, generation: UInt64) {
        self.offset = offset
        self.generation = generation
    }

    public init?(token: String) {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: ":")
        guard parts.count == 3, parts[0] == "c1", let generation = UInt64(parts[1]), let offset = Int(parts[2]), offset >= 0 else { return nil }
        self.init(offset: offset, generation: generation)
    }

    public var token: String {
        Data("c1:\(generation):\(offset)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Path conventions for tool input and output.
public enum ToolPaths {
    /// `~` or `~/x` to an absolute path under `home`. Absolute paths are standardized. Returns nil for
    /// relative paths, which tools reject.
    public static func expand(_ path: String, home: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute: String
        if trimmed == "~" {
            absolute = home
        } else if trimmed.hasPrefix("~/") {
            absolute = (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            return nil
        }
        // Lexical clean-up only ("." and ".." and empty components); symlinks and /private are left alone.
        var components: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Absolute path to the `~` form when it is inside `home`.
    public static func abbreviate(_ path: String, home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !base.isEmpty else { return path }
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }
}
