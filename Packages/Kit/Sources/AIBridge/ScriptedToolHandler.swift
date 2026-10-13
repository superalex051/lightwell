import Foundation
import IPCProtocol
import Synchronization

/// One tool call seen by `ScriptedToolHandler`.
public struct RecordedToolCall: Sendable, Hashable {
    public var name: String
    public var arguments: JSONValue
    public var thread: UUID
}

/// Test double for `AssistantToolHandler` (UI tests, AIBridge and AppCore tests). Not used in production.
///
/// - `propose_deletion`: each path is expanded (`~` against `home`); paths equal to or inside one of
///   `protectedPaths` are rejected with code `protected`; when `knownPaths` is not empty, paths missing
///   from it are rejected with code `not_in_scan`; everything else is queued with its known size.
/// - Other tools return `responses[name]` when set, otherwise a small canned answer.
/// - Every call is recorded in `calls`.
public final class ScriptedToolHandler: AssistantToolHandler {
    public let home: String
    public let knownPaths: [String: UInt64]
    public let protectedPaths: [String]
    public let responses: [String: ToolCallResult]
    /// Risk reported for known paths (absolute path -> "safe", "review", ...); default "review".
    public let risks: [String: String]
    private let recorded = Mutex<[RecordedToolCall]>([])

    public init(home: String = NSHomeDirectory(), knownPaths: [String: UInt64] = [:], protectedPaths: [String] = [], responses: [String: ToolCallResult] = [:], risks: [String: String] = [:]) {
        self.risks = risks
        self.home = home
        self.knownPaths = knownPaths
        self.protectedPaths = protectedPaths
        self.responses = responses
    }

    public var calls: [RecordedToolCall] {
        recorded.withLock { $0 }
    }

    public func handle(name: String, arguments: JSONValue, thread: UUID) async -> ToolCallResult {
        recorded.withLock { $0.append(RecordedToolCall(name: name, arguments: arguments, thread: thread)) }
        if let response = responses[name] { return response }
        switch ToolName(rawValue: name) {
        case .proposeDeletion:
            return propose(arguments)
        case .getDiskOverview:
            return ToolOutput.result(DiskOverviewResult(
                volume: "Test Volume", capacity: 500_000_000_000, used: 300_000_000_000, free: 200_000_000_000,
                purgeable: 0, otherVolumes: 0, hidden: 0, scannedRoot: "~", scanAgeSeconds: 60, fda: "unknown", snapshotsCount: 0
            ))
        case .getLargestItems, .listChildren, .searchItems:
            let items = knownPaths.sorted { $0.value > $1.value }.map { path, bytes in
                ToolItem(path: ToolPaths.abbreviate(path, home: home), bytes: bytes, freesBytes: bytes, kind: "file", items: 0, risk: isProtected(path) ? "never" : (risks[path] ?? "review"))
            }
            return ToolOutput.result(ToolItemList(items: items))
        case .getCategorySummary:
            return ToolOutput.result(CategorySummaryResult(categories: []))
        case .getCleanupQueue:
            return ToolOutput.result(CleanupQueueResult(items: [], totalBytes: 0))
        case .inspectPath:
            guard let raw = arguments["path"]?.stringValue, let path = ToolPaths.expand(raw, home: home) else {
                return ToolOutput.error("missing required argument path")
            }
            let protected = isProtected(path)
            guard protected || knownPaths[path] != nil else { return ToolOutput.error("This path is not in the current scan.") }
            return ToolOutput.result(PathInspectionResult(
                path: ToolPaths.abbreviate(path, home: home), bytes: knownPaths[path] ?? 0, freesBytes: knownPaths[path] ?? 0,
                kind: "directory", items: 1, modified: nil, risk: protected ? "never" : (risks[path] ?? "review"),
                explanation: protected ? "Protected location." : "Scripted test item.", protected: protected,
                protectionReason: protected ? "protected" : nil
            ))
        case nil:
            return ToolOutput.error("Unknown tool: \(name)")
        }
    }

    private func propose(_ arguments: JSONValue) -> ToolCallResult {
        let request: ProposeDeletionArguments
        do {
            request = try ToolArguments.decode(ProposeDeletionArguments.self, from: arguments)
        } catch {
            return ToolOutput.error(error.message)
        }
        var queued: [QueuedProposal] = []
        var rejected: [RejectedProposalEntry] = []
        for item in request.items {
            guard let path = ToolPaths.expand(item.path, home: home) else {
                rejected.append(RejectedProposalEntry(path: item.path, code: "invalid_path", message: "Use an absolute path or ~/..."))
                continue
            }
            let shown = ToolPaths.abbreviate(path, home: home)
            if isProtected(path) {
                rejected.append(RejectedProposalEntry(path: shown, code: "protected", message: "This location is protected and cannot be removed."))
            } else if !knownPaths.isEmpty, knownPaths[path] == nil {
                rejected.append(RejectedProposalEntry(path: shown, code: "not_in_scan", message: "This path is not in the current scan."))
            } else {
                queued.append(QueuedProposal(path: shown, bytes: knownPaths[path] ?? 0, risk: risks[path] ?? "review"))
            }
        }
        return ToolOutput.result(ProposeDeletionResult(queued: queued, rejected: rejected))
    }

    private func isProtected(_ path: String) -> Bool {
        protectedPaths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
