import Darwin
import Foundation
import IPCProtocol
import Synchronization
import Testing
import TestSupport
@testable import AIBridge

/// Collects a session's events in the background.
final class EventCollector: Sendable {
    private let store = Mutex<[StreamEvent]>([])
    private let ended = Mutex(false)

    convenience init(_ session: ClaudeSession) {
        self.init(stream: session.events)
    }

    /// Takes only the stream, so the collector does not keep the session alive.
    init(stream: AsyncStream<StreamEvent>) {
        Task.detached { [self] in
            for await event in stream { self.store.withLock { $0.append(event) } }
            self.ended.withLock { $0 = true }
        }
    }

    var events: [StreamEvent] { store.withLock { $0 } }
    var finished: Bool { ended.withLock { $0 } }

    /// Polls until `condition` holds or `timeout` passes.
    @discardableResult
    func wait(timeout: TimeInterval = 15, _ condition: ([StreamEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(events) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(events)
    }

    func results(_ events: [StreamEvent]? = nil) -> [TurnResult] {
        (events ?? self.events).compactMap { if case .result(let r) = $0 { r } else { nil } }
    }
}

struct SessionTestbed {
    let fx: FixtureBuilder
    let server: IPCServer
    let handler: ScriptedToolHandler
    let config: AssistantConfig

    init(claude: URL = Products.url("fake-claude"), model: String? = nil, maxTurns: Int? = nil, knownPaths: (FixtureBuilder) throws -> [String: UInt64] = { _ in [:] }, protected: (FixtureBuilder) -> [String] = { _ in [] }, risks: (FixtureBuilder) -> [String: String] = { _ in [:] }, fakeScript: JSONValue? = nil) throws {
        fx = try FixtureBuilder()
        handler = ScriptedToolHandler(home: fx.root.path, knownPaths: try knownPaths(fx), protectedPaths: protected(fx), risks: risks(fx))
        server = IPCServer(directory: fx.root.appendingPathComponent("ipc"), handler: handler, peerPolicy: .cdhash(helperCdhash))
        try server.start()
        let assistant = fx.root.appendingPathComponent("assistant")
        config = AssistantConfig(
            claude: ClaudeInstallation(url: claude, version: nil, source: .override),
            workingDirectory: assistant,
            helperURL: Products.url("mcp-helper"),
            socketPath: server.socketPath,
            model: model,
            maxTurns: maxTurns
        )
        let template = try String(contentsOf: AssistantFileTests.templateURL, encoding: .utf8)
        try SystemPromptRenderer.write(SystemPromptRenderer.render(template: template, scanAgeSeconds: 60, scannedRoot: "~"), to: config.resolvedSystemPromptURL)
        if let fakeScript {
            try JSONEncoder().encode(fakeScript).write(to: assistant.appendingPathComponent("fake-claude-script.json"))
        }
    }

    func tearDown() {
        server.stop()
        fx.tearDown()
    }
}

@Suite("Claude session with fake-claude", .serialized)
struct SessionTests {
    @Test func proposeTwoFixturePathsThroughTheWholeChain() async throws {
        let bed = try SessionTestbed(
            knownPaths: { fx in
                [try fx.file("Library/Developer/Xcode/DerivedData/App-1/build.o", size: 4096).deletingLastPathComponent().path: 4096,
                 try fx.file("Downloads/old-installer.dmg", size: 8192).path: 8192]
            },
            protected: { fx in [fx.root.appendingPathComponent("Library/Keychains").path] }
        )
        defer { bed.tearDown() }
        let thread = UUID()
        let session = ClaudeSession(config: bed.config, thread: thread, resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        #expect(posixMode(session.mcpConfigURL.path) == 0o600)

        #expect(await collector.wait { $0.contains { $0.kind == "initialized" } })
        guard case .initialized(let info) = collector.events.first else {
            Issue.record("no init")
            return
        }
        #expect(info.isDiskServerConnected)
        #expect(info.supportsInterrupt)
        #expect(info.apiKeySource == "none")
        #expect(info.sessionID == thread.uuidString.lowercased())
        #expect(info.tools == ToolCatalog.all.map(\.qualifiedName))

        let paths = ["~/Library/Developer/Xcode/DerivedData/App-1", "~/Downloads/old-installer.dmg", "~/Library/Keychains/login.keychain-db"]
        try session.send("Please suggest " + paths.joined(separator: " "))
        #expect(await collector.wait { !collector.results($0).isEmpty })

        let events = collector.events
        let starts = events.compactMap { if case .toolUseStart(_, let name) = $0 { name } else { nil } }
        #expect(starts == ["mcp__disk__propose_deletion"])
        let toolText = try #require(events.compactMap { if case .toolResult(_, let text, false) = $0 { text } else { nil } }.first)
        let proposal = try JSONDecoder().decode(ProposeDeletionResult.self, from: Data(toolText.utf8))
        #expect(proposal.queued.map(\.path) == ["~/Library/Developer/Xcode/DerivedData/App-1", "~/Downloads/old-installer.dmg"])
        #expect(proposal.queued.map(\.bytes) == [4096, 8192])
        #expect(proposal.rejected.map(\.code) == ["protected"])
        #expect(proposal.note == ToolCatalog.proposalNote)
        #expect(bed.handler.calls.map(\.name) == ["propose_deletion"])
        #expect(bed.handler.calls.first?.thread == thread)
        #expect(collector.results().first?.subtype == "success")
        #expect(events.contains(.status("requesting")))
        #expect(events.contains(.messageDelta(stopReason: "tool_use")))

        session.close()
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
        #expect(await collector.wait { _ in collector.finished })
        #expect(!FileManager.default.fileExists(atPath: session.mcpConfigURL.path))
        #expect(session.exitStatus == 0)
        // The nonce is unregistered once the session ends.
        let late = try callThroughHelper(Products.url("mcp-helper"), socket: bed.server.socketPath, secret: session.mcpNonce)
        #expect(late.isError)
    }

    @Test func interruptStopsTheTurnAndTheSessionContinues() async throws {
        let bed = try SessionTestbed()
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("[slow] tell me a long story")
        #expect(await collector.wait { $0.contains { $0.kind == "textDelta" } })
        #expect(session.interrupt() == "req_1")
        #expect(await collector.wait { !collector.results($0).isEmpty })
        #expect(collector.events.contains(.controlResponse(requestID: "req_1", subtype: "success")))
        let first = try #require(collector.results().first)
        #expect(first.subtype == "error_during_execution")
        #expect(first.isError)

        try session.send("What is using my disk?")
        #expect(await collector.wait { collector.results($0).count == 2 })
        #expect(collector.results().last?.subtype == "success")
        #expect(bed.handler.calls.map(\.name) == ["get_disk_overview"])
        session.shutdown(grace: 3)
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
    }

    @Test func lifecycleErrors() async throws {
        let bed = try SessionTestbed()
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: true)
        #expect(throws: AssistantSessionError.notStarted) { try session.send("hi") }
        #expect(session.command.arguments.contains("--resume"))
        let collector = EventCollector(session)
        try session.start()
        #expect(throws: AssistantSessionError.alreadyStarted) { try session.start() }
        session.close()
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
        #expect(throws: AssistantSessionError.inputClosed) { try session.send("late") }
        #expect(session.interrupt() == nil)
    }

    @Test func crashReportsExitStatusAndSavesLog() async throws {
        let bed = try SessionTestbed()
        defer { bed.tearDown() }
        let script = try bed.fx.file("bin/crashy", size: 0)
        try Data("#!/bin/sh\necho 'something broke' >&2\nexit 3\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        var config = bed.config
        config.claude = ClaudeInstallation(url: script, version: nil, source: .override)
        let session = ClaudeSession(config: config, thread: UUID(), resume: false)
        let collector = EventCollector(session)
        try session.start()
        #expect(await collector.wait { $0.last == .processExited(status: 3) })
        #expect(!FileManager.default.fileExists(atPath: session.mcpConfigURL.path))
        #expect(session.stderrTail.contains("something broke"))
        #expect(posixMode(session.logURL.path) == 0o600)
        #expect(try String(contentsOf: session.logURL, encoding: .utf8).contains("something broke"))
    }

    @Test func launchFailureFinishesStream() async throws {
        let bed = try SessionTestbed()
        defer { bed.tearDown() }
        var config = bed.config
        config.claude = ClaudeInstallation(url: bed.fx.root.appendingPathComponent("missing-claude"), version: nil, source: .override)
        let session = ClaudeSession(config: config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        #expect(throws: AssistantSessionError.self) { try session.start() }
        #expect(await collector.wait { _ in collector.finished })
        #expect(!FileManager.default.fileExists(atPath: session.mcpConfigURL.path))
    }

    @Test func fakeClaudeRefusesForbiddenFlags() throws {
        for flag in ClaudeCommandBuilder.forbiddenFlags {
            let (status, _) = try run(Products.url("fake-claude").path, ["-p", flag])
            #expect(status == 2, "\(flag)")
        }
    }

    @Test func apiKeySessionIsRefusedBeforeAnyTurn() async throws {
        let bed = try SessionTestbed(fakeScript: ["apiKeySource": "ANTHROPIC_API_KEY"])
        defer { bed.tearDown() }
        #expect(bed.config.blockAPIKeys)
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        #expect(await collector.wait { $0.contains { $0.kind == "processExited" } })
        let events = collector.events
        #expect(events.map(\.kind) == ["initialized", "refused", "processExited"])
        #expect(events.contains(.refused(.apiKeyInUse(source: "ANTHROPIC_API_KEY"))))
        #expect(session.refusal == .apiKeyInUse(source: "ANTHROPIC_API_KEY"))
        #expect(throws: AssistantSessionError.refused(.apiKeyInUse(source: "ANTHROPIC_API_KEY"))) { try session.send("hello") }
        #expect(bed.handler.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: session.mcpConfigURL.path))
        let late = try callThroughHelper(Products.url("mcp-helper"), socket: bed.server.socketPath, secret: session.mcpNonce)
        #expect(late.isError)
    }

    @Test func apiKeyBlockCanBeTurnedOff() async throws {
        let bed = try SessionTestbed(fakeScript: ["apiKeySource": "ANTHROPIC_API_KEY"])
        defer { bed.tearDown() }
        var config = bed.config
        config.blockAPIKeys = false
        let session = ClaudeSession(config: config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("What is using my disk?")
        #expect(await collector.wait { !collector.results($0).isEmpty })
        #expect(!collector.events.contains { $0.kind == "refused" })
        #expect(collector.results().first?.subtype == "success")
        session.close()
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
    }

    @Test func releasingARunningSessionCleansUp() async throws {
        let bed = try SessionTestbed()
        defer { bed.tearDown() }
        var session: ClaudeSession? = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(stream: session!.events)
        weak let core = session!.core
        let configURL = session!.mcpConfigURL
        let secret = session!.mcpNonce
        try session!.start()
        try session!.send("[slow] keep talking")
        #expect(await collector.wait { $0.contains { $0.kind == "textDelta" } })
        #expect(FileManager.default.fileExists(atPath: configURL.path))
        session = nil

        #expect(await collector.wait(timeout: 10) { _ in collector.finished })
        #expect(collector.events.last?.kind == "processExited")
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        // The core is gone, so no pipe or termination handler (they retain it) is left to fire.
        let deadline = Date().addingTimeInterval(5)
        while core != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(core == nil)
        let late = try callThroughHelper(Products.url("mcp-helper"), socket: bed.server.socketPath, secret: secret)
        #expect(late.isError)
    }

    @Test func configDescriptionHidesTheNonce() throws {
        let secret = MCPConfigWriter.makeNonce()
        let config = AssistantConfig(
            claude: ClaudeInstallation(url: URL(fileURLWithPath: "/c"), version: nil, source: .override),
            workingDirectory: URL(fileURLWithPath: "/w"), helperURL: URL(fileURLWithPath: "/h"), socketPath: "/s",
            mcpNonce: secret, baseEnvironment: ["SECRET_VALUE": "hunter2"]
        )
        var dumped = ""
        dump(config, to: &dumped)
        for text in [String(describing: config), String(reflecting: config), "\(config)", dumped] {
            #expect(!text.contains(secret))
            #expect(!text.contains("hunter2"))
        }
        #expect(String(describing: config).contains("<redacted>"))
    }

    /// (a) The `auth status` pre-check refuses an API key login before any turn: the CLI never
    /// receives a user message (late init, like the real CLI, so no init is ever emitted).
    @Test func preCheckRefusesAPIKeyLoginBeforeAnySend() async throws {
        let bed = try SessionTestbed(fakeScript: [
            "lateInit": true,
            "authStatus": ["loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty", "apiKeySource": "apiKeyHelper"],
        ])
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("hello")
        #expect(await collector.wait { $0.contains { $0.kind == "processExited" } })
        #expect(collector.events.map(\.kind) == ["refused", "processExited"])
        #expect(session.refusal == .apiKeyInUse(source: "apiKeyHelper"))
        #expect(throws: AssistantSessionError.refused(.apiKeyInUse(source: "apiKeyHelper"))) { try session.send("again") }
        let inbox = bed.config.workingDirectory.appendingPathComponent("fake-claude-inbox.log")
        #expect(!FileManager.default.fileExists(atPath: inbox.path), "the CLI received a user message")
        #expect(bed.handler.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: session.mcpConfigURL.path))
    }

    /// (b) OAuth status passes the pre-check, then the late init reports a key: the backstop refuses,
    /// no tool call reaches the handler, and the next send throws.
    @Test func backstopRefusesKeyReportedByLateInit() async throws {
        let bed = try SessionTestbed(fakeScript: ["lateInit": true, "apiKeySource": "ANTHROPIC_API_KEY"])
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("What is using my disk?")
        #expect(await collector.wait { $0.contains { $0.kind == "processExited" } })
        #expect(collector.events.map(\.kind) == ["initialized", "refused", "processExited"])
        #expect(collector.events.contains(.refused(.apiKeyInUse(source: "ANTHROPIC_API_KEY"))))
        #expect(bed.handler.calls.isEmpty)
        #expect(throws: AssistantSessionError.refused(.apiKeyInUse(source: "ANTHROPIC_API_KEY"))) { try session.send("next") }
        let inbox = try String(contentsOf: bed.config.workingDirectory.appendingPathComponent("fake-claude-inbox.log"), encoding: .utf8)
        #expect(inbox == "user\n")
    }

    /// (c) OAuth status and a late init with "none" run normally; the message sent before the
    /// pre-check finished is delivered.
    @Test func oauthWithLateInitWorksNormally() async throws {
        let bed = try SessionTestbed(fakeScript: ["lateInit": true])
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("What is using my disk?")
        #expect(await collector.wait { !collector.results($0).isEmpty })
        #expect(collector.events.first?.kind == "initialized")
        #expect(!collector.events.contains { $0.kind == "refused" })
        #expect(collector.results().first?.subtype == "success")
        #expect(bed.handler.calls.map(\.name) == ["get_disk_overview"])
        try session.send("And now?")
        #expect(await collector.wait { collector.results($0).count == 2 })
        session.close()
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
    }

    /// A Console API-credit login (`/login` managed key) is allowed, and an unreadable status never blocks.
    @Test(arguments: [
        JSONValue.object(["loggedIn": true, "authMethod": "api_key", "apiKeySource": "/login managed key"]),
        JSONValue.string("Not JSON at all"),
    ])
    func allowedOrUnreadableStatusDoesNotBlock(status: JSONValue) async throws {
        let bed = try SessionTestbed(fakeScript: ["lateInit": true, "authStatus": status])
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("hi")
        #expect(await collector.wait { !collector.results($0).isEmpty })
        #expect(collector.results().first?.subtype == "success")
        #expect(session.refusal == nil)
        session.close()
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
    }

    /// Stop pressed while the pre-check is still running: the held message is dropped, so the
    /// stopped turn never reaches the CLI once the check passes. Later messages still work.
    @Test func interruptDuringPreCheckDropsHeldMessages() async throws {
        let bed = try SessionTestbed(fakeScript: [
            "lateInit": true,
            "authStatus": ["loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"],
            "authStatusDelayMs": 800,
        ])
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        try session.send("a turn the user stops")
        #expect(session.interrupt() == "req_1")
        let inbox = bed.config.workingDirectory.appendingPathComponent("fake-claude-inbox.log")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!FileManager.default.fileExists(atPath: inbox.path), "the stopped turn reached the CLI")
        #expect(collector.results().isEmpty)
        #expect(bed.handler.calls.isEmpty)

        try session.send("What is using my disk?")
        #expect(await collector.wait { !collector.results($0).isEmpty })
        #expect(collector.results().first?.subtype == "success")
        #expect(try String(contentsOf: inbox, encoding: .utf8) == "user\n")
        session.close()
        #expect(await collector.wait { $0.last == .processExited(status: 0) })
    }

    @Test func keyOriginNamesTheSetting() {
        #expect(SessionRefusal.apiKeyInUse(source: "apiKeyHelper").keyOrigin == .keyHelper)
        #expect(SessionRefusal.apiKeyInUse(source: "ANTHROPIC_API_KEY").keyOrigin == .environmentVariable)
        #expect(SessionRefusal.apiKeyInUse(source: "api_key").keyOrigin == .storedKey)
        #expect(SessionRefusal.apiKeyInUse(source: "something new").keyOrigin == .other("something new"))
    }

    @Test func authStatusParsingAndPolicy() {
        #expect(ClaudeAuthStatus(authMethod: "api_key_helper").disallowedKeySource == "apiKeyHelper")
        #expect(ClaudeAuthStatus(authMethod: "api_key_helper", apiKeySource: "none").disallowedKeySource == "apiKeyHelper")
        #expect(ClaudeAuthStatus(authMethod: "none").disallowedKeySource == nil)
        #expect(ClaudeAuthStatus(authMethod: "third_party").disallowedKeySource == nil)
        let oauth = ClaudeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty","configDirectory":"/x"}"#.utf8))
        #expect(oauth == ClaudeAuthStatus(loggedIn: true, authMethod: "oauth_token"))
        #expect(oauth?.disallowedKeySource == nil)
        #expect(ClaudeAuthStatus(authMethod: "claude.ai").disallowedKeySource == nil)
        #expect(ClaudeAuthStatus(authMethod: "api_key", apiKeySource: "/login managed key").disallowedKeySource == nil)
        #expect(ClaudeAuthStatus(authMethod: "api_key", apiKeySource: "ANTHROPIC_API_KEY").disallowedKeySource == "ANTHROPIC_API_KEY")
        #expect(ClaudeAuthStatus(authMethod: "api_key").disallowedKeySource == "api_key")
        #expect(ClaudeAuthStatus(authMethod: "oauth_token", apiKeySource: "apiKeyHelper").disallowedKeySource == "apiKeyHelper")
        #expect(ClaudeAuthStatus.parse(Data("[1]".utf8)) == nil)
        #expect(ClaudeAuthStatus.parse(Data("oops".utf8)) == nil)
        #expect(APIKeyPolicy.allows(keySource: "none"))
        #expect(APIKeyPolicy.allows(keySource: "/login managed key"))
        #expect(!APIKeyPolicy.allows(keySource: "ANTHROPIC_API_KEY"))
    }

    /// Gated live smoke against the real CLI (PLAN 5.2): `LIGHTWELL_LIVE_CLAUDE=1`, model haiku.
    /// Note: the CLI creates `~/.claude/projects/<cwd slug>/` for the fixture working directory.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTWELL_LIVE_CLAUDE"] == "1", "set LIGHTWELL_LIVE_CLAUDE=1"))
    func liveClaudeSmoke() async throws {
        let claude = try await ClaudeLocator.locate(override: nil)
        let bed = try SessionTestbed(
            claude: claude.url,
            model: "haiku",
            maxTurns: 10,
            knownPaths: { fx in
                [
                    try fx.file("Library/Developer/Xcode/DerivedData/Demo-abc/Build/x.o", size: 4096).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path: 2_400_000_000,
                    try fx.file("Library/Keychains/login.keychain-db", size: 1024).path: 1024,
                ]
            },
            protected: { fx in [fx.root.appendingPathComponent("Library/Keychains").path] },
            risks: { fx in [fx.root.appendingPathComponent("Library/Developer/Xcode/DerivedData").path: "safe"] }
        )
        defer { bed.tearDown() }
        let session = ClaudeSession(config: bed.config, thread: UUID(), resume: false, ipcServer: bed.server)
        let collector = EventCollector(session)
        try session.start()
        // Observe whether the CLI reports init before the first user message (input for the API key block).
        let initBeforeSend = await collector.wait(timeout: 3) { $0.contains { $0.kind == "initialized" } }
        try session.send("find safe things to clean")
        let done = await collector.wait(timeout: 180) { !collector.results($0).isEmpty }
        session.close()
        await collector.wait(timeout: 10) { _ in collector.finished }

        let info = collector.events.compactMap { if case .initialized(let i) = $0 { i } else { nil } }.first
        let result = collector.results().first
        let root = bed.fx.root.path
        let proposals = bed.handler.calls.filter { $0.name == "propose_deletion" }
        let proposedPaths = proposals.flatMap { call in
            (call.arguments["items"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }.compactMap { ToolPaths.expand($0, home: root) }
        }
        let toolTexts = collector.events.compactMap { if case .toolResult(_, let text, _) = $0 { text } else { nil } }
        let queued = toolTexts.compactMap { try? JSONDecoder().decode(ProposeDeletionResult.self, from: Data($0.utf8)) }.flatMap(\.queued).map(\.path)
        print("LIVE claude \(claude.version ?? "?"): init before first message = \(initBeforeSend), init disk status = \(info?.diskServerStatus ?? "none"), apiKeySource = \(info?.apiKeySource ?? "?"), result = \(result?.subtype ?? "none"), turns = \(result?.numTurns ?? 0), estimated cost USD = \(result?.totalCostUSD ?? -1), tool calls = \(bed.handler.calls.map(\.name)), queued = \(queued)")
        #expect(done)
        #expect(info?.isDiskServerConnected == true)
        #expect(result?.subtype == "success")
        #expect(!proposals.isEmpty)
        #expect(!proposedPaths.isEmpty && proposedPaths.allSatisfy { $0.hasPrefix(root + "/") })
        #expect(!queued.contains { $0.contains("Keychains") })
        #expect((result?.totalCostUSD ?? 1) < 0.10)
    }
}
