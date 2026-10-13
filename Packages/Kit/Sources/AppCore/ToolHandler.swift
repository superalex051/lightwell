import AIBridge
import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit

/// The scan a tool call answers from (taken from the active session on the main actor).
public struct ToolScanContext: Sendable {
    public var tree: any TreeReading
    /// Rules and safety policy for this scan (home and scan root injected).
    public var engine: RuleEngine
    public var volume: VolumeInfo?
    public var summary: SpaceSummary?
    public var categories: [CategoryResult]
    public var finishedAt: Date
    public var isVolumeScan: Bool

    public init(tree: any TreeReading, engine: RuleEngine, volume: VolumeInfo?, summary: SpaceSummary?, categories: [CategoryResult], finishedAt: Date, isVolumeScan: Bool) {
        self.tree = tree
        self.engine = engine
        self.volume = volume
        self.summary = summary
        self.categories = categories
        self.finishedAt = finishedAt
        self.isVolumeScan = isVolumeScan
    }
}

/// Everything a tool call can see.
public struct ToolContext: Sendable {
    public var scan: ToolScanContext?
    /// True while a scan runs and no finished scan is available yet.
    public var isScanning: Bool
    public var queue: [QueueItem]
    public var fda: FDAStatus

    public init(scan: ToolScanContext? = nil, isScanning: Bool = false, queue: [QueueItem] = [], fda: FDAStatus = .unknown) {
        self.scan = scan
        self.isScanning = isScanning
        self.queue = queue
        self.fda = fda
    }
}

/// One proposed item that passed the tool's checks, handed to the cleanup queue.
public struct ToolProposal: Sendable {
    public var node: NodeID
    public var tree: any TreeReading
    public var path: String
    public var risk: Risk
    public var ruleID: String?
    public var reason: String
}

/// How the tools reach the stores. Built by `AppModel`; tests build it directly.
public struct ToolEnvironment: Sendable {
    public var context: @Sendable @MainActor () -> ToolContext
    /// Queues proposals (unselected, source assistant) and returns one result per proposal.
    public var enqueue: @Sendable @MainActor (_ thread: UUID, _ proposals: [ToolProposal]) -> [AddResult]
    /// Shows the proposal card in the assistant transcript.
    public var proposalMade: @Sendable @MainActor (_ thread: UUID, _ batch: ProposalBatch) -> Void
    public var metadata: ItemMetadata
    public var snapshots: SnapshotCounter
    public var now: @Sendable () -> Date

    public init(
        context: @escaping @Sendable @MainActor () -> ToolContext,
        enqueue: @escaping @Sendable @MainActor (_ thread: UUID, _ proposals: [ToolProposal]) -> [AddResult],
        proposalMade: @escaping @Sendable @MainActor (_ thread: UUID, _ batch: ProposalBatch) -> Void = { _, _ in },
        metadata: ItemMetadata = .live,
        snapshots: SnapshotCounter = SnapshotCounter(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.enqueue = enqueue
        self.proposalMade = proposalMade
        self.metadata = metadata
        self.snapshots = snapshots
        self.now = now
    }
}

/// Answers the assistant's MCP tool calls from the current scan (PLAN 3.7).
///
/// Every answer is compact JSON with `~` paths, at most 24 KB (paged with opaque cursors tied to
/// the tree generation). No tool reads file contents. `propose_deletion` only queues: paths must
/// be nodes of the current scan, the safety policy and rules run first, never and dangerous items
/// (and folders holding them) are rejected with the reason, guide rules are rejected with their
/// command, and the rest is queued unselected with source `assistant(thread, reason)`.
///
/// Texts in tool results are read by the model, not shown in the UI, so they are plain English
/// constants and not in a String Catalog (same rule as IPCProtocol, see Task 3 decision 8).
public final class ToolHandler: AssistantToolHandler {
    public let environment: ToolEnvironment

    public init(environment: ToolEnvironment) {
        self.environment = environment
    }

    /// Rejection code for items only the user may queue (dangerous, or holding a dangerous item).
    public static let needsUserChoiceCode = "needs_user_choice"

    static let noScanText = "No scan is loaded yet. Ask the user to scan a disk or folder in Lightwell first."
    static let scanningText = "A scan is still running. Try again in a moment, when it has finished."
    static let notInScanText = "This path is not in the current scan."
    static let changedText = "This item is gone or changed since the scan."

    /// Always runs off the main actor (`@concurrent`), whoever calls it: queries over a large tree
    /// must never stall the UI. Only the context snapshot and the queue changes hop to the main actor.
    @concurrent
    public func handle(name: String, arguments: JSONValue, thread: UUID) async -> ToolCallResult {
        guard let tool = ToolName(rawValue: name) else { return ToolOutput.error("Unknown tool: \(name)") }
        let context = await environment.context()
        let result: ToolCallResult
        do {
            switch tool {
            case .getCleanupQueue:
                result = cleanupQueue(context, home: context.scan?.engine.home ?? NSHomeDirectory())
            case .proposeDeletion:
                result = try await propose(ToolArguments.decode(ProposeDeletionArguments.self, from: arguments), context: context, thread: thread)
            default:
                guard let scan = context.scan else {
                    return ToolOutput.error(context.isScanning ? Self.scanningText : Self.noScanText)
                }
                switch tool {
                case .getDiskOverview: result = await overview(scan, fda: context.fda)
                case .getLargestItems: result = try largest(ToolArguments.decode(GetLargestItemsArguments.self, from: arguments), scan)
                case .listChildren: result = try children(ToolArguments.decode(ListChildrenArguments.self, from: arguments), scan)
                case .getCategorySummary: result = categorySummary(scan)
                case .inspectPath: result = try inspect(ToolArguments.decode(InspectPathArguments.self, from: arguments), scan)
                case .searchItems: result = try search(ToolArguments.decode(SearchItemsArguments.self, from: arguments), scan)
                case .getCleanupQueue, .proposeDeletion: result = ToolOutput.error("Unknown tool: \(name)")
                }
            }
        } catch {
            return ToolOutput.error(error.message)
        }
        return ToolOutput.enforceSizeLimit(result)
    }

    // MARK: Read tools

    private func overview(_ scan: ToolScanContext, fda: FDAStatus) async -> ToolCallResult {
        let home = scan.engine.home
        let tree = scan.tree
        let scanned = tree.size(tree.root)
        // The session fills in the volume shortly after the scan; read it here if it is not there yet.
        let volume = scan.volume ?? VolumeLookup.containing(URL(fileURLWithPath: tree.path(tree.root)))
        let summary = scan.summary ?? volume.map { SpaceSummary.compute($0, scanned: scanned) }
        let age = max(0, Int(environment.now().timeIntervalSince(scan.finishedAt)))
        let snapshots = scan.isVolumeScan ? await environment.snapshots.count(volumePath: volume?.url.path ?? tree.path(tree.root)) : 0
        return ToolOutput.result(DiskOverviewResult(
            volume: volume?.name ?? tree.name(tree.root),
            capacity: summary?.capacity ?? 0,
            used: summary?.used ?? 0,
            free: summary?.free ?? 0,
            purgeable: summary?.purgeable ?? 0,
            otherVolumes: scan.isVolumeScan ? (summary?.otherVolumes ?? 0) : 0,
            hidden: scan.isVolumeScan ? (summary?.hidden ?? 0) : 0,
            scannedRoot: ToolPaths.abbreviate(tree.path(tree.root), home: home),
            scanAgeSeconds: age,
            fda: fda.rawValue,
            snapshotsCount: snapshots
        ))
    }

    private func largest(_ args: GetLargestItemsArguments, _ scan: ToolScanContext) throws(ToolArgumentError) -> ToolCallResult {
        let tree = scan.tree
        let root = try resolve(args.path, scan, default: tree.root)
        let limit = args.limit ?? 20
        let wanted = min(ToolQueries.offset(of: args.cursor) + limit + 1, 5_000)
        let nodes = ToolQueries.largest(
            in: tree, under: root, count: wanted, minBytes: args.minBytes ?? 0,
            kind: args.kind ?? .any, descendants: (args.scope ?? .descendants) == .descendants
        )
        return try page(nodes, cursor: args.cursor, limit: limit, scan)
    }

    private func children(_ args: ListChildrenArguments, _ scan: ToolScanContext) throws(ToolArgumentError) -> ToolCallResult {
        let node = try resolve(args.path, scan, default: scan.tree.root)
        let nodes = ToolQueries.children(in: scan.tree, of: node, sort: args.sort ?? .size)
        return try page(nodes, cursor: args.cursor, limit: args.limit ?? 50, scan)
    }

    private func search(_ args: SearchItemsArguments, _ scan: ToolScanContext) throws(ToolArgumentError) -> ToolCallResult {
        let tree = scan.tree
        let root = try resolve(args.under, scan, default: tree.root)
        let limit = args.limit ?? 30
        // The top list holds what this page can reach; with an age filter, the largest candidates whose dates are read.
        let wanted = min(ToolQueries.offset(of: args.cursor) + limit + 1, 5_000)
        let count = args.olderThanDays == nil ? wanted : max(wanted, SearchItemsArguments.maxDateCandidates)
        var nodes = ToolQueries.search(in: tree, under: root, nameGlob: args.nameGlob, extension: args.extension, minBytes: args.minBytes ?? 0, count: count)
        if let days = args.olderThanDays {
            // Dates are read lazily, for the largest candidates only.
            let cutoff = environment.now().addingTimeInterval(-Double(days) * 86_400)
            nodes = nodes.prefix(SearchItemsArguments.maxDateCandidates).filter { node in
                guard let modified = environment.metadata.modified(tree.path(node)) else { return false }
                return modified < cutoff
            }
        }
        return try page(nodes, cursor: args.cursor, limit: limit, scan)
    }

    private func categorySummary(_ scan: ToolScanContext) -> ToolCallResult {
        let entries = scan.categories
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.ruleID < $1.ruleID }
            .map { CategorySummaryEntry(ruleID: $0.ruleID, title: $0.title, risk: $0.risk.rawValue, bytes: $0.bytes, count: $0.count, action: $0.action.rawValue, commandHint: $0.commandHint) }
        var kept: [CategorySummaryEntry] = []
        var used = 64
        for entry in entries {
            let size = ToolOutput.encode(entry).utf8.count + 1
            if used + size > ToolCatalog.maxResultBytes { break }
            used += size
            kept.append(entry)
        }
        return ToolOutput.result(CategorySummaryResult(categories: kept))
    }

    private func inspect(_ args: InspectPathArguments, _ scan: ToolScanContext) throws(ToolArgumentError) -> ToolCallResult {
        let tree = scan.tree
        let home = scan.engine.home
        let node = try resolve(args.path, scan, default: tree.root)
        let path = tree.path(node)
        let flags = tree.flags(node)
        let classification = scan.engine.classify(path: path, resolveSymlinks: false)
        let bytes = tree.size(node)
        let frees = tree.reclaimableBytes(node, ifAlsoRemoving: [])
        let metadata = environment.metadata
        var explanation = classification.explanation ?? "No cleanup rule covers this item. Look at what it is before suggesting it."
        var protectionReason = classification.block?.message
        var risk = classification.risk
        if classification.block == nil, let nested = scan.engine.protectedDescendant(of: node, in: tree) {
            let shown = ToolPaths.abbreviate(nested.path, home: home)
            if let block = nested.classification.block {
                risk = .never
                protectionReason = "It contains \(shown), which is protected: \(block.message)"
            } else {
                risk = max(risk, .dangerous)
                explanation += " It contains \(shown), which only the user may decide about."
            }
        }
        if flags.contains(.notResponding) {
            explanation += " This folder did not answer during the scan, so its size is unknown (shown as 0)."
        } else if flags.contains(.restricted) {
            explanation += " This folder could not be read, so its size is unknown (shown as 0). Full Disk Access may help."
        }
        if risk == .dangerous, classification.block == nil {
            explanation += " Only the user can queue this, from the app, after confirming."
        }
        let isPackage = flags.contains(.package)
        return ToolOutput.result(PathInspectionResult(
            path: ToolPaths.abbreviate(path, home: home),
            bytes: bytes,
            freesBytes: frees,
            kind: ItemKind(flags: flags).rawValue,
            items: Int(tree.descendantCount(node)),
            modified: metadata.modified(path).map(Self.isoDate),
            lastUsed: metadata.lastUsed(path).map(Self.isoDate),
            bundleID: isPackage ? metadata.bundleID(path) : nil,
            ruleID: classification.ruleID,
            risk: risk.rawValue,
            explanation: explanation,
            protected: risk == .never,
            protectionReason: risk == .never ? (protectionReason ?? "This item is protected.") : nil,
            hardLinks: flags.contains(.hardLink) ? metadata.linkCount(path) : nil,
            cloneSharedBytes: flags.contains(.cloned) && bytes > frees ? bytes - frees : nil
        ))
    }

    private func cleanupQueue(_ context: ToolContext, home: String) -> ToolCallResult {
        let entries = context.queue.map { item in
            CleanupQueueEntry(path: ToolPaths.abbreviate(item.path, home: home), bytes: item.bytes, risk: item.risk.rawValue, source: Self.sourceName(item.source), selected: item.isSelected)
        }
        let total = context.queue.reduce(UInt64(0)) { $0 + $1.bytes }
        var kept: [CleanupQueueEntry] = []
        var used = 96
        for entry in entries {
            let size = ToolOutput.encode(entry).utf8.count + 1
            if used + size > ToolCatalog.maxResultBytes { break }
            used += size
            kept.append(entry)
        }
        return ToolOutput.result(CleanupQueueResult(items: kept, totalBytes: total))
    }

    // MARK: propose_deletion

    private func propose(_ args: ProposeDeletionArguments, context: ToolContext, thread: UUID) async -> ToolCallResult {
        guard let scan = context.scan else {
            return ToolOutput.error(context.isScanning ? Self.scanningText : Self.noScanText)
        }
        let tree = scan.tree
        let engine = scan.engine
        let home = engine.home
        var rejected: [(index: Int, entry: RejectedProposalEntry, block: BlockReason?)] = []
        var candidates: [(index: Int, proposal: ToolProposal)] = []

        for (index, item) in args.items.enumerated() {
            func reject(_ shown: String, _ code: String, _ message: String, _ block: BlockReason? = nil) {
                rejected.append((index, RejectedProposalEntry(path: shown, code: code, message: message), block))
            }
            guard let path = ToolPaths.expand(item.path, home: home) else {
                reject(item.path, "invalid_path", "Use an absolute path or one that starts with ~/.")
                continue
            }
            let shown = ToolPaths.abbreviate(path, home: home)
            guard let node = tree.node(atPath: path) else {
                reject(shown, "not_in_scan", Self.notInScanText, .notInScan)
                continue
            }
            let flags = tree.flags(node)
            if node == tree.root {
                reject(shown, "protected", BlockReason.scanRoot.message, .scanRoot)
                continue
            }
            if flags.contains(.missing) {
                reject(shown, "changed_since_scan", Self.changedText, .changedSinceScan)
                continue
            }
            let classification = engine.classify(path: path, resolveSymlinks: false)
            if let block = classification.block {
                reject(shown, "protected", block.message, block)
                continue
            }
            if classification.risk >= .dangerous {
                reject(shown, "needs_user_choice", "This item can hold data that cannot be replaced. Only the user can queue it, from the app.")
                continue
            }
            if let nested = engine.protectedDescendant(of: node, in: tree) {
                let nestedShown = ToolPaths.abbreviate(nested.path, home: home)
                if let block = nested.classification.block {
                    reject(shown, "contains_protected", "It contains \(nestedShown), which is protected: \(block.message)", block)
                } else {
                    reject(shown, "needs_user_choice", "It contains \(nestedShown), which only the user may decide about.")
                }
                continue
            }
            if let ruleID = classification.ruleID, let rule = engine.rule(withID: ruleID), rule.action == .guide {
                let hint = rule.commandHint.map { " Suggest this command instead: \($0)" } ?? ""
                reject(shown, "use_command", "This is managed by its own tool, so it is not removed file by file.\(hint)")
                continue
            }
            candidates.append((index, ToolProposal(node: node, tree: tree, path: path, risk: classification.risk, ruleID: classification.ruleID, reason: item.reason)))
        }

        let proposals = candidates.map(\.proposal)
        let results = proposals.isEmpty ? [] : await environment.enqueue(thread, proposals)
        var queued: [(index: Int, entry: QueuedProposal, item: ProposedItem)] = []
        for (offset, candidate) in candidates.enumerated() {
            let proposal = candidate.proposal
            let shown = ToolPaths.abbreviate(proposal.path, home: home)
            let result = offset < results.count ? results[offset] : .blocked(.notInScan)
            switch result {
            case .added, .alreadyQueued:
                let bytes = tree.size(proposal.node)
                queued.append((candidate.index, QueuedProposal(path: shown, bytes: bytes, risk: proposal.risk.rawValue),
                               ProposedItem(path: shown, bytes: bytes, risk: proposal.risk, reason: proposal.reason)))
            case .coveredByParent(let parent):
                rejected.append((candidate.index, RejectedProposalEntry(path: shown, code: "already_covered", message: "\(ToolPaths.abbreviate(parent, home: home)) is already in the queue and contains it."), nil))
            case .blocked(let block):
                rejected.append((candidate.index, RejectedProposalEntry(path: shown, code: "protected", message: block.message), block))
            case .needsUserChoice:
                rejected.append((candidate.index, RejectedProposalEntry(path: shown, code: "needs_user_choice", message: "Only the user can queue this, from the app."), nil))
            case .containsUserItems(let paths):
                let listed = paths.prefix(5).map { ToolPaths.abbreviate($0, home: home) }.joined(separator: ", ")
                let more = paths.count > 5 ? " and \(paths.count - 5) more" : ""
                rejected.append((candidate.index, RejectedProposalEntry(
                    path: shown, code: "contains_user_items",
                    message: "Not queued: the user already queued items inside it (\(listed)\(more)). Their choices stay as they are. Propose other items inside this folder one by one instead."
                ), nil))
            }
        }
        queued.sort { $0.index < $1.index }
        rejected.sort { $0.index < $1.index }

        let batch = ProposalBatch(
            summary: args.summary,
            queued: queued.map(\.item),
            rejected: rejected.map {
                RejectedProposal(path: $0.entry.path, block: $0.block, message: $0.entry.message, code: $0.entry.code, fullPath: ToolPaths.expand($0.entry.path, home: home))
            }
        )
        await environment.proposalMade(thread, batch)
        return ToolOutput.result(ProposeDeletionResult(queued: queued.map(\.entry), rejected: rejected.map(\.entry)))
    }

    // MARK: Helpers

    /// Node for a tool path argument (absolute or `~/...`), or `fallback` when the argument is absent.
    private func resolve(_ raw: String?, _ scan: ToolScanContext, default fallback: NodeID) throws(ToolArgumentError) -> NodeID {
        guard let raw, !raw.isEmpty else { return fallback }
        guard let path = ToolPaths.expand(raw, home: scan.engine.home) else {
            throw ToolArgumentError("Use an absolute path or one that starts with ~/.")
        }
        guard let node = scan.tree.node(atPath: path) else {
            throw ToolArgumentError("\(Self.notInScanText) The scanned folder is \(ToolPaths.abbreviate(scan.tree.path(scan.tree.root), home: scan.engine.home)).")
        }
        return node
    }

    /// One page of `nodes` as tool items: at most `limit` items and the 24 KB budget, with an
    /// opaque cursor (tree generation plus offset). Only the items on the page are described.
    private func page(_ nodes: [NodeID], cursor: String?, limit: Int, _ scan: ToolScanContext) throws(ToolArgumentError) -> ToolCallResult {
        let generation = scan.tree.generation
        var offset = 0
        if let cursor, !cursor.isEmpty {
            guard let parsed = ToolCursor(token: cursor) else { throw ToolArgumentError("cursor is not valid, repeat the call without it") }
            guard parsed.generation == generation else { throw ToolArgumentError("cursor belongs to an older scan, repeat the call without it") }
            offset = min(max(parsed.offset, 0), nodes.count)
        }
        let window = nodes[offset..<min(nodes.count, offset + max(limit, 1))].map { item($0, scan) }
        let kept = try ToolOutput.page(window, cursor: nil, limit: limit, generation: generation).items
        let nextOffset = offset + kept.count
        let next = nextOffset < nodes.count ? ToolCursor(offset: nextOffset, generation: generation).token : nil
        return ToolOutput.result(ToolItemList(items: kept, nextCursor: next))
    }

    private func item(_ node: NodeID, _ scan: ToolScanContext) -> ToolItem {
        let tree = scan.tree
        let path = tree.path(node)
        let classification = scan.engine.classify(path: path, resolveSymlinks: false)
        return ToolItem(
            path: ToolPaths.abbreviate(path, home: scan.engine.home),
            bytes: tree.size(node),
            freesBytes: tree.reclaimableBytes(node, ifAlsoRemoving: []),
            kind: ItemKind(flags: tree.flags(node)).rawValue,
            items: Int(tree.descendantCount(node)),
            ruleID: classification.ruleID,
            risk: classification.risk.rawValue
        )
    }

    static func sourceName(_ source: QueueSource) -> String {
        switch source {
        case .user: "user"
        case .category(let id): "category:\(id)"
        case .assistant: "assistant"
        }
    }

    static func isoDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
