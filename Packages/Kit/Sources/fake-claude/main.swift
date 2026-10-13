// Deterministic stand-in for the claude CLI used by tests (PLAN 4.2 WS10a).
//
// Accepts the argv of ClaudeCommandBuilder, reads `--mcp-config`, spawns the `disk` server from it,
// runs the MCP handshake and emits stream-json modelled on Tests/Fixtures/cli-samples. Honours interrupt
// control requests. Refuses `--bare`, `--safe-mode` and `--dangerously-skip-permissions` (exit 2).
//
// Behaviour per user message, in order:
// 1. `<cwd>/fake-claude-script.json`, if present:
//    {"apiKeySource":"...","lateInit":true,"authStatus":{...},"turns":[{"steps":[STEP...]}...]};
//    turn i of the script answers message i (the last turn repeats). All keys are optional:
//    - `apiKeySource` (default "none") is what system/init reports;
//    - `lateInit` (default false): like the real CLI 2.1.296, system/init is emitted only when the
//      first user message arrives, followed by about 300 ms of simulated request latency during
//      which an interrupt aborts the turn;
//    - `authStatus`: what `fake-claude auth status --json` prints (an object, or a string printed
//      verbatim); default {"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}.
//      With `authStatus` set, `authStatusDelayMs` delays that answer (a slow pre-check).
//    STEP is one of
//    {"tool":"<short name>","arguments":{...}}, {"text":"..."}, {"slow_text":"...","delay_ms":20}.
// 2. Otherwise the built-in script:
//    - absolute or ~/ paths in the message: one propose_deletion call with those paths, then a text reply;
//    - "[slow]" in the message: a long slowly streamed reply (for interrupt tests);
//    - anything else: get_disk_overview, then a text reply.
import Darwin
import Foundation
import IPCProtocol

signal(SIGPIPE, SIG_IGN)

// `auth status --json` stub (the session's API key pre-check).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "auth", CommandLine.arguments[2] == "status" {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fake-claude-script.json")
    var output = #"{"apiProvider":"firstParty","authMethod":"oauth_token","loggedIn":true}"#
    if let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(JSONValue.self, from: data), let custom = document["authStatus"] {
        if let delay = document["authStatusDelayMs"]?.intValue { usleep(useconds_t(delay * 1000)) }
        if case .string(let raw) = custom {
            output = raw
        } else if let encoded = try? JSONEncoder().encode(custom) {
            output = String(decoding: encoded, as: UTF8.self)
        }
    }
    FileHandle.standardOutput.write(Data((output + "\n").utf8))
    exit(0)
}

// MARK: - Output

nonisolated func emit(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return }
    FileHandle.standardOutput.write(data + Data([0x0A]))
}

nonisolated func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data("fake-claude: \(text)\n".utf8))
}

// MARK: - Arguments

struct Arguments {
    var mcpConfig: String?
    var sessionID: String?
    var model = "claude-fake-1"
    var allowedTools: [String] = []
}

@MainActor func parseArguments(_ argv: [String]) -> Arguments {
    var result = Arguments()
    var index = 1
    while index < argv.count {
        let argument = argv[index]
        let next = index + 1 < argv.count ? argv[index + 1] : nil
        switch argument {
        case "--bare", "--safe-mode", "--dangerously-skip-permissions":
            diagnostic("refusing forbidden flag \(argument)")
            exit(2)
        case "--version":
            FileHandle.standardOutput.write(Data("0.0.0-fake (Claude Code)\n".utf8))
            exit(0)
        case "--mcp-config":
            result.mcpConfig = next
            index += 1
        case "--session-id", "--resume":
            result.sessionID = next
            index += 1
        case "--model":
            if let next { result.model = next }
            index += 1
        case "--allowedTools":
            result.allowedTools = (next ?? "").split(separator: " ").map(String.init)
            index += 1
        case "--input-format", "--output-format", "--max-turns", "--max-budget-usd", "--setting-sources",
             "--tools", "--permission-mode", "--system-prompt-file":
            index += 1
        default:
            break
        }
        index += 1
    }
    return result
}

let arguments = parseArguments(CommandLine.arguments)
let sessionID = arguments.sessionID ?? UUID().uuidString.lowercased()
let cwd = FileManager.default.currentDirectoryPath

// MARK: - MCP client

final class MCPClient {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var buffer = Data()
    var nextID = 1
    var toolNames: [String] = []

    init?(configPath: String) {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(JSONValue.self, from: data),
              let server = config["mcpServers"]?[ToolCatalog.serverName],
              let command = server["command"]?.stringValue
        else {
            diagnostic("no disk server in the MCP config")
            return nil
        }
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = (server["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in server["env"]?.objectValue ?? [:] {
            if let value = value.stringValue { environment[key] = value }
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            diagnostic("could not start the disk server")
            return nil
        }
        guard let initialize = request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "fake-claude", "version": "0.0.0"],
        ]), initialize["result"] != nil else { return nil }
        notify("notifications/initialized")
        guard let list = request("tools/list", params: [:]) else { return nil }
        toolNames = (list["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": .string(method)])
    }

    func request(_ method: String, params: JSONValue) -> JSONValue? {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params])
        while let line = readLine() {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
            if message["id"]?.intValue == Int64(id) { return message }
        }
        return nil
    }

    func callTool(_ name: String, arguments: JSONValue) -> (text: String, isError: Bool) {
        guard let response = request("tools/call", params: ["name": .string(name), "arguments": arguments]) else {
            return ("MCP server disconnected", true)
        }
        if let error = response["error"] {
            return ("MCP error \(error["code"]?.intValue ?? 0): \(error["message"]?.stringValue ?? "")", true)
        }
        let result = response["result"] ?? .null
        let text = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return (text, result["isError"]?.boolValue ?? false)
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
    }

    private func send(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            // availableData returns as soon as some bytes arrive (read(upToCount:) waits for the full count).
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }
}

let mcp = arguments.mcpConfig.flatMap { MCPClient(configPath: $0) }

// MARK: - Stdin reader (background, so interrupts arrive while a reply streams)

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var lines: [JSONValue] = []
    private var closed = false

    func start() {
        let thread = Thread { [self] in
            while let line = Swift.readLine(strippingNewline: true) {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                lock.withLock { lines.append(message) }
                available.signal()
            }
            lock.withLock { closed = true }
            available.signal()
        }
        thread.start()
    }

    /// Next message, waiting for one. Nil at end of input.
    func next() -> JSONValue? {
        while true {
            available.wait()
            // Spelled out: a bare `nil` in a ternary would become JSONValue.null (ExpressibleByNilLiteral).
            let (message, isClosed): (JSONValue?, Bool) = lock.withLock {
                let first: JSONValue? = lines.isEmpty ? Optional.none : lines.removeFirst()
                return (first, closed)
            }
            if let message { return message }
            if isClosed {
                // Keep later calls from blocking.
                available.signal()
                return nil
            }
            // The message behind this signal was taken by takeInterrupt(); wait for the next one.
        }
    }

    /// Removes and returns a pending interrupt request id, if any.
    func takeInterrupt() -> String? {
        lock.withLock {
            guard let index = lines.firstIndex(where: { $0["type"]?.stringValue == "control_request" }) else { return nil }
            return lines.remove(at: index)["request_id"]?.stringValue ?? ""
        }
    }
}

let inbox = Inbox()
inbox.start()

// MARK: - Events

var messageCounter = 0
var toolCounter = 0

@MainActor func base(_ type: String) -> [String: JSONValue] {
    ["type": .string(type), "session_id": .string(sessionID), "uuid": .string(UUID().uuidString.lowercased())]
}

@MainActor func streamEvent(_ event: JSONValue, messageID: String) {
    var line = base("stream_event")
    line["event"] = event
    line["parent_tool_use_id"] = .null
    line["api_message_id"] = .string(messageID)
    emit(.object(line))
}

@MainActor func emitInit() {
    var line = base("system")
    line["subtype"] = "init"
    line["cwd"] = .string(cwd)
    line["tools"] = .array((mcp?.toolNames ?? []).map { .string("mcp__\(ToolCatalog.serverName)__\($0)") })
    line["mcp_servers"] = arguments.mcpConfig == nil ? [] : [["name": .string(ToolCatalog.serverName), "status": .string(mcp == nil ? "failed" : "connected")]]
    line["model"] = .string(arguments.model)
    line["permissionMode"] = "dontAsk"
    line["apiKeySource"] = .string(scriptAPIKeySource() ?? "none")
    line["claude_code_version"] = "0.0.0-fake"
    line["output_style"] = "default"
    line["capabilities"] = ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"]
    emit(.object(line))
}

@MainActor func emitStatus() {
    var line = base("system")
    line["subtype"] = "status"
    line["status"] = "requesting"
    emit(.object(line))
}

@MainActor func startMessage() -> String {
    messageCounter += 1
    let id = "msg_fake_\(messageCounter)"
    streamEvent(["type": "message_start", "message": [
        "model": .string(arguments.model), "id": .string(id), "type": "message", "role": "assistant", "content": [],
        "usage": ["input_tokens": 10, "output_tokens": 1],
    ]], messageID: id)
    return id
}

@MainActor func endMessage(_ id: String, stopReason: String) {
    streamEvent(["type": "content_block_stop", "index": 0], messageID: id)
    streamEvent(["type": "message_delta", "delta": ["stop_reason": .string(stopReason)], "usage": ["output_tokens": 20]], messageID: id)
    streamEvent(["type": "message_stop"], messageID: id)
}

@MainActor func assistant(_ id: String, content: JSONValue) {
    var line = base("assistant")
    line["message"] = ["model": .string(arguments.model), "id": .string(id), "type": "message", "role": "assistant", "content": content]
    line["parent_tool_use_id"] = .null
    emit(.object(line))
}

/// Runs one tool step. Returns the result text.
@MainActor func runTool(_ name: String, arguments toolArguments: JSONValue) {
    emitStatus()
    let id = startMessage()
    toolCounter += 1
    let toolID = "toolu_fake_\(toolCounter)"
    let qualified = "mcp__\(ToolCatalog.serverName)__\(name)"
    streamEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": .string(toolID), "name": .string(qualified), "input": [:]]], messageID: id)
    let json = (try? JSONEncoder().encode(toolArguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    let middle = json.index(json.startIndex, offsetBy: json.count / 2)
    for part in [String(json[..<middle]), String(json[middle...])] {
        streamEvent(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": .string(part)]], messageID: id)
    }
    assistant(id, content: [["type": "tool_use", "id": .string(toolID), "name": .string(qualified), "input": toolArguments]])
    endMessage(id, stopReason: "tool_use")

    let outcome: (text: String, isError: Bool)
    if !arguments.allowedTools.isEmpty, !arguments.allowedTools.contains(qualified) {
        outcome = ("Permission to use \(qualified) has been denied.", true)
    } else if let mcp {
        outcome = mcp.callTool(name, arguments: toolArguments)
    } else {
        outcome = ("No such tool available: \(qualified)", true)
    }
    var line = base("user")
    var block: [String: JSONValue] = ["tool_use_id": .string(toolID), "type": "tool_result", "content": [["type": "text", "text": .string(outcome.text)]]]
    if outcome.isError { block["is_error"] = true }
    line["message"] = ["role": "user", "content": [.object(block)]]
    line["parent_tool_use_id"] = .null
    emit(.object(line))
}

/// Streams a text reply word by word. Returns the interrupt request id if one arrived.
@MainActor func runText(_ text: String, delayMs: Int) -> String? {
    emitStatus()
    let id = startMessage()
    streamEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]], messageID: id)
    var words: [String] = []
    var current = ""
    for character in text {
        current.append(character)
        if character == " " {
            words.append(current)
            current = ""
        }
    }
    if !current.isEmpty { words.append(current) }
    var sent = ""
    for word in words {
        if let interrupt = inbox.takeInterrupt() {
            assistant(id, content: [["type": "text", "text": .string(sent)]])
            streamEvent(["type": "message_delta", "delta": ["stop_reason": .null], "usage": ["output_tokens": 5]], messageID: id)
            return interrupt
        }
        streamEvent(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": .string(word)]], messageID: id)
        sent += word
        if delayMs > 0 {
            fflush(stdout)
            usleep(useconds_t(delayMs * 1000))
        }
    }
    assistant(id, content: [["type": "text", "text": .string(text)]])
    endMessage(id, stopReason: "end_turn")
    return nil
}

@MainActor func emitResult(subtype: String, isError: Bool, text: String, turns: Int, started: Date, terminalReason: String) {
    var line = base("result")
    line["subtype"] = .string(subtype)
    line["is_error"] = .bool(isError)
    line["result"] = .string(text)
    line["num_turns"] = .int(Int64(turns))
    line["duration_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
    line["total_cost_usd"] = 0
    line["usage"] = ["input_tokens": .int(Int64(10 * turns)), "output_tokens": .int(Int64(20 * turns)), "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
    line["permission_denials"] = []
    line["terminal_reason"] = .string(terminalReason)
    line["stop_reason"] = isError ? .null : "end_turn"
    line["api_error_status"] = .null
    emit(.object(line))
}

@MainActor func emitControlResponse(_ requestID: String) {
    emit(["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID), "response": ["still_queued": []]]])
}

// MARK: - Scripts

enum Step {
    case tool(String, JSONValue)
    case text(String, delayMs: Int)
}

@MainActor func scriptDocument() -> JSONValue? {
    let url = URL(fileURLWithPath: cwd).appendingPathComponent("fake-claude-script.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// `"apiKeySource"` in the script file: what `system/init` reports (tests of the API key block).
@MainActor func scriptAPIKeySource() -> String? {
    scriptDocument()?["apiKeySource"]?.stringValue
}

@MainActor func loadScript() -> [[Step]]? {
    guard let script = scriptDocument() else { return nil }
    let turns = (script["turns"]?.arrayValue ?? []).map { turn in
        (turn["steps"]?.arrayValue ?? []).compactMap { step -> Step? in
            if let tool = step["tool"]?.stringValue { return .tool(tool, step["arguments"] ?? [:]) }
            if let text = step["text"]?.stringValue { return .text(text, delayMs: 0) }
            if let text = step["slow_text"]?.stringValue { return .text(text, delayMs: Int(step["delay_ms"]?.intValue ?? 20)) }
            return nil
        }
    }
    return turns.isEmpty ? nil : turns
}

@MainActor func builtInSteps(for message: String) -> [Step] {
    let paths = message.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) }
        .filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
    if !paths.isEmpty {
        let items: [JSONValue] = paths.map { ["path": .string($0), "reason": "Named in the request."] }
        return [
            .tool(ToolName.proposeDeletion.rawValue, ["items": .array(items), "summary": "Items you asked about."]),
            .text("I suggested \(paths.count) item(s). Nothing was deleted; review them in the app.", delayMs: 0),
        ]
    }
    if message.contains("[slow]") {
        let story = (1...200).map { "word\($0)" }.joined(separator: " ")
        return [.text(story, delayMs: 15)]
    }
    return [
        .tool(ToolName.getDiskOverview.rawValue, [:]),
        .text("Here is a short overview of your disk.", delayMs: 0),
    ]
}

// MARK: - Main loop

let script = loadScript()
let lateInit = scriptDocument()?["lateInit"]?.boolValue ?? false
var initSent = false
if !lateInit {
    emitInit()
    initSent = true
}
var turnIndex = 0

/// Appends one line per received user message to `<cwd>/fake-claude-inbox.log` (tests check that a
/// refused session never delivered a message).
@MainActor func recordInbox() {
    let url = URL(fileURLWithPath: cwd).appendingPathComponent("fake-claude-inbox.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data("user\n".utf8))
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: url.path, contents: Data("user\n".utf8))
    }
}

@MainActor func emitInterrupted(_ requestID: String, turns: Int, started: Date) {
    emitControlResponse(requestID)
    var line = base("user")
    line["message"] = ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]
    emit(.object(line))
    emitResult(subtype: "error_during_execution", isError: true, text: "", turns: turns, started: started, terminalReason: "aborted_streaming")
}

while let message = inbox.next() {
    switch message["type"]?.stringValue {
    case "control_request":
        emitControlResponse(message["request_id"]?.stringValue ?? "")
    case "user":
        recordInbox()
        if !initSent {
            initSent = true
            emitInit()
            // Request latency of the real CLI between init and the first event of the turn.
            var early: String?
            for _ in 0..<30 {
                if let id = inbox.takeInterrupt() {
                    early = id
                    break
                }
                usleep(10_000)
            }
            if let early {
                emitInterrupted(early, turns: 0, started: Date())
                continue
            }
        }
        let text = (message["message"]?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        let steps = script.map { $0[min(turnIndex, $0.count - 1)] } ?? builtInSteps(for: text)
        turnIndex += 1
        let started = Date()
        var turns = 0
        var lastText = ""
        var interrupted: String?
        for step in steps {
            turns += 1
            switch step {
            case .tool(let name, let toolArguments):
                runTool(name, arguments: toolArguments)
            case .text(let reply, let delayMs):
                lastText = reply
                interrupted = runText(reply, delayMs: delayMs)
            }
            if interrupted == nil { interrupted = inbox.takeInterrupt() }
            if interrupted != nil { break }
        }
        if let requestID = interrupted {
            emitInterrupted(requestID, turns: turns, started: started)
        } else {
            emitResult(subtype: "success", isError: false, text: lastText, turns: turns, started: started, terminalReason: "completed")
        }
    default:
        break
    }
    fflush(stdout)
}

mcp?.stop()
exit(0)
