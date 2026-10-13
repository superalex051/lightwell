import AIBridge
import Foundation
import Observation
import RulesKit

/// Whether the assistant can be used right now.
public enum AssistantAvailability: Sendable, Hashable {
    case checking
    /// CLI found but the user has not accepted the privacy consent yet.
    case needsConsent
    case ready(version: String?)
    case notInstalled
    case notSignedIn
    case disabled
    case failed(String)
}

/// One tool call shown as an activity chip.
public struct ToolActivity: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        case running
        case succeeded
        case failed
    }

    public var id: String
    /// MCP tool name without the server prefix, e.g. "get_largest_items".
    public var name: String
    /// Short machine summary of the arguments (paths, limits), shown in the Advanced view.
    public var detail: String
    public var state: State
    public var durationMs: Int?

    public init(id: String, name: String, detail: String = "", state: State, durationMs: Int? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.durationMs = durationMs
    }
}

public struct ProposedItem: Sendable, Hashable, Identifiable {
    public var path: String
    public var bytes: UInt64
    public var risk: Risk
    public var reason: String
    public var id: String { path }

    public init(path: String, bytes: UInt64, risk: Risk, reason: String) {
        self.path = path
        self.bytes = bytes
        self.risk = risk
        self.reason = reason
    }
}

public struct RejectedProposal: Sendable, Hashable, Identifiable {
    public var path: String
    public var block: BlockReason?
    public var message: String
    /// Tool rejection code (`needs_user_choice`, `protected`, ...), when known.
    public var code: String?
    /// Absolute path, for "Queue It Myself" on items only the user may queue.
    public var fullPath: String?
    public var id: String { path }

    public init(path: String, block: BlockReason?, message: String, code: String? = nil, fullPath: String? = nil) {
        self.path = path
        self.block = block
        self.message = message
        self.code = code
        self.fullPath = fullPath
    }

    /// The assistant may not queue this, but the user can (it lands unticked and needs the
    /// per-item acknowledgement).
    public var userMayQueue: Bool { code == ToolHandler.needsUserChoiceCode && fullPath != nil }
}

/// Result of one `propose_deletion` call, rendered as a proposal card.
public struct ProposalBatch: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var summary: String
    public var queued: [ProposedItem]
    public var rejected: [RejectedProposal]

    public init(id: UUID = UUID(), summary: String, queued: [ProposedItem], rejected: [RejectedProposal]) {
        self.id = id
        self.summary = summary
        self.queued = queued
        self.rejected = rejected
    }

    public var totalBytes: UInt64 { queued.reduce(0) { $0 + $1.bytes } }
}

/// One row in the assistant transcript.
public struct ChatItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case user(String)
        case assistant(text: String, isStreaming: Bool)
        case tool(ToolActivity)
        case proposal(ProposalBatch)
        case notice(String)
        case error(String)
    }

    public var id: UUID
    public var kind: Kind
    public var date: Date

    public init(id: UUID = UUID(), kind: Kind, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.date = date
    }
}

/// Token and cost totals for the active thread. Money in integer cents.
public struct UsageSummary: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var costCents: Int
    public var turns: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, costCents: Int = 0, turns: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costCents = costCents
        self.turns = turns
    }
}
