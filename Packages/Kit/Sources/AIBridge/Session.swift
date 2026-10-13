import Darwin
import Foundation
import IPCProtocol
import Synchronization

/// Handles tool calls arriving from the helper. Implemented by AppCore's ToolHandler. Frozen contract (PLAN 4.3).
public protocol AssistantToolHandler: Sendable {
    func handle(name: String, arguments: JSONValue, thread: UUID) async -> ToolCallResult
}

public enum AssistantSessionError: Error, Sendable, Hashable {
    case notStarted
    case alreadyStarted
    case processFailed(code: Int32)
    case notImplemented
    /// stdin is closed (the session ended or `close()` was called).
    case inputClosed
    case launchFailed(String)
    /// The session was refused (see `SessionRefusal`); nothing more can be sent.
    case refused(SessionRefusal)
}

/// Why a session was refused before any turn ran (added).
public enum SessionRefusal: Sendable, Hashable {
    /// `system/init.apiKeySource` was not "none" while `AssistantConfig.blockAPIKeys` is on: the CLI
    /// would bill an API key (environment variable or apiKeyHelper) instead of the user's login.
    case apiKeyInUse(source: String)

    /// Where the key comes from, so the UI card can name the setting (added).
    public var keyOrigin: APIKeyOrigin {
        switch self {
        case .apiKeyInUse(let source): APIKeyOrigin(source: source)
        }
    }
}

/// Origin of a refused API key, derived from the CLI's key source string (added). The UI maps each
/// case to its own localized text.
public enum APIKeyOrigin: Sendable, Hashable {
    /// `ANTHROPIC_API_KEY` in the environment.
    case environmentVariable
    /// An `apiKeyHelper` configured in Claude Code settings.
    case keyHelper
    /// An API key stored by the CLI itself (authentication method `api_key`).
    case storedKey
    /// Anything else the CLI reports; the raw source is kept for the Details view.
    case other(String)

    public init(source: String) {
        switch source {
        case "ANTHROPIC_API_KEY": self = .environmentVariable
        case "apiKeyHelper", "api_key_helper": self = .keyHelper
        case "api_key": self = .storedKey
        default: self = .other(source)
        }
    }
}

/// One long-lived `claude` process for a thread (PLAN 3.3 and 3.4). Frozen contract (PLAN 4.3).
///
/// `start()` writes the 0600 MCP config (`mcp-<thread>.json`) with the session nonce, then spawns the
/// CLI with the exact argv of `ClaudeCommandBuilder` and the scrubbed environment. stdout is parsed
/// into `events`; stderr goes to a 256 KB ring buffer saved to `logs/<thread>.log` when the process
/// ends. The last event is always `.processExited(status:)`, then the stream finishes. The MCP config
/// is deleted and the nonce unregistered when the process ends.
///
/// API key block (`config.blockAPIKeys`, default on), in two layers:
/// 1. Pre-check before any turn: `start()` runs `<claude> auth status --json` once (same scrubbed
///    environment and folder, 5 s timeout). Messages sent meanwhile are held back, so the CLI receives
///    none until the check passes. A disallowed key source (see `APIKeyPolicy`) emits
///    `.refused(.apiKeyInUse)` and ends the session without the CLI ever seeing a user message.
///    An unparseable or failed check does not block (the backstop still applies).
/// 2. Backstop: the first `.initialized` whose `apiKeySource` is not allowed is followed by
///    `.refused(.apiKeyInUse)`. Either way every later parsed event is dropped, the nonce is
///    unregistered, the session interrupts, closes stdin and terminates the CLI, and `send` throws
///    `.refused`.
///
/// Releasing a running session is safe: `deinit` closes stdin (SIGTERM after 3 s); the process and
/// its pipes are owned by an internal core that cleans up (config file, nonce, handlers) when the
/// process ends.
public final class ClaudeSession: Sendable {
    public static let stderrCapacity = 256 * 1024

    public let config: AssistantConfig
    public let thread: UUID
    public let resume: Bool
    public let events: AsyncStream<StreamEvent>
    /// Per-session nonce for the helper (added). Keep in memory only: never log or display it.
    public let mcpNonce: String
    let core: SessionCore

    public convenience init(config: AssistantConfig, thread: UUID, resume: Bool) {
        self.init(config: config, thread: thread, resume: resume, server: nil)
    }

    /// Same as the frozen initializer, plus automatic `register`/`unregister` of the nonce on
    /// `ipcServer` (added).
    public convenience init(config: AssistantConfig, thread: UUID, resume: Bool, ipcServer: IPCServer) {
        self.init(config: config, thread: thread, resume: resume, server: ipcServer)
    }

    private init(config: AssistantConfig, thread: UUID, resume: Bool, server: IPCServer?) {
        self.config = config
        self.thread = thread
        self.resume = resume
        let nonce = config.mcpNonce ?? MCPConfigWriter.makeNonce()
        self.mcpNonce = nonce
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.events = stream
        self.core = SessionCore(config: config, thread: thread, resume: resume, nonce: nonce, ipcServer: server, continuation: continuation)
    }

    deinit {
        core.abandon()
    }

    /// The command `start()` runs (argv golden tests, Settings "Details").
    public var command: ClaudeCommand { core.command }
    public var mcpConfigURL: URL { core.mcpConfigURL }
    /// `logs/<thread>.log`, written when the process ends.
    public var logURL: URL { core.logURL }
    public var isRunning: Bool { core.isRunning }
    /// Exit status once the process has ended.
    public var exitStatus: Int32? { core.exitStatus }
    /// The refusal, if the session was refused.
    public var refusal: SessionRefusal? { core.refusal }
    /// Recent stderr output (nonce redacted), for the "Details" disclosure.
    public var stderrTail: String { core.stderrTail }

    public func start() throws { try core.start() }

    /// Sends one user message.
    public func send(_ text: String) throws { try core.send(text) }

    /// Asks the CLI to stop the current turn. Expect `.controlResponse` and a `result` with subtype
    /// `error_during_execution`. Returns the request id (`req_<n>`), or nil when stdin is closed.
    @discardableResult
    public func interrupt() -> String? { core.interrupt() }

    /// Closes stdin: the CLI finishes the current turn and exits cleanly.
    public func close() { core.close() }

    /// App quit (added): interrupt, close stdin, SIGTERM after `grace` seconds if still running.
    public func shutdown(grace: TimeInterval = 3) { core.shutdown(grace: grace) }
}

/// Owns the process, pipes and parser. Its pipe and termination handlers retain it until the process
/// has ended and `complete()` has cleared them, so it outlives a released `ClaudeSession`.
final class SessionCore: Sendable {
    let config: AssistantConfig
    let thread: UUID
    let resume: Bool
    let mcpNonce: String
    private let ipcServer: IPCServer?
    private let continuation: AsyncStream<StreamEvent>.Continuation

    private struct State {
        var started = false
        var finished = false
        var process: Process?
        var stdin: FileHandle?
        var stdout: FileHandle?
        var stderrHandle: FileHandle?
        var parser = StreamJSONParser()
        var stderr = Data()
        var stderrDropped = false
        var nextRequest = 1
        var pendingEOF = 2
        var exitStatus: Int32?
        var refusal: SessionRefusal?
        /// API key pre-check: messages wait in `held` until it passes.
        var preCheck: PreCheck = .pending
        var held: [Data] = []
    }

    enum PreCheck: Sendable {
        case pending
        case passed
        case refused
    }

    private let state = Mutex(State())
    /// Serializes every stdin write (and the release of held messages) so message order is kept.
    private let writeLock = Mutex(())

    init(config: AssistantConfig, thread: UUID, resume: Bool, nonce: String, ipcServer: IPCServer?, continuation: AsyncStream<StreamEvent>.Continuation) {
        self.config = config
        self.thread = thread
        self.resume = resume
        self.mcpNonce = nonce
        self.ipcServer = ipcServer
        self.continuation = continuation
    }

    var command: ClaudeCommand {
        ClaudeCommandBuilder.command(config: config, thread: thread, resume: resume)
    }

    var mcpConfigURL: URL { config.mcpConfigURL(thread: thread) }

    var logURL: URL {
        config.resolvedLogDirectory.appendingPathComponent("\(thread.uuidString.lowercased()).log")
    }

    var isRunning: Bool { state.withLock { $0.process?.isRunning ?? false } }
    var exitStatus: Int32? { state.withLock { $0.exitStatus } }
    var refusal: SessionRefusal? { state.withLock { $0.refusal } }

    var stderrTail: String {
        let data = state.withLock { $0.stderr }
        return redact(String(decoding: data, as: UTF8.self))
    }

    func start() throws {
        try state.withLock { state in
            guard !state.started else { throw AssistantSessionError.alreadyStarted }
            state.started = true
        }
        do {
            try launch()
            if config.blockAPIKeys {
                Task.detached { [self] in await runPreCheck() }
            } else {
                state.withLock { $0.preCheck = .passed }
            }
        } catch {
            state.withLock { $0.finished = true }
            MCPConfigWriter.remove(at: mcpConfigURL)
            ipcServer?.unregister(nonce: mcpNonce)
            continuation.finish()
            throw error
        }
    }

    private func launch() throws {
        try SecureFile.ensureDirectory(config.workingDirectory)
        try MCPConfigWriter.write(to: mcpConfigURL, helperURL: config.helperURL, socketPath: config.socketPath, nonce: mcpNonce)
        ipcServer?.register(nonce: mcpNonce, thread: thread)

        let command = self.command
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Writing to a dead child must fail with EPIPE instead of killing the app.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // The handlers capture the core strongly on purpose (see the type comment). EOF clears the
        // handler first, so a finished pipe can never keep firing.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finishStream(stdout: true)
            } else {
                deliver(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finishStream(stdout: false)
            } else {
                state.withLock { state in
                    state.stderr.append(data)
                    if state.stderr.count > ClaudeSession.stderrCapacity {
                        state.stderr.removeFirst(state.stderr.count - ClaudeSession.stderrCapacity)
                        state.stderrDropped = true
                    }
                }
            }
        }
        process.terminationHandler = { [self] process in
            processEnded(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw AssistantSessionError.launchFailed(String(describing: error))
        }
        state.withLock { state in
            state.process = process
            state.stdin = stdinPipe.fileHandleForWriting
            state.stdout = stdoutPipe.fileHandleForReading
            state.stderrHandle = stderrPipe.fileHandleForReading
        }
    }

    /// Parses stdout and applies the API key block.
    private func deliver(_ data: Data) {
        let (events, refusal) = state.withLock { state -> ([StreamEvent], SessionRefusal?) in
            var output: [StreamEvent] = []
            var refusal: SessionRefusal?
            for event in state.parser.feed(data) {
                guard state.refusal == nil else { continue }
                output.append(event)
                if config.blockAPIKeys, case .initialized(let info) = event,
                   let source = info.apiKeySource, !APIKeyPolicy.allows(keySource: source) {
                    let reason = SessionRefusal.apiKeyInUse(source: source)
                    state.refusal = reason
                    refusal = reason
                    output.append(.refused(reason))
                }
            }
            return (output, refusal)
        }
        for event in events { continuation.yield(event) }
        if refusal != nil { stopAfterRefusal() }
    }

    /// Refused: the helper loses access right away (no scan data for a key-billed session), the turn
    /// is interrupted, stdin closed, and the CLI terminated shortly after.
    private func stopAfterRefusal() {
        ipcServer?.unregister(nonce: mcpNonce)
        _ = interrupt()
        close()
        let pid = state.withLock { $0.process?.processIdentifier }
        guard let pid, pid > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
            if isRunning { kill(pid, SIGTERM) }
        }
    }

    func send(_ text: String) throws {
        if let refusal { throw AssistantSessionError.refused(refusal) }
        let message: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": .string(text)]]],
        ]
        let data = try Self.line(message)
        try writeLock.withLock { _ in
            let held = try state.withLock { state -> Bool in
                guard state.started else { throw AssistantSessionError.notStarted }
                if let refusal = state.refusal { throw AssistantSessionError.refused(refusal) }
                guard state.preCheck == .pending else { return false }
                guard state.stdin != nil, !state.finished else { throw AssistantSessionError.inputClosed }
                state.held.append(data)
                return true
            }
            if !held { try writeData(data) }
        }
    }

    /// `auth status --json` before the first turn. Refuses on a disallowed key source; otherwise
    /// releases the held messages in order.
    private func runPreCheck() async {
        let status = await ClaudeAuthStatus.fetch(
            claude: config.claude.resolvedURL,
            environment: command.environment,
            workingDirectory: config.workingDirectory
        )
        if let source = status?.disallowedKeySource {
            let reason = SessionRefusal.apiKeyInUse(source: source)
            let first = state.withLock { state -> Bool in
                state.preCheck = .refused
                state.held.removeAll()
                guard state.refusal == nil else { return false }
                state.refusal = reason
                return true
            }
            if first {
                continuation.yield(.refused(reason))
                stopAfterRefusal()
            }
            return
        }
        writeLock.withLock { _ in
            let held = state.withLock { state -> [Data] in
                state.preCheck = .passed
                defer { state.held.removeAll() }
                return state.held
            }
            for data in held { try? writeData(data) }
        }
    }

    func interrupt() -> String? {
        let id = state.withLock { "req_\($0.nextRequest)" }
        let request: JSONValue = ["type": "control_request", "request_id": .string(id), "request": ["subtype": "interrupt"]]
        do {
            let data = try Self.line(request)
            try writeLock.withLock { _ in
                // A message still held by the API key pre-check is a turn the user just stopped: drop it.
                state.withLock { state in
                    if state.preCheck == .pending { state.held.removeAll() }
                }
                try writeData(data)
            }
            state.withLock { $0.nextRequest += 1 }
            return id
        } catch {
            return nil
        }
    }

    func close() {
        let handle = state.withLock { state -> FileHandle? in
            defer { state.stdin = nil }
            return state.stdin
        }
        try? handle?.close()
        let notStarted = state.withLock { state -> Bool in
            guard !state.started, !state.finished else { return false }
            state.finished = true
            return true
        }
        if notStarted { continuation.finish() }
    }

    func shutdown(grace: TimeInterval) {
        if isRunning { _ = interrupt() }
        close()
        let pid = state.withLock { $0.process?.processIdentifier }
        guard let pid, pid > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if isRunning { kill(pid, SIGTERM) }
        }
    }

    /// The public session was released: end the process if it is still running.
    func abandon() {
        let running = state.withLock { $0.started && !$0.finished }
        if running {
            shutdown(grace: 3)
        } else {
            close()
        }
    }

    // MARK: - Private

    private static func line(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    /// Call with `writeLock` held.
    private func writeData(_ data: Data) throws {
        let handle = try state.withLock { state -> FileHandle in
            guard state.started else { throw AssistantSessionError.notStarted }
            guard let stdin = state.stdin, !state.finished else { throw AssistantSessionError.inputClosed }
            return stdin
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw AssistantSessionError.inputClosed
        }
    }

    private func finishStream(stdout: Bool) {
        if stdout {
            let rest = state.withLock { state -> [StreamEvent] in
                let events = state.parser.finish()
                return state.refusal == nil ? events : []
            }
            for event in rest { continuation.yield(event) }
        }
        let done = state.withLock { state -> Bool in
            state.pendingEOF -= 1
            return state.pendingEOF <= 0 && state.exitStatus != nil
        }
        if done { complete() }
    }

    private func processEnded(status: Int32) {
        let done = state.withLock { state -> Bool in
            state.exitStatus = status
            return state.pendingEOF <= 0
        }
        if done {
            complete()
        } else {
            // A grandchild may keep a pipe open (for example a helper that outlives the CLI); do not
            // wait for it forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in complete() }
        }
    }

    private func complete() {
        let snapshot = state.withLock { state -> (status: Int32, stderr: Data, dropped: Bool)? in
            guard !state.finished, let status = state.exitStatus else { return nil }
            state.finished = true
            state.stdin = nil
            // Break the retain cycle core -> process/pipes -> handlers -> core.
            state.stdout?.readabilityHandler = nil
            state.stderrHandle?.readabilityHandler = nil
            state.process?.terminationHandler = nil
            state.stdout = nil
            state.stderrHandle = nil
            state.process = nil
            return (status, state.stderr, state.stderrDropped)
        }
        guard let (status, stderr, dropped) = snapshot else { return }
        MCPConfigWriter.remove(at: mcpConfigURL)
        ipcServer?.unregister(nonce: mcpNonce)
        saveLog(stderr, dropped: dropped)
        continuation.yield(.processExited(status: status))
        continuation.finish()
    }

    private func saveLog(_ data: Data, dropped: Bool) {
        guard !data.isEmpty else { return }
        var text = redact(String(decoding: data, as: UTF8.self))
        if dropped { text = "[earlier output dropped]\n" + text }
        try? SecureFile.ensureDirectory(config.resolvedLogDirectory)
        try? SecureFile.write(Data(text.utf8), to: logURL)
    }

    private func redact(_ text: String) -> String {
        text.replacingOccurrences(of: mcpNonce, with: "<redacted>")
    }
}
