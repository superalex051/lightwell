import Darwin
import Foundation
import IPCProtocol
import Synchronization
import Testing
import TestSupport
@testable import AIBridge


/// Runs a short command and returns (status, stdout + stderr).
@discardableResult
func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    let data = Mutex(Data())
    output.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { data.withLock { $0.append(chunk) } }
    }
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    usleep(50_000)
    output.fileHandleForReading.readabilityHandler = nil
    return (process.terminationStatus, String(decoding: data.withLock { $0 }, as: UTF8.self))
}

/// Calls one tool through the real helper binary (as claude would) and returns the MCP result.
func callThroughHelper(_ helper: URL, socket: String, secret: String, tool: String = "get_disk_overview", arguments: JSONValue = [:]) throws -> (text: String, isError: Bool) {
    let process = Process()
    process.executableURL = helper
    process.arguments = ["--socket", socket]
    process.environment = ["PATH": "/usr/bin:/bin", IPC.nonceEnvironmentKey: secret]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]]
    try stdin.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request) + Data([0x0A]))
    try stdin.fileHandleForWriting.close()
    let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    let response = try JSONDecoder().decode(JSONValue.self, from: data)
    let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    return (text, response["result"]?["isError"]?.boolValue ?? true)
}

/// First Apple Development signing identity (SHA-1), if this Mac has one.
func developmentIdentity() -> String? {
    guard let (status, output) = try? run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], timeout: 15), status == 0 else { return nil }
    for line in output.split(separator: "\n") where line.contains("Apple Development") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count > 1, parts[1].count == 40 { return String(parts[1]) }
    }
    return nil
}

/// Copy of the helper re-signed with `identity` ("-" for ad hoc) and `identifier`.
func signedHelperCopy(in fx: FixtureBuilder, name: String, identity: String, identifier: String) throws -> URL {
    let copy = try fx.url("bin/\(name)")
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Products.url("mcp-helper"), to: copy)
    let (status, output) = try run("/usr/bin/codesign", ["--force", "--sign", identity, "--identifier", identifier, copy.path])
    guard status == 0 else { throw POSIXError(.EPERM, userInfo: ["codesign": output]) }
    return copy
}

struct IPCTestbed {
    let fx: FixtureBuilder
    let server: IPCServer
    let handler: ScriptedToolHandler

    init(policy: PeerPolicy) throws {
        fx = try FixtureBuilder()
        handler = ScriptedToolHandler(home: fx.root.path)
        server = IPCServer(directory: fx.root.appendingPathComponent("ipc"), handler: handler, peerPolicy: policy)
        try server.start()
    }

    func tearDown() {
        server.stop()
        fx.tearDown()
    }

    /// Waits until `count` rejections were recorded (they are recorded on the connection thread).
    func rejections(atLeast count: Int) -> [IPCRejection] {
        let deadline = Date().addingTimeInterval(5)
        while server.rejections.count < count, Date() < deadline { usleep(10_000) }
        return server.rejections
    }
}

var helperCdhash: String {
    PeerVerifier.signingInfo(at: Products.url("mcp-helper"))?.cdhash ?? ""
}

@Suite("IPC server and peer verification", .serialized)
struct IPCServerTests {
    @Test func acceptsHelperInCdhashMode() throws {
        let bed = try IPCTestbed(policy: .cdhash(helperCdhash))
        defer { bed.tearDown() }
        #expect(posixMode(bed.server.socketPath) == 0o600)
        let thread = UUID()
        let secret = MCPConfigWriter.makeNonce()
        bed.server.register(nonce: secret, thread: thread)
        let result = try callThroughHelper(Products.url("mcp-helper"), socket: bed.server.socketPath, secret: secret)
        #expect(!result.isError)
        let overview = try JSONDecoder().decode(DiskOverviewResult.self, from: Data(result.text.utf8))
        #expect(overview.volume == "Test Volume")
        #expect(bed.handler.calls.map(\.name) == ["get_disk_overview"])
        #expect(bed.handler.calls.first?.thread == thread)
        #expect(bed.server.acceptedConnections == 1)
        #expect(bed.server.rejections.isEmpty)
    }

    @Test func rejectsWrongNonce() throws {
        let bed = try IPCTestbed(policy: .cdhash(helperCdhash))
        defer { bed.tearDown() }
        bed.server.register(nonce: MCPConfigWriter.makeNonce(), thread: UUID())
        let result = try callThroughHelper(Products.url("mcp-helper"), socket: bed.server.socketPath, secret: MCPConfigWriter.makeNonce())
        #expect(result == (ToolCatalog.appUnavailableText, true))
        #expect(bed.handler.calls.isEmpty)
        #expect(bed.rejections(atLeast: 2) == [.badNonce, .badNonce])
    }

    @Test func rejectsUnregisteredNonceAfterUnregister() throws {
        let bed = try IPCTestbed(policy: .cdhash(helperCdhash))
        defer { bed.tearDown() }
        let secret = MCPConfigWriter.makeNonce()
        bed.server.register(nonce: secret, thread: UUID())
        bed.server.unregister(nonce: secret)
        let result = try callThroughHelper(Products.url("mcp-helper"), socket: bed.server.socketPath, secret: secret)
        #expect(result.isError)
        #expect(bed.rejections(atLeast: 2).allSatisfy { $0 == .badNonce })
    }

    /// cdhash mode: a binary signed with another identifier has another cdhash and is refused before
    /// anything is read, even with a valid nonce.
    @Test func rejectsBinaryWithWrongIdentifierInCdhashMode() throws {
        let bed = try IPCTestbed(policy: .cdhash(helperCdhash))
        defer { bed.tearDown() }
        let impostor = try signedHelperCopy(in: bed.fx, name: "impostor", identity: "-", identifier: "com.example.impostor")
        #expect(PeerVerifier.signingInfo(at: impostor)?.cdhash != helperCdhash)
        let secret = MCPConfigWriter.makeNonce()
        bed.server.register(nonce: secret, thread: UUID())
        let result = try callThroughHelper(impostor, socket: bed.server.socketPath, secret: secret)
        #expect(result == (ToolCatalog.appUnavailableText, true))
        #expect(bed.handler.calls.isEmpty)
        #expect(bed.rejections(atLeast: 2) == [.peerUnverified, .peerUnverified])
    }

    /// Team mode: an ad hoc signed helper (no certificate, the "unsigned" case) is refused even with
    /// the right identifier and nonce.
    @Test func rejectsUnsignedPeerInTeamMode() throws {
        let bed = try IPCTestbed(policy: .team(identifier: "com.alexluncan.lightwell.mcp", teamID: "TESTTEAM01"))
        defer { bed.tearDown() }
        let adhoc = try signedHelperCopy(in: bed.fx, name: "adhoc", identity: "-", identifier: "com.alexluncan.lightwell.mcp")
        #expect(PeerVerifier.signingInfo(at: adhoc)?.teamID == nil)
        let secret = MCPConfigWriter.makeNonce()
        bed.server.register(nonce: secret, thread: UUID())
        let result = try callThroughHelper(adhoc, socket: bed.server.socketPath, secret: secret)
        #expect(result.isError)
        #expect(bed.handler.calls.isEmpty)
        #expect(bed.rejections(atLeast: 2) == [.peerUnverified, .peerUnverified])
    }

    /// An Apple-signed system binary (`nc`) connecting to the socket is refused on accept.
    @Test func rejectsForeignSignedClient() throws {
        let bed = try IPCTestbed(policy: .cdhash(helperCdhash))
        defer { bed.tearDown() }
        bed.server.register(nonce: MCPConfigWriter.makeNonce(), thread: UUID())
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", bed.server.socketPath]
        let input = Pipe()
        nc.standardInput = input
        nc.standardOutput = FileHandle.nullDevice
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer {
            try? input.fileHandleForWriting.close()
            if nc.isRunning { nc.terminate() }
            nc.waitUntilExit()
        }
        #expect(bed.rejections(atLeast: 1) == [.peerUnverified])
        #expect(bed.server.acceptedConnections == 0)
    }

    @Test(.enabled(if: developmentIdentity() != nil, "needs an Apple Development signing identity"))
    func teamModeWithDevelopmentSignature() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let identity = try #require(developmentIdentity())
        let good = try signedHelperCopy(in: fx, name: "good", identity: identity, identifier: "com.alexluncan.lightwell.mcp")
        let wrong = try signedHelperCopy(in: fx, name: "wrong", identity: identity, identifier: "com.alexluncan.lightwell.other")
        let team = try #require(PeerVerifier.signingInfo(at: good)?.teamID)

        let handler = ScriptedToolHandler(home: fx.root.path)
        let server = IPCServer(directory: fx.root.appendingPathComponent("ipc"), handler: handler, peerPolicy: .team(identifier: "com.alexluncan.lightwell.mcp", teamID: team))
        try server.start()
        defer { server.stop() }
        let secret = MCPConfigWriter.makeNonce()
        server.register(nonce: secret, thread: UUID())

        let accepted = try callThroughHelper(good, socket: server.socketPath, secret: secret)
        #expect(!accepted.isError)
        #expect(server.acceptedConnections == 1)

        let refused = try callThroughHelper(wrong, socket: server.socketPath, secret: secret)
        #expect(refused == (ToolCatalog.appUnavailableText, true))
        let deadline = Date().addingTimeInterval(5)
        while server.rejections.count < 2, Date() < deadline { usleep(10_000) }
        #expect(server.rejections == [.peerUnverified, .peerUnverified])
    }

    @Test func requirementStrings() {
        #expect(PeerVerifier.requirementString(for: .team(identifier: "com.alexluncan.lightwell.mcp", teamID: "TESTTEAM01")) ==
            #"identifier "com.alexluncan.lightwell.mcp" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01""#)
        let hash = String(repeating: "ab", count: 20)
        #expect(PeerVerifier.requirementString(for: .cdhash(hash.uppercased())) == "cdhash H\"\(hash)\"")
        #expect(PeerVerifier.requirementString(for: .cdhash("1234")) == nil)
        #expect(PeerVerifier.requirementString(for: .automatic(helperURL: URL(fileURLWithPath: "/nonexistent/helper"))) == nil
            || PeerVerifier.ownSigningInfo()?.teamID != nil)
        for policy in [PeerPolicy.team(identifier: "a.b", teamID: "TESTTEAM01"), .cdhash(hash)] {
            #expect(PeerVerifier.compile(PeerVerifier.requirementString(for: policy)!) != nil)
        }
    }

    @Test func startFailsWithoutUsablePolicy() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let server = IPCServer(directory: fx.root.appendingPathComponent("ipc"), handler: ScriptedToolHandler(), peerPolicy: .cdhash("zz"))
        #expect(throws: IPCServerError.peerPolicyUnavailable) { try server.start() }
    }

    @Test func socketPathRule() {
        #expect(IPCServer.socketPath(directory: URL(fileURLWithPath: "/Users/u/Library/Application Support/Lightwell/ipc"), pid: 4242, index: 0)
            == "/Users/u/Library/Application Support/Lightwell/ipc/s-4242.sock")
        #expect(IPCServer.socketPath(directory: URL(fileURLWithPath: "/short"), pid: 7, index: 3) == "/short/s-7-3.sock")
        let long = URL(fileURLWithPath: "/" + String(repeating: "d", count: 120))
        let fallback = IPCServer.socketPath(directory: long, pid: 4242, index: 0)
        #expect(fallback == (NSTemporaryDirectory() as NSString).appendingPathComponent("lightwell-4242.sock"))
    }

    @Test func stopRemovesSocket() throws {
        let bed = try IPCTestbed(policy: .cdhash(helperCdhash))
        let path = bed.server.socketPath
        #expect(FileManager.default.fileExists(atPath: path))
        bed.tearDown()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    @Test func oversizedHandlerResultIsCappedAtTheServer() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let handler = ScriptedToolHandler(home: fx.root.path, responses: ["get_cleanup_queue": ToolCallResult(text: String(repeating: "q", count: 30_000))])
        let server = IPCServer(directory: fx.root.appendingPathComponent("ipc"), handler: handler, peerPolicy: .cdhash(helperCdhash))
        try server.start()
        defer { server.stop() }
        let secret = MCPConfigWriter.makeNonce()
        server.register(nonce: secret, thread: UUID())
        let result = try callThroughHelper(Products.url("mcp-helper"), socket: server.socketPath, secret: secret, tool: "get_cleanup_queue")
        #expect(result == (ToolOutput.tooLargeMessage(size: 30_000), true))
        #expect(handler.calls.count == 1)
    }

    /// A policy for the test process's own cdhash lets it act as a raw peer.
    @Test func undecodableRequestAfterHelloGetsAnErrorOrClose() throws {
        let bed = try IPCTestbed(policy: .cdhash(PeerVerifier.ownSigningInfo()?.cdhash ?? ""))
        defer { bed.tearDown() }
        let secret = MCPConfigWriter.makeNonce()
        bed.server.register(nonce: secret, thread: UUID())
        let client = try RawClient(path: bed.server.socketPath)
        defer { client.close() }
        client.send(#"{"id":1,"method":"hello","params":{"nonce":"\#(secret)","protocol":1,"helperVersion":"test"}}"#)
        #expect(client.readLine() == #"{"id":1,"result":{"ok":true}}"#)
        client.send(#"{"id":9,"params":{}}"#)
        #expect(client.readLine() == #"{"error":{"code":-32600,"message":"invalid request"},"id":9}"#)
        client.send(#"{"id":2,"method":"ping","params":{}}"#)
        #expect(client.readLine() == #"{"id":2,"result":{"ok":true}}"#)
        client.send("not json at all")
        #expect(client.readLine() == nil)
    }

    @Test func pendingConnectionsAreCapped() throws {
        let bed = try IPCTestbed(policy: .cdhash(PeerVerifier.ownSigningInfo()?.cdhash ?? ""))
        defer { bed.tearDown() }
        var clients: [RawClient] = []
        defer { clients.forEach { $0.close() } }
        for _ in 0..<(IPCServer.maxPendingConnections + 3) {
            clients.append(try RawClient(path: bed.server.socketPath))
        }
        let rejected = bed.rejections(atLeast: 3)
        #expect(rejected.filter { $0 == .tooManyPending }.count == 3)
        #expect(bed.server.acceptedConnections == 0)
    }
}

/// Minimal blocking Unix socket client for protocol tests.
final class RawClient {
    let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Next line, or nil when the server closed the connection (or 5 s passed).
    func readLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func close() {
        Darwin.close(fd)
    }
}
