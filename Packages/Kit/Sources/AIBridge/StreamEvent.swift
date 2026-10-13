import Foundation
import IPCProtocol

/// `system/init` payload.
public struct InitInfo: Sendable, Hashable {
    public var sessionID: String
    public var model: String
    public var mcpServers: [MCPServerStatus]
    public var capabilities: [String]
    public var version: String
    /// "none" for an OAuth (subscription or Console) login; anything else means an API key is in use.
    public var apiKeySource: String?
    public var permissionMode: String?
    /// Tool names the CLI exposes to the model (with `--tools ""` only `mcp__disk__*`).
    public var tools: [String]

    public init(sessionID: String, model: String, mcpServers: [MCPServerStatus], capabilities: [String], version: String, apiKeySource: String? = nil, permissionMode: String? = nil, tools: [String] = []) {
        self.sessionID = sessionID
        self.model = model
        self.mcpServers = mcpServers
        self.capabilities = capabilities
        self.version = version
        self.apiKeySource = apiKeySource
        self.permissionMode = permissionMode
        self.tools = tools
    }

    /// Capability required for the Stop button (PLAN 3.2 item 6).
    public static let interruptCapability = "interrupt_receipt_v1"

    /// Status of the `disk` MCP server, nil when the CLI did not list it.
    public var diskServerStatus: String? {
        mcpServers.first { $0.name == ToolCatalog.serverName }?.status
    }

    public var isDiskServerConnected: Bool { diskServerStatus == "connected" }
    public var supportsInterrupt: Bool { capabilities.contains(Self.interruptCapability) }
}

public struct MCPServerStatus: Sendable, Hashable, Codable {
    public var name: String
    /// e.g. "connected", "failed", "pending".
    public var status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

/// Token usage reported by the CLI.
public struct TokenUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    /// Every input token, cached or not, plus output tokens (what the per-thread guard counts).
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }
}

/// Final `result` line of a turn.
public struct TurnResult: Sendable, Hashable {
    /// "success", "error_max_turns", "error_during_execution", ...
    public var subtype: String
    public var isError: Bool
    public var text: String?
    public var numTurns: Int
    public var durationMs: Int
    public var usage: TokenUsage?
    /// Cost as reported by the CLI (`total_cost_usd`), kept as the raw number for display only.
    public var totalCostUSD: Double?
    public var permissionDenials: [String]
    public var terminalReason: String?
    public var apiErrorStatus: Int?

    public init(subtype: String, isError: Bool, text: String? = nil, numTurns: Int = 0, durationMs: Int = 0, usage: TokenUsage? = nil, totalCostUSD: Double? = nil, permissionDenials: [String] = [], terminalReason: String? = nil, apiErrorStatus: Int? = nil) {
        self.subtype = subtype
        self.isError = isError
        self.text = text
        self.numTurns = numTurns
        self.durationMs = durationMs
        self.usage = usage
        self.totalCostUSD = totalCostUSD
        self.permissionDenials = permissionDenials
        self.terminalReason = terminalReason
        self.apiErrorStatus = apiErrorStatus
    }

    /// Estimated cost in millionths of a US dollar (integer, so it can be summed without drift).
    public var estimatedCostMicros: Int {
        guard let totalCostUSD, totalCostUSD.isFinite, totalCostUSD > 0 else { return 0 }
        return Int((totalCostUSD * 1_000_000).rounded())
    }
}

/// Content block of a complete assistant message.
public enum AssistantBlock: Sendable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case thinking
}

/// Parsed stream-json event (PLAN 3.5). Unknown types map to `.unknown`.
public enum StreamEvent: Sendable, Hashable {
    case initialized(InitInfo)
    case status(String)
    case messageStart(id: String)
    case textDelta(String)
    /// Thinking content is never shown; only its length is reported.
    case thinkingDelta(characters: Int)
    case toolUseStart(id: String, name: String)
    case toolInputDelta(id: String, partialJSON: String)
    case blockStop
    case messageDelta(stopReason: String?)
    case assistantMessage([AssistantBlock])
    case toolResult(toolUseID: String, text: String, isError: Bool)
    case thinkingTokens(Int)
    case apiRetry(attempt: Int, max: Int, delayMs: Int, errorStatus: Int?, error: String?)
    case controlResponse(requestID: String, subtype: String)
    case result(TurnResult)
    case unknown(type: String, subtype: String?)
    /// The CLI process ended (added: emitted by `ClaudeSession` as its last event, never by the parser).
    /// Status 0 after a clean stdin close; anything else is a crash, offer Retry with `--resume`.
    case processExited(status: Int32)
    /// The session refused to run (added: emitted by `ClaudeSession` right after the `.initialized`
    /// that triggered it, never by the parser). The process is stopped; show the reason to the user.
    case refused(SessionRefusal)
}

/// Incremental newline-delimited JSON parser for `--output-format stream-json`. Frozen contract (PLAN 4.3).
///
/// Mapping (PLAN 3.5):
/// - `system/init` -> `.initialized`, `system/status` -> `.status`, `system/thinking_tokens` -> `.thinkingTokens`,
///   `system/api_retry` -> `.apiRetry`, any other `system` subtype (hooks, ...) -> `.unknown`.
/// - `stream_event`: `message_start` -> `.messageStart`, `content_block_start` of a tool use -> `.toolUseStart`,
///   `text_delta` -> `.textDelta`, `input_json_delta` -> `.toolInputDelta`, `thinking_delta` -> `.thinkingDelta`,
///   `content_block_stop` -> `.blockStop`, `message_delta` -> `.messageDelta`. Text and thinking block starts,
///   `signature_delta` and `message_stop` produce nothing. Other stream events -> `.unknown("stream_event", type)`.
/// - `assistant` -> `.assistantMessage`; `user` -> one `.toolResult` per `tool_result` block (plain user text,
///   such as the interrupt marker, produces nothing); `control_response` -> `.controlResponse`; `result` -> `.result`.
/// - Any other `type` -> `.unknown`. Lines that are not JSON objects with a string `type` are counted in
///   `malformedLines` and skipped. Unknown fields are ignored.
///
/// Bytes may be fed in arbitrary chunks (split anywhere, including inside UTF-8 sequences).
public struct StreamJSONParser: Sendable {
    private var buffer = Data()
    /// Tool use ids by content block index, for `input_json_delta` (which carries only the index).
    private var toolBlocks: [Int: String] = [:]

    /// Complete lines seen so far (blank lines excluded).
    public private(set) var linesRead = 0
    /// Lines that could not be parsed and were skipped.
    public private(set) var malformedLines = 0

    public init() {}

    public mutating func feed(_ bytes: Data) -> [StreamEvent] {
        // Only the new bytes can hold a newline: the buffer before them has none.
        guard bytes.contains(0x0A) else {
            buffer.append(bytes)
            return []
        }
        buffer.append(bytes)
        var events: [StreamEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty, !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { continue }
            linesRead += 1
            parse(line: line, into: &events)
        }
        return events
    }

    /// Parses whatever is left in the buffer as a final line (call at end of stream).
    public mutating func finish() -> [StreamEvent] {
        guard !buffer.isEmpty else { return [] }
        return feed(Data([0x0A]))
    }

    private mutating func parse(line: Data, into events: inout [StreamEvent]) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              case .object(let object) = value,
              case .string(let type)? = object["type"]
        else {
            malformedLines += 1
            return
        }
        let subtype = object["subtype"]?.stringValue
        switch type {
        case "system":
            parseSystem(object, subtype: subtype, into: &events)
        case "stream_event":
            parseStreamEvent(object["event"] ?? .null, into: &events)
        case "assistant":
            events.append(.assistantMessage(Self.blocks(object["message"]?["content"])))
        case "user":
            for block in object["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                events.append(.toolResult(
                    toolUseID: block["tool_use_id"]?.stringValue ?? "",
                    text: Self.text(of: block["content"]),
                    isError: block["is_error"]?.boolValue ?? false
                ))
            }
        case "control_response":
            let response = object["response"] ?? .null
            events.append(.controlResponse(
                requestID: response["request_id"]?.stringValue ?? "",
                subtype: response["subtype"]?.stringValue ?? ""
            ))
        case "result":
            events.append(.result(Self.turnResult(value)))
        default:
            events.append(.unknown(type: type, subtype: subtype))
        }
    }

    private mutating func parseSystem(_ object: [String: JSONValue], subtype: String?, into events: inout [StreamEvent]) {
        let value = JSONValue.object(object)
        switch subtype {
        case "init":
            let servers = (value["mcp_servers"]?.arrayValue ?? []).compactMap { server -> MCPServerStatus? in
                guard let name = server["name"]?.stringValue else { return nil }
                return MCPServerStatus(name: name, status: server["status"]?.stringValue ?? "unknown")
            }
            events.append(.initialized(InitInfo(
                sessionID: value["session_id"]?.stringValue ?? "",
                model: value["model"]?.stringValue ?? "",
                mcpServers: servers,
                capabilities: (value["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue),
                version: value["claude_code_version"]?.stringValue ?? "",
                apiKeySource: value["apiKeySource"]?.stringValue,
                permissionMode: value["permissionMode"]?.stringValue,
                tools: (value["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            )))
        case "status":
            events.append(.status(value["status"]?.stringValue ?? ""))
        case "thinking_tokens":
            events.append(.thinkingTokens(Self.int(value["estimated_tokens"]) ?? 0))
        case "api_retry":
            events.append(.apiRetry(
                attempt: Self.int(value["attempt"]) ?? 0,
                max: Self.int(value["max_retries"]) ?? 0,
                delayMs: Self.int(value["retry_delay_ms"]) ?? 0,
                errorStatus: Self.int(value["error_status"]),
                error: value["error"]?.stringValue
            ))
        default:
            events.append(.unknown(type: "system", subtype: subtype))
        }
    }

    private mutating func parseStreamEvent(_ event: JSONValue, into events: inout [StreamEvent]) {
        let eventType = event["type"]?.stringValue ?? ""
        switch eventType {
        case "message_start":
            toolBlocks.removeAll()
            events.append(.messageStart(id: event["message"]?["id"]?.stringValue ?? ""))
        case "content_block_start":
            let block = event["content_block"] ?? .null
            if block["type"]?.stringValue == "tool_use" {
                let id = block["id"]?.stringValue ?? ""
                if let index = Self.int(event["index"]) { toolBlocks[index] = id }
                events.append(.toolUseStart(id: id, name: block["name"]?.stringValue ?? ""))
            }
        case "content_block_delta":
            let delta = event["delta"] ?? .null
            switch delta["type"]?.stringValue {
            case "text_delta":
                events.append(.textDelta(delta["text"]?.stringValue ?? ""))
            case "input_json_delta":
                let id = Self.int(event["index"]).flatMap { toolBlocks[$0] } ?? ""
                events.append(.toolInputDelta(id: id, partialJSON: delta["partial_json"]?.stringValue ?? ""))
            case "thinking_delta":
                events.append(.thinkingDelta(characters: delta["thinking"]?.stringValue?.count ?? 0))
            default:
                // signature_delta and future delta kinds carry nothing to show.
                break
            }
        case "content_block_stop":
            events.append(.blockStop)
        case "message_delta":
            events.append(.messageDelta(stopReason: event["delta"]?["stop_reason"]?.stringValue))
        case "message_stop":
            break
        default:
            events.append(.unknown(type: "stream_event", subtype: eventType.isEmpty ? nil : eventType))
        }
    }

    private static func blocks(_ content: JSONValue?) -> [AssistantBlock] {
        (content?.arrayValue ?? []).compactMap { block in
            switch block["type"]?.stringValue {
            case "text": .text(block["text"]?.stringValue ?? "")
            case "tool_use": .toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "", input: block["input"] ?? .object([:]))
            case "thinking", "redacted_thinking": .thinking
            default: nil
            }
        }
    }

    /// Text of a tool result `content`: a plain string or an array of text blocks.
    private static func text(of content: JSONValue?) -> String {
        switch content {
        case .string(let text)?: text
        case .array(let blocks)?: blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
        default: ""
        }
    }

    private static func turnResult(_ value: JSONValue) -> TurnResult {
        let usage = value["usage"].flatMap { usage -> TokenUsage? in
            guard case .object = usage else { return nil }
            return TokenUsage(
                inputTokens: int(usage["input_tokens"]) ?? 0,
                outputTokens: int(usage["output_tokens"]) ?? 0,
                cacheReadInputTokens: int(usage["cache_read_input_tokens"]) ?? 0,
                cacheCreationInputTokens: int(usage["cache_creation_input_tokens"]) ?? 0
            )
        }
        let denials = (value["permission_denials"]?.arrayValue ?? []).compactMap { denial in
            denial.stringValue ?? denial["tool_name"]?.stringValue
        }
        return TurnResult(
            subtype: value["subtype"]?.stringValue ?? "",
            isError: value["is_error"]?.boolValue ?? false,
            text: value["result"]?.stringValue,
            numTurns: int(value["num_turns"]) ?? 0,
            durationMs: int(value["duration_ms"]) ?? 0,
            usage: usage,
            totalCostUSD: double(value["total_cost_usd"]),
            permissionDenials: denials,
            terminalReason: value["terminal_reason"]?.stringValue,
            apiErrorStatus: int(value["api_error_status"])
        )
    }

    private static func int(_ value: JSONValue?) -> Int? {
        value?.intValue.map { Int(clamping: $0) }
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let v)?: v
        case .int(let v)?: Double(v)
        default: nil
        }
    }
}
