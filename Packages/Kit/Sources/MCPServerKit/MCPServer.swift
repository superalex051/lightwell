import Foundation
import IPCProtocol

/// Where `tools/call` requests go. The helper uses `SocketToolBackend`; tests inject their own.
public protocol ToolBackend: Sendable {
    func callTool(name: String, arguments: JSONValue) -> ToolCallResult
}

/// Backend used when the helper has no way to reach the app: every call returns guidance text.
public struct UnavailableToolBackend: ToolBackend {
    public init() {}

    public func callTool(name: String, arguments: JSONValue) -> ToolCallResult {
        ToolCallResult(text: ToolCatalog.appUnavailableText, isError: true)
    }
}

/// JSON-RPC 2.0 error codes used by the helper.
public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
}

/// Stdio MCP server logic: one JSON-RPC message in, at most one response out (PLAN 3.6, 3.7).
///
/// Pure and synchronous so it can be driven line by line from stdin or from tests.
public final class MCPServer: Sendable {
    /// Protocol version answered when the client does not send one.
    public static let fallbackProtocolVersion = "2025-06-18"

    private let backend: any ToolBackend
    private let tools: [ToolDefinition]

    public init(backend: any ToolBackend, tools: [ToolDefinition] = ToolCatalog.all) {
        self.backend = backend
        self.tools = tools
    }

    /// Handles one line of input. Returns the response line (without trailing newline), or nil for
    /// notifications, responses and blank lines.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.encode(errorResponse(id: .null, code: JSONRPCErrorCode.parseError, message: "Parse error"))
        }
        return handle(message: message).map(Self.encode)
    }

    /// Handles one decoded message. Returns nil when no response is due.
    public func handle(message: JSONValue) -> JSONValue? {
        guard case .object(let object) = message else {
            return errorResponse(id: .null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request")
        }
        let id = object["id"]
        if let id, !Self.isValidID(id) {
            return errorResponse(id: .null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request")
        }
        guard case .string(let method)? = object["method"] else {
            // A response to a request we never sent: nothing to answer.
            if object["result"] != nil || object["error"] != nil { return nil }
            return errorResponse(id: id ?? .null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request")
        }
        guard object["jsonrpc"] == .string("2.0") else {
            return errorResponse(id: id ?? .null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request")
        }
        let params = object["params"] ?? .null
        guard let id else {
            // Notifications (notifications/initialized, notifications/cancelled, ...) need no answer.
            return nil
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.fallbackProtocolVersion
            return resultResponse(id: id, result: [
                "protocolVersion": .string(requested),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": .string(ToolCatalog.serverName),
                    "title": "Lightwell disk tools",
                    "version": .string(MCPHelperMain.version),
                ],
            ])
        case "ping":
            return resultResponse(id: id, result: .object([:]))
        case "tools/list":
            return resultResponse(id: id, result: ["tools": .array(tools.map(\.mcpListEntry))])
        case "tools/call":
            guard case .object = params, case .string(let name)? = params["name"] else {
                return errorResponse(id: id, code: JSONRPCErrorCode.invalidParams, message: "Invalid params: name is required")
            }
            guard tools.contains(where: { $0.name == name }) else {
                return errorResponse(id: id, code: JSONRPCErrorCode.invalidParams, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] ?? .null
            switch arguments {
            case .object, .null: break
            default:
                return errorResponse(id: id, code: JSONRPCErrorCode.invalidParams, message: "Invalid params: arguments must be an object")
            }
            // Size cap backstop (PLAN 3.7): nothing over 24 KiB reaches the model.
            let result = ToolOutput.enforceSizeLimit(backend.callTool(name: name, arguments: arguments == .null ? .object([:]) : arguments))
            return resultResponse(id: id, result: [
                "content": [["type": "text", "text": .string(result.text)]],
                "isError": .bool(result.isError),
            ])
        default:
            return errorResponse(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int, .null: true
        case .double(let value): value.rounded() == value
        default: false
        }
    }

    private func resultResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(Int64(code)), "message": .string(message)]]
    }

    /// Single-line JSON with sorted keys (deterministic for golden tests).
    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
