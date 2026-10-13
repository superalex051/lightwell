import Foundation
import Synchronization

/// A located `claude` binary.
public struct ClaudeInstallation: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable {
        case override
        case knownPath
        case loginShell
    }

    /// Path as found (often the `~/.local/bin/claude` symlink). Resolved again at every spawn,
    /// because auto-update repoints the symlink to a new versioned binary.
    public var url: URL
    /// First word of `claude --version`, e.g. "2.1.296".
    public var version: String?
    public var source: Source

    public init(url: URL, version: String?, source: Source) {
        self.url = url
        self.version = version
        self.source = source
    }

    /// The binary to execute right now (symlinks resolved).
    public var resolvedURL: URL { url.resolvingSymlinksInPath() }
}

public enum ClaudeLocatorError: Error, Sendable, Hashable {
    case notFound
    case notExecutable(path: String)
}

/// Finds the claude CLI (PLAN 3.2). Frozen contract (PLAN 4.3): `locate(override:)`.
///
/// Order: user override, then the known install locations, then once per app run the login shell
/// (`/bin/zsh -l -c 'command -v claude'`, no `-i`, last stdout line, 5 s timeout).
public enum ClaudeLocator {
    /// Injectable file system and process access (tests use a temporary HOME and a mocked shell).
    public struct Environment: Sendable {
        public var home: String
        public var isExecutable: @Sendable (String) -> Bool
        /// Raw stdout of the login shell lookup, or nil when it failed or timed out.
        public var loginShellLookup: @Sendable () async -> String?
        /// Raw stdout of `<claude> --version`, or nil.
        public var versionProbe: @Sendable (URL) async -> String?

        public init(home: String, isExecutable: @escaping @Sendable (String) -> Bool, loginShellLookup: @escaping @Sendable () async -> String?, versionProbe: @escaping @Sendable (URL) async -> String?) {
            self.home = home
            self.isExecutable = isExecutable
            self.loginShellLookup = loginShellLookup
            self.versionProbe = versionProbe
        }

        /// The real Mac: the user's home, `FileManager`, a cached login shell lookup and a real version probe.
        public static var live: Environment {
            Environment(
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                loginShellLookup: { await LoginShellCache.shared.lookup() },
                versionProbe: { url in
                    await ProcessRunner.run(url, arguments: ["--version"], environment: ClaudeCommandBuilder.childEnvironment(), timeout: 5)?.stdout
                }
            )
        }
    }

    public static func locate(override: URL?) async throws -> ClaudeInstallation {
        try await locate(override: override, environment: .live)
    }

    public static func locate(override: URL?, environment: Environment) async throws -> ClaudeInstallation {
        if let override {
            let path = override.path
            guard environment.isExecutable(path) else { throw ClaudeLocatorError.notExecutable(path: path) }
            return await installation(URL(fileURLWithPath: path), source: .override, environment: environment)
        }
        for path in candidatePaths(home: environment.home) where environment.isExecutable(path) {
            return await installation(URL(fileURLWithPath: path), source: .knownPath, environment: environment)
        }
        if let output = await environment.loginShellLookup(),
           let path = parseLoginShellOutput(output),
           environment.isExecutable(path) {
            return await installation(URL(fileURLWithPath: path), source: .loginShell, environment: environment)
        }
        throw ClaudeLocatorError.notFound
    }

    /// Known install locations in priority order (PLAN 3.2 item 2).
    public static func candidatePaths(home: String) -> [String] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            "\(base)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(base)/.npm-global/bin/claude",
            "\(base)/.claude/local/claude",
        ]
    }

    /// Last non-empty stdout line of the shell lookup, if it is an absolute path.
    public static func parseLoginShellOutput(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let line, line.hasPrefix("/") else { return nil }
        return line
    }

    /// "2.1.296 (Claude Code)" -> "2.1.296".
    public static func parseVersion(_ output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let word = firstLine.split(separator: " ").first.map(String.init)
        guard let word, word.first?.isNumber == true else { return nil }
        return word
    }

    private static func installation(_ url: URL, source: ClaudeInstallation.Source, environment: Environment) async -> ClaudeInstallation {
        let version = await environment.versionProbe(url.resolvingSymlinksInPath()).flatMap(parseVersion)
        return ClaudeInstallation(url: url, version: version, source: source)
    }
}

/// Runs the login shell lookup at most once per app run.
actor LoginShellCache {
    static let shared = LoginShellCache()
    private var done = false
    private var cached: String?

    func lookup() async -> String? {
        if done { return cached }
        let output = await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", "command -v claude"],
            environment: ClaudeCommandBuilder.childEnvironment(),
            timeout: 5
        )
        done = true
        cached = output?.status == 0 ? output?.stdout : nil
        return cached
    }
}

/// Small helper to run a short-lived process with a timeout and collect its stdout.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
    }

    static func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval, workingDirectory: URL? = nil) async -> Output? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        struct Progress {
            var data = Data()
            var eof = false
            var status: Int32?
        }
        let progress = Mutex(Progress())
        let resumed = Mutex(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            @Sendable func finish(_ value: Output?) {
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            // Finishes once both stdout EOF and process exit were seen.
            @Sendable func update(_ change: (inout Progress) -> Void) {
                let output = progress.withLock { state -> Output? in
                    change(&state)
                    guard state.eof, let status = state.status else { return nil }
                    return Output(status: status, stdout: String(decoding: state.data, as: UTF8.self))
                }
                if let output { finish(output) }
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    update { $0.eof = true }
                } else {
                    update { $0.data.append(data) }
                }
            }
            process.terminationHandler = { process in
                let status = process.terminationStatus
                update { $0.status = status }
            }
            do {
                try process.run()
            } catch {
                finish(nil)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let pending = resumed.withLock { !$0 }
                if pending {
                    kill(pid, SIGKILL)
                    finish(nil)
                }
            }
        }
    }
}
