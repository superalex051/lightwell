import Darwin
import Foundation
import IPCProtocol
import Testing
import TestSupport
@testable import AIBridge

func posixMode(_ path: String) -> mode_t {
    var st = stat()
    guard lstat(path, &st) == 0 else { return 0 }
    return st.st_mode & 0o777
}

@Suite("Command builder")
struct CommandBuilderTests {
    static let thread = UUID(uuidString: "2B9C1F8E-0000-4000-8000-00000000ABCD")!

    func config(model: String? = nil, budget: Int? = nil) -> AssistantConfig {
        AssistantConfig(
            claude: ClaudeInstallation(url: URL(fileURLWithPath: "/opt/claude/bin/claude"), version: "2.1.296", source: .knownPath),
            workingDirectory: URL(fileURLWithPath: "/Users/u/Library/Application Support/Lightwell/assistant"),
            helperURL: URL(fileURLWithPath: "/Applications/Lightwell.app/Contents/Helpers/lightwell-mcp"),
            socketPath: "/Users/u/Library/Application Support/Lightwell/ipc/s-1.sock",
            model: model,
            maxBudgetCents: budget,
            baseEnvironment: [
                "HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "LANG": "en_US.UTF-8", "TMPDIR": "/var/folders/x/T/",
                "PATH": "/opt/homebrew/bin:/usr/bin", "SHELL": "/bin/zsh", "ANTHROPIC_BASE_URL": "https://example.invalid",
                "SECRET_TOKEN": "x", "LIGHTWELL_MCP_NONCE": "should-not-pass",
            ]
        )
    }

    @Test func goldenArgvNewThread() {
        let command = ClaudeCommandBuilder.command(config: config(), thread: Self.thread, resume: false)
        #expect(command.executable.path == "/opt/claude/bin/claude")
        #expect(command.workingDirectory.path == "/Users/u/Library/Application Support/Lightwell/assistant")
        #expect(command.arguments == [
            "-p",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--session-id", "2b9c1f8e-0000-4000-8000-00000000abcd",
            "--model", "sonnet", "--max-turns", "12",
            "--setting-sources", "", "--disable-slash-commands",
            "--strict-mcp-config", "--mcp-config", "/Users/u/Library/Application Support/Lightwell/assistant/mcp-2b9c1f8e-0000-4000-8000-00000000abcd.json",
            "--tools", "",
            "--allowedTools", "mcp__disk__get_disk_overview mcp__disk__get_largest_items mcp__disk__list_children mcp__disk__get_category_summary mcp__disk__inspect_path mcp__disk__search_items mcp__disk__get_cleanup_queue mcp__disk__propose_deletion",
            "--permission-mode", "dontAsk",
            "--system-prompt-file", "/Users/u/Library/Application Support/Lightwell/assistant/system-prompt.md",
        ])
    }

    @Test func goldenArgvResumeWithModelAndBudget() {
        let arguments = ClaudeCommandBuilder.command(config: config(model: "haiku", budget: 150), thread: Self.thread, resume: true).arguments
        #expect(Array(arguments[7...14]) == ["--resume", "2b9c1f8e-0000-4000-8000-00000000abcd", "--model", "haiku", "--max-turns", "12", "--max-budget-usd", "1.50"])
        #expect(!arguments.contains("--session-id"))
        #expect(ClaudeCommandBuilder.usdString(cents: 5) == "0.05")
        #expect(ClaudeCommandBuilder.usdString(cents: 1200) == "12.00")
    }

    @Test func neverForbiddenFlags() {
        for resume in [false, true] {
            let arguments = ClaudeCommandBuilder.command(config: config(budget: 100), thread: Self.thread, resume: resume).arguments
            #expect(ClaudeCommandBuilder.forbiddenFlags.isDisjoint(with: arguments))
            #expect(!arguments.contains { $0.localizedCaseInsensitiveContains("api-key") || $0.localizedCaseInsensitiveContains("apikey") })
        }
    }

    @Test func environmentIsScrubbed() {
        let environment = ClaudeCommandBuilder.command(config: config(), thread: Self.thread, resume: false).environment
        #expect(environment == [
            "HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "LANG": "en_US.UTF-8", "TMPDIR": "/var/folders/x/T/", "PATH": "/usr/bin:/bin",
        ])
    }

    @Test func symlinkResolvedAtSpawn() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let real = try fx.file("versions/9.9.9", size: 16)
        chmod(real.path, 0o755)
        let link = try fx.symlink("bin/claude", to: real.path)
        var c = config()
        c.claude = ClaudeInstallation(url: link, version: nil, source: .knownPath)
        #expect(ClaudeCommandBuilder.command(config: c, thread: Self.thread, resume: false).executable.path == real.resolvingSymlinksInPath().path)
    }
}

@Suite("Claude locator")
struct ClaudeLocatorTests {
    static func environment(home: String, executables: Set<String>, shell: String? = nil) -> ClaudeLocator.Environment {
        ClaudeLocator.Environment(
            home: home,
            isExecutable: { executables.contains($0) },
            loginShellLookup: { shell },
            versionProbe: { _ in "2.1.296 (Claude Code)\n" }
        )
    }

    @Test func overrideWins() async throws {
        let env = Self.environment(home: "/h", executables: ["/custom/claude", "/h/.local/bin/claude"])
        let found = try await ClaudeLocator.locate(override: URL(fileURLWithPath: "/custom/claude"), environment: env)
        #expect(found == ClaudeInstallation(url: URL(fileURLWithPath: "/custom/claude"), version: "2.1.296", source: .override))
        await #expect(throws: ClaudeLocatorError.notExecutable(path: "/missing")) {
            try await ClaudeLocator.locate(override: URL(fileURLWithPath: "/missing"), environment: env)
        }
    }

    @Test func knownPathsInOrder() async throws {
        #expect(ClaudeLocator.candidatePaths(home: "/h/") == [
            "/h/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/h/.npm-global/bin/claude", "/h/.claude/local/claude",
        ])
        let brew = try await ClaudeLocator.locate(override: nil, environment: Self.environment(home: "/h", executables: ["/opt/homebrew/bin/claude", "/h/.claude/local/claude"]))
        #expect(brew.url.path == "/opt/homebrew/bin/claude")
        #expect(brew.source == .knownPath)
    }

    @Test func realFilesInTemporaryHome() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let script = try fx.file("home/.npm-global/bin/claude", size: 0)
        try Data("#!/bin/sh\necho '3.4.5 (Claude Code)'\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        let env = ClaudeLocator.Environment(
            home: fx.root.appendingPathComponent("home").path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) && !$0.hasPrefix("/opt") && !$0.hasPrefix("/usr") },
            loginShellLookup: { nil },
            versionProbe: ClaudeLocator.Environment.live.versionProbe
        )
        let found = try await ClaudeLocator.locate(override: nil, environment: env)
        #expect(found.url.path == script.path)
        #expect(found.version == "3.4.5")
    }

    @Test func loginShellFallback() async throws {
        let shellOutput = "Welcome banner\n/Users/h/.volta/bin/claude\n\n"
        let found = try await ClaudeLocator.locate(override: nil, environment: Self.environment(home: "/h", executables: ["/Users/h/.volta/bin/claude"], shell: shellOutput))
        #expect(found.url.path == "/Users/h/.volta/bin/claude")
        #expect(found.source == .loginShell)
        #expect(ClaudeLocator.parseLoginShellOutput("claude: aliased to foo\n") == nil)
        await #expect(throws: ClaudeLocatorError.notFound) {
            try await ClaudeLocator.locate(override: nil, environment: Self.environment(home: "/h", executables: [], shell: "/nope/claude\n"))
        }
    }

    @Test func versionParsing() {
        #expect(ClaudeLocator.parseVersion("2.1.296 (Claude Code)\n") == "2.1.296")
        #expect(ClaudeLocator.parseVersion("error: something\n") == nil)
        #expect(ClaudeLocator.parseVersion("") == nil)
    }
}

@Suite("Assistant files")
struct AssistantFileTests {
    @Test func mcpConfigIsPrivateAndExact() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let nonce = MCPConfigWriter.makeNonce()
        #expect(nonce.count == 64)
        #expect(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(MCPConfigWriter.makeNonce() != nonce)
        let thread = UUID()
        let url = MCPConfigWriter.configURL(directory: fx.root.appendingPathComponent("assistant"), thread: thread)
        try MCPConfigWriter.write(to: url, helperURL: URL(fileURLWithPath: "/A b/lightwell-mcp"), socketPath: "/s.sock", nonce: nonce)
        #expect(posixMode(url.path) == 0o600)
        #expect(posixMode(url.deletingLastPathComponent().path) == 0o700)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        #expect(json == [
            "mcpServers": ["disk": [
                "type": "stdio",
                "command": "/A b/lightwell-mcp",
                "args": ["--socket", "/s.sock"],
                "env": ["LIGHTWELL_MCP_NONCE": .string(nonce)],
            ]],
        ])
        #expect(url.lastPathComponent == "mcp-\(thread.uuidString.lowercased()).json")
        MCPConfigWriter.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    static var templateURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/assistant-system-prompt.md")
    }

    @Test func bundledPromptRenders() throws {
        let template = try String(contentsOf: Self.templateURL, encoding: .utf8)
        #expect(Set(SystemPromptRenderer.unresolvedPlaceholders(in: template)) == ["scanAge", "scannedRoot"])
        let rendered = SystemPromptRenderer.render(template: template, scanAgeSeconds: 7200, scannedRoot: "/")
        #expect(SystemPromptRenderer.unresolvedPlaceholders(in: rendered).isEmpty)
        #expect(rendered.contains("2 hours old"))
        #expect(!rendered.contains("\u{2013}") && !rendered.contains("\u{2014}"))
        for tool in ToolCatalog.all where tool.name != "list_children" && tool.name != "search_items" && tool.name != "get_cleanup_queue" {
            #expect(rendered.contains(tool.name), "\(tool.name)")
        }
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let url = try SystemPromptRenderer.write(rendered, to: fx.root.appendingPathComponent("assistant/system-prompt.md"))
        #expect(posixMode(url.path) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == rendered)
    }

    @Test func scanAgeWords() {
        #expect(SystemPromptRenderer.describeScanAge(seconds: nil) == "no scan yet")
        #expect(SystemPromptRenderer.describeScanAge(seconds: 5) == "less than a minute")
        #expect(SystemPromptRenderer.describeScanAge(seconds: 60) == "1 minute")
        #expect(SystemPromptRenderer.describeScanAge(seconds: 3 * 86_400) == "3 days")
    }

    @Test func threadStorePersistsUsage() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let directory = fx.root.appendingPathComponent("assistant")
        let store = ThreadStore(directory: directory)
        #expect(store.threads.isEmpty)
        let record = try store.createThread(firstMessage: "  What is   taking all the space\non my Mac these days? I need room for a big project", model: "sonnet", now: Date(timeIntervalSince1970: 1000))
        #expect(record.title == "What is taking all the space on my Mac these days? I need...")
        #expect(record.sessionID == record.id.uuidString.lowercased())
        let usage = TokenUsage(inputTokens: 6, outputTokens: 423, cacheReadInputTokens: 5972, cacheCreationInputTokens: 3285)
        try store.recordTurn(thread: record.id, result: TurnResult(subtype: "success", isError: false, usage: usage, totalCostUSD: 0.0130517), now: Date(timeIntervalSince1970: 2000))
        try store.recordTurn(thread: record.id, result: TurnResult(subtype: "success", isError: false, usage: usage, totalCostUSD: 0.0130517), now: Date(timeIntervalSince1970: 3000))
        #expect(posixMode(store.fileURL.path) == 0o600)

        let reloaded = ThreadStore(directory: directory)
        let thread = try #require(reloaded.thread(record.id))
        #expect(thread.inputTokens == 2 * (6 + 5972 + 3285))
        #expect(thread.outputTokens == 846)
        #expect(thread.estimatedCostMicros == 26_104)
        #expect(thread.estimatedCostCents == 3)
        #expect(thread.turns == 2)
        #expect(thread.model == "sonnet")
        #expect(thread.updatedAt == Date(timeIntervalSince1970: 3000))
        try reloaded.remove(record.id)
        #expect(ThreadStore(directory: directory).threads.isEmpty)
    }

    @Test func concurrentTurnsAreNeverLost() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let directory = fx.root.appendingPathComponent("assistant")
        let store = ThreadStore(directory: directory)
        let record = try store.createThread(firstMessage: "hi", model: nil)
        let turn = TurnResult(subtype: "success", isError: false, usage: TokenUsage(inputTokens: 1, outputTokens: 2), totalCostUSD: 0.000001)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask { _ = try? store.recordTurn(thread: record.id, result: turn) }
            }
        }
        let saved = try #require(ThreadStore(directory: directory).thread(record.id))
        #expect(saved.turns == 40)
        #expect(saved.outputTokens == 80)
        #expect(saved.estimatedCostMicros == 40)
    }

    @Test func threadRecordDecodesOlderFiles() throws {
        let json = #"{"id":"2B9C1F8E-0000-4000-8000-00000000ABCD","title":"Old","createdAt":"2026-10-01T10:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ThreadRecord.self, from: Data(json.utf8))
        #expect(record.updatedAt == record.createdAt)
        #expect(record.turns == 0)
    }
}
