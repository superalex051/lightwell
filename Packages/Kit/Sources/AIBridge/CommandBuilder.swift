import Foundation
import IPCProtocol

/// Everything needed to spawn one assistant session.
public struct AssistantConfig: Sendable, Hashable {
    public var claude: ClaudeInstallation
    /// Working directory for the CLI process: `~/Library/Application Support/Lightwell/assistant/`
    /// (0700, app-owned). The per-session MCP config and the rendered system prompt live here too.
    public var workingDirectory: URL
    /// Helper binary written into the generated MCP config.
    public var helperURL: URL
    /// Socket of the app's `IPCServer`, passed to the helper as `--socket <path>`.
    public var socketPath: String
    public var model: String?
    public var maxTurns: Int?
    /// Spending cap per session in integer cents, converted for `--max-budget-usd` when building argv.
    public var maxBudgetCents: Int?
    /// Rendered system prompt (added). Defaults to `<workingDirectory>/system-prompt.md`.
    public var systemPromptURL: URL?
    /// Per-session MCP nonce (added). When nil, `ClaudeSession` generates a fresh random one.
    /// Never logged or shown; written only into the 0600 MCP config file.
    public var mcpNonce: String?
    /// Where the stderr log of each session is saved (added). Defaults to `<workingDirectory>/logs`.
    public var logDirectory: URL?
    /// Environment the child allowlist is taken from (added). Defaults to the app's own environment.
    public var baseEnvironment: [String: String]?
    /// Refuse the session when the CLI reports an API key (`system/init.apiKeySource` not "none")
    /// (added, PLAN 3.2b "Block API keys", default on).
    public var blockAPIKeys: Bool

    public init(claude: ClaudeInstallation, workingDirectory: URL, helperURL: URL, socketPath: String, model: String? = nil, maxTurns: Int? = nil, maxBudgetCents: Int? = nil, systemPromptURL: URL? = nil, mcpNonce: String? = nil, logDirectory: URL? = nil, baseEnvironment: [String: String]? = nil, blockAPIKeys: Bool = true) {
        self.blockAPIKeys = blockAPIKeys
        self.claude = claude
        self.workingDirectory = workingDirectory
        self.helperURL = helperURL
        self.socketPath = socketPath
        self.model = model
        self.maxTurns = maxTurns
        self.maxBudgetCents = maxBudgetCents
        self.systemPromptURL = systemPromptURL
        self.mcpNonce = mcpNonce
        self.logDirectory = logDirectory
        self.baseEnvironment = baseEnvironment
    }

    public var resolvedSystemPromptURL: URL {
        systemPromptURL ?? workingDirectory.appendingPathComponent(SystemPromptRenderer.fileName)
    }

    public var resolvedLogDirectory: URL {
        logDirectory ?? workingDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// `mcp-<thread>.json` inside the working directory.
    public func mcpConfigURL(thread: UUID) -> URL {
        MCPConfigWriter.configURL(directory: workingDirectory, thread: thread)
    }
}

/// Printing, dumping or a failed test expectation must never show the nonce or environment values.
extension AssistantConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AssistantConfig(claude: \(claude.url.path), workingDirectory: \(workingDirectory.path), helperURL: \(helperURL.path), socketPath: \(socketPath), model: \(model ?? "default"), maxTurns: \(maxTurns.map(String.init) ?? "default"), maxBudgetCents: \(maxBudgetCents.map(String.init) ?? "none"), mcpNonce: \(mcpNonce == nil ? "generated" : "<redacted>"), baseEnvironment: \(baseEnvironment.map { "\($0.count) variables" } ?? "app"), blockAPIKeys: \(blockAPIKeys))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "claude": claude.url.path,
            "workingDirectory": workingDirectory.path,
            "helperURL": helperURL.path,
            "socketPath": socketPath,
            "model": model ?? "default",
            "mcpNonce": mcpNonce == nil ? "generated" : "<redacted>",
            "blockAPIKeys": blockAPIKeys,
        ])
    }
}

/// A fully built CLI invocation.
public struct ClaudeCommand: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Builds the exact invocation of PLAN 3.3.
///
/// Never adds `--bare` (drops the OAuth login), `--safe-mode` (drops our MCP server) or
/// `--dangerously-skip-permissions`. No API key is ever passed.
public enum ClaudeCommandBuilder {
    public static let defaultModel = "sonnet"
    public static let defaultMaxTurns = 12
    /// Flags that must never appear in argv.
    public static let forbiddenFlags: Set<String> = ["--bare", "--safe-mode", "--dangerously-skip-permissions"]
    /// Variables copied from the app's environment; everything else (including `ANTHROPIC_*`) is dropped.
    public static let inheritedVariables = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"]
    public static let childPATH = "/usr/bin:/bin"

    /// CLI session id for a thread (the thread UUID, lowercased).
    public static func sessionID(for thread: UUID) -> String {
        thread.uuidString.lowercased()
    }

    public static func arguments(thread: UUID, resume: Bool, model: String?, maxTurns: Int?, maxBudgetCents: Int?, mcpConfigPath: String, systemPromptPath: String) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        arguments += resume ? ["--resume", sessionID(for: thread)] : ["--session-id", sessionID(for: thread)]
        let chosenModel = model.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        arguments += ["--model", chosenModel, "--max-turns", String(max(1, maxTurns ?? defaultMaxTurns))]
        if let maxBudgetCents, maxBudgetCents > 0 {
            arguments += ["--max-budget-usd", usdString(cents: maxBudgetCents)]
        }
        arguments += [
            "--setting-sources", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", mcpConfigPath,
            "--tools", "",
            "--allowedTools", ToolCatalog.allowedToolsArgument,
            "--permission-mode", "dontAsk",
            "--system-prompt-file", systemPromptPath,
        ]
        return arguments
    }

    public static func command(config: AssistantConfig, thread: UUID, resume: Bool) -> ClaudeCommand {
        ClaudeCommand(
            executable: config.claude.resolvedURL,
            arguments: arguments(
                thread: thread,
                resume: resume,
                model: config.model,
                maxTurns: config.maxTurns,
                maxBudgetCents: config.maxBudgetCents,
                mcpConfigPath: config.mcpConfigURL(thread: thread).path,
                systemPromptPath: config.resolvedSystemPromptURL.path
            ),
            environment: childEnvironment(from: config.baseEnvironment ?? ProcessInfo.processInfo.environment),
            workingDirectory: config.workingDirectory
        )
    }

    /// The scrubbed child environment: HOME, USER, LOGNAME, LANG, TMPDIR and `PATH=/usr/bin:/bin`.
    public static func childEnvironment(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var child: [String: String] = ["PATH": childPATH]
        for key in inheritedVariables {
            if let value = environment[key], !value.isEmpty { child[key] = value }
        }
        if child["HOME"] == nil { child["HOME"] = NSHomeDirectory() }
        return child
    }

    /// 150 -> "1.50".
    static func usdString(cents: Int) -> String {
        let remainder = cents % 100
        return "\(cents / 100).\(remainder < 10 ? "0" : "")\(remainder)"
    }
}
