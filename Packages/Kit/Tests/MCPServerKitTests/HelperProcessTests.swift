import Darwin
import Foundation
import IPCProtocol
import Synchronization
import Testing
import TestSupport
@testable import MCPServerKit


/// Runs the helper binary with the given stdin lines and returns its stdout lines.
func runHelper(arguments: [String] = [], environment: [String: String] = [:], input: [String]) throws -> [String] {
    let process = Process()
    process.executableURL = Products.url("mcp-helper")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data(input.map { $0 + "\n" }.joined().utf8))
    try stdin.fileHandleForWriting.close()
    let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

@Suite("mcp-helper binary")
struct HelperProcessTests {
    @Test func worksWithAppAbsent() throws {
        let lines = try runHelper(arguments: ["--socket", "/nonexistent/lightwell-test.sock"], environment: [IPC.nonceEnvironmentKey: "abc"], input: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_largest_items","arguments":{}}}"#,
        ])
        #expect(lines.count == 3)
        let list = try JSONDecoder().decode(JSONValue.self, from: Data(lines[1].utf8))
        #expect(list["result"]?["tools"]?.arrayValue?.count == 8)
        #expect(lines[2] == #"{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"Open Lightwell and scan a disk first.","type":"text"}],"isError":true}}"#)
    }

    @Test func printsVersion() throws {
        #expect(try runHelper(arguments: ["--version"], input: []) == ["lightwell-mcp \(MCPHelperMain.version)"])
    }

    /// PLAN acceptance: helper cold start under 50 ms (spawn to `initialize` answer). Best of 5 runs to
    /// keep the check stable while other builds load the machine.
    @Test func coldStartIsFast() throws {
        var best = Double.infinity
        for _ in 0..<5 {
            let process = Process()
            process.executableURL = Products.url("mcp-helper")
            process.environment = ["PATH": "/usr/bin:/bin"]
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let start = DispatchTime.now()
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8 + [0x0A]))
            var received = Data()
            while !received.contains(0x0A) {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                received.append(chunk)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(received.contains(0x0A))
            best = min(best, elapsed)
        }
        print("mcp-helper cold start best of 5: \(String(format: "%.1f", best)) ms")
        #expect(best < 50)
    }
}

/// Minimal stand-in for the app's IPC server: checks the hello nonce and echoes tool calls.
final class FakeAppSocket: @unchecked Sendable {
    let path: String
    let expectedNonce: String
    /// Close each connection after this many tool calls (0 = never).
    let closeAfterCalls: Int
    /// Never answer tool calls (timeout tests).
    let silent: Bool
    private let listenFD: Int32
    let hellos = Mutex(0)
    let calls = Mutex<[String]>([])

    init(expectedNonce: String, closeAfterCalls: Int = 0, silent: Bool = false) throws {
        self.silent = silent
        self.expectedNonce = expectedNonce
        self.closeAfterCalls = closeAfterCalls
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("lwt-\(UUID().uuidString.prefix(8)).sock")
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    func stop() {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            let thread = Thread { [self] in serve(client) }
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var reader = LineReader()
        guard case .success(let helloLine) = reader.readLine(from: fd),
              let hello = try? JSONDecoder().decode(IPCRequest.self, from: helloLine),
              hello.method == "hello",
              hello.params["nonce"]?.stringValue == expectedNonce
        else { return }
        hellos.withLock { $0 += 1 }
        reply(fd, IPCResponse(id: hello.id, result: ["ok": true]))
        var served = 0
        while case .success(let line) = reader.readLine(from: fd) {
            guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else { return }
            let name = request.params["name"]?.stringValue ?? ""
            calls.withLock { $0.append(name) }
            if silent { continue }
            reply(fd, IPCResponse(id: request.id, result: ["text": .string("echo:\(name)"), "isError": false]))
            served += 1
            if closeAfterCalls > 0, served >= closeAfterCalls { return }
        }
    }

    private func reply(_ fd: Int32, _ response: IPCResponse) {
        guard let data = try? IPC.encodeLine(response) else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

@Suite("Socket backend")
struct SocketBackendTests {
    @Test func helloThenCall() throws {
        let app = try FakeAppSocket(expectedNonce: "good")
        defer { app.stop() }
        let backend = SocketToolBackend(socketPath: app.path, nonce: "good", timeoutSeconds: 5)
        #expect(backend.callTool(name: "get_disk_overview", arguments: [:]) == ToolCallResult(text: "echo:get_disk_overview", isError: false))
        #expect(backend.callTool(name: "list_children", arguments: ["path": "/"]) == ToolCallResult(text: "echo:list_children", isError: false))
        #expect(app.hellos.withLock { $0 } == 1)
    }

    @Test func reconnectsOnceAfterDrop() throws {
        let app = try FakeAppSocket(expectedNonce: "good", closeAfterCalls: 1)
        defer { app.stop() }
        let backend = SocketToolBackend(socketPath: app.path, nonce: "good", timeoutSeconds: 5)
        #expect(backend.callTool(name: "get_disk_overview", arguments: [:]).text == "echo:get_disk_overview")
        #expect(backend.callTool(name: "get_cleanup_queue", arguments: [:]).text == "echo:get_cleanup_queue")
        #expect(app.hellos.withLock { $0 } == 2)
    }

    @Test func timeoutIsNotResent() throws {
        let app = try FakeAppSocket(expectedNonce: "good", silent: true)
        defer { app.stop() }
        let backend = SocketToolBackend(socketPath: app.path, nonce: "good", timeoutSeconds: 1)
        let result = backend.callTool(name: "search_items", arguments: [:])
        #expect(result == ToolCallResult(text: "The app took too long to answer. Try a narrower request.", isError: true))
        #expect(app.calls.withLock { $0 } == ["search_items"])
        #expect(app.hellos.withLock { $0 } == 1)
    }

    @Test func wrongNonceEndsInGuidance() throws {
        let app = try FakeAppSocket(expectedNonce: "good")
        defer { app.stop() }
        let backend = SocketToolBackend(socketPath: app.path, nonce: "bad", timeoutSeconds: 5)
        #expect(backend.callTool(name: "get_disk_overview", arguments: [:]) == ToolCallResult(text: ToolCatalog.appUnavailableText, isError: true))
        #expect(app.calls.withLock { $0 }.isEmpty)
    }

    @Test func helperBinaryForwardsOverSocket() throws {
        let app = try FakeAppSocket(expectedNonce: "n-123")
        defer { app.stop() }
        let lines = try runHelper(arguments: ["--socket", app.path], environment: [IPC.nonceEnvironmentKey: "n-123"], input: [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect_path","arguments":{"path":"~"}}}"#,
        ])
        #expect(lines == [#"{"id":1,"jsonrpc":"2.0","result":{"content":[{"text":"echo:inspect_path","type":"text"}],"isError":false}}"#])
    }
}
