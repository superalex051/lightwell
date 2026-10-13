import Darwin
import Foundation
import IPCProtocol
import Synchronization
import Testing
@testable import MCPServerKit

/// Backend that records calls and answers with a fixed result.
final class RecordingBackend: ToolBackend {
    let calls = Mutex<[(String, JSONValue)]>([])
    func callTool(name: String, arguments: JSONValue) -> ToolCallResult {
        calls.withLock { $0.append((name, arguments)) }
        return ToolCallResult(text: #"{"items":[]}"#, isError: false)
    }
}

@Suite("MCP JSON-RPC server")
struct MCPServerTests {
    /// Golden transcript: request line -> exact response line (nil = no response).
    static let golden: [(String, String?)] = [
        (#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.296"}}}"#,
         #"{"id":0,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"protocolVersion":"2025-11-25","serverInfo":{"name":"disk","title":"Lightwell disk tools","version":"1.0"}}}"#),
        (#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, nil),
        (#"{"jsonrpc":"2.0","id":"a-1","method":"ping"}"#,
         #"{"id":"a-1","jsonrpc":"2.0","result":{}}"#),
        (#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_largest_items","arguments":{"limit":2}}}"#,
         #"{"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"{\"items\":[]}","type":"text"}],"isError":false}}"#),
        (#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_disk_overview"}}"#,
         #"{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"{\"items\":[]}","type":"text"}],"isError":false}}"#),
        (#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#,
         #"{"error":{"code":-32602,"message":"Unknown tool: rm_rf"},"id":4,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"arguments":{}}}"#,
         #"{"error":{"code":-32602,"message":"Invalid params: name is required"},"id":5,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"inspect_path","arguments":"/etc"}}"#,
         #"{"error":{"code":-32602,"message":"Invalid params: arguments must be an object"},"id":6,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#,
         #"{"error":{"code":-32601,"message":"Method not found: resources/list"},"id":7,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{"#,
         #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#),
        (#"[{"jsonrpc":"2.0","id":9,"method":"ping"}]"#,
         #"{"error":{"code":-32600,"message":"Invalid Request"},"id":null,"jsonrpc":"2.0"}"#),
        (#"{"id":10,"method":"ping"}"#,
         #"{"error":{"code":-32600,"message":"Invalid Request"},"id":10,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":11}"#,
         #"{"error":{"code":-32600,"message":"Invalid Request"},"id":11,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#,
         #"{"error":{"code":-32600,"message":"Invalid Request"},"id":null,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":12,"result":{}}"#, nil),
        (#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#, nil),
        ("   ", nil),
    ]

    @Test func goldenTranscript() {
        let backend = RecordingBackend()
        let server = MCPServer(backend: backend)
        for (request, expected) in Self.golden {
            #expect(server.handle(line: request) == expected, "request: \(request)")
        }
        let calls = backend.calls.withLock { $0 }
        #expect(calls.map(\.0) == ["get_largest_items", "get_disk_overview"])
        #expect(calls[0].1 == ["limit": 2])
        #expect(calls[1].1 == .object([:]))
    }

    @Test func initializeWithoutVersionUsesFallback() throws {
        let server = MCPServer(backend: UnavailableToolBackend())
        let response = try #require(server.handle(message: ["jsonrpc": "2.0", "id": 1, "method": "initialize"]))
        #expect(response["result"]?["protocolVersion"] == .string(MCPServer.fallbackProtocolVersion))
    }

    @Test func toolsListEqualsCatalog() throws {
        let server = MCPServer(backend: UnavailableToolBackend())
        let line = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        let tools = try #require(response["result"]?["tools"]?.arrayValue)
        #expect(tools == ToolCatalog.all.map(\.mcpListEntry))
        #expect(tools.count == 8)
    }

    @Test func appAbsentReturnsGuidance() throws {
        let server = MCPServer(backend: UnavailableToolBackend())
        let response = try #require(server.handle(message: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_disk_overview"]]))
        #expect(response["result"]?["isError"] == true)
        #expect(response["result"]?["content"]?.arrayValue?.first?["text"] == "Open Lightwell and scan a disk first.")
    }

    @Test func oversizedResultBecomesError() throws {
        struct HugeBackend: ToolBackend {
            func callTool(name: String, arguments: JSONValue) -> ToolCallResult {
                ToolCallResult(text: String(repeating: "x", count: 30_000), isError: false)
            }
        }
        let server = MCPServer(backend: HugeBackend())
        let response = try #require(server.handle(message: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_cleanup_queue"]]))
        #expect(response["result"]?["isError"] == true)
        let text = try #require(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text == ToolOutput.tooLargeMessage(size: 30_000))
    }

    @Test func optionsParsing() {
        let env = [IPC.nonceEnvironmentKey: "n0nce", IPC.socketEnvironmentKey: "/env.sock"]
        let a = MCPHelperMain.Options.parse(arguments: ["helper", "--socket", "/tmp/s.sock"], environment: env)
        #expect(a.socketPath == "/tmp/s.sock")
        #expect(a.nonce == "n0nce")
        let b = MCPHelperMain.Options.parse(arguments: ["helper", "--socket=/x.sock"], environment: [:])
        #expect(b.socketPath == "/x.sock")
        #expect(b.nonce == nil)
        #expect(b.makeBackend() is UnavailableToolBackend)
        let c = MCPHelperMain.Options.parse(arguments: ["helper"], environment: env)
        #expect(c.socketPath == "/env.sock")
        #expect(c.makeBackend() is SocketToolBackend)
        #expect(MCPHelperMain.Options.parse(arguments: ["helper", "--version"], environment: [:]).printVersion)
    }
}
