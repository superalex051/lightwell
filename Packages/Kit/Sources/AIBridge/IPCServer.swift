import Darwin
import Foundation
import IPCProtocol
import os
import Synchronization

/// Why a helper connection was closed. Only these codes are ever logged.
public enum IPCRejection: String, Sendable, Hashable {
    /// `LOCAL_PEERTOKEN` could not be read.
    case peerTokenUnavailable
    /// The peer's code signature does not satisfy the policy (unsigned, wrong identifier, wrong team or cdhash).
    case peerUnverified
    /// No usable peer policy (for example the bundled helper is missing).
    case policyUnavailable
    /// The first message was not a `hello`.
    case notHello
    /// `hello` carried a nonce that belongs to no live session.
    case badNonce
    /// `hello` asked for another protocol version.
    case protocolMismatch
    /// Unreadable JSON or a line over 1 MiB before `hello`.
    case malformed
    /// The peer disconnected or timed out before `hello`.
    case closedBeforeHello
    /// Too many connections were already waiting for verification.
    case tooManyPending
}

public enum IPCServerError: Error, Sendable, Hashable {
    case alreadyStarted
    case socketPathTooLong(path: String)
    case socket(errno: Int32)
    case bind(errno: Int32)
    case listen(errno: Int32)
    case peerPolicyUnavailable
}

/// Unix socket server the helper connects to (PLAN 3.6). Frozen contract (PLAN 4.3).
///
/// - Socket `<directory>/s-<pid>.sock` (directory 0700, socket 0600); when that path would exceed the
///   103 byte `sun_path` limit, `$TMPDIR/lightwell-<pid>.sock`. A second server in the same process
///   gets a `-<n>` suffix.
/// - On accept, before reading anything: `LOCAL_PEERTOKEN` audit token, then
///   `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` against the peer policy.
/// - The first message must be `hello` with the nonce of a registered session; it maps the connection
///   to that thread. Then `callTool` and `ping`. Any failure closes the connection silently and records
///   an `IPCRejection` code.
public final class IPCServer: Sendable {
    public let directory: URL
    public let handler: any AssistantToolHandler
    public let socketPath: String
    public let peerPolicy: PeerPolicy

    private struct State {
        var started = false
        var stopped = false
        var listenFD: Int32 = -1
        var source: (any DispatchSourceRead)?
        var clients: Set<Int32> = []
        var requirement: String?
        var rejections: [IPCRejection] = []
        var accepted = 0
        /// Connections not yet past peer verification and `hello`.
        var pending = 0
    }

    private let state = Mutex(State())
    private let nonces = Mutex<[String: UUID]>([:])
    private let queue = DispatchQueue(label: "com.alexluncan.lightwell.ipc.accept")
    private static let logger = Logger(subsystem: "com.alexluncan.lightwell", category: "ipc")
    private static let instanceCounter = Atomic<Int>(0)
    /// Seconds a peer has to send `hello`.
    static let helloTimeout = 10
    /// Most connections that may wait for verification at once; more are closed on accept.
    static let maxPendingConnections = 8

    /// Frozen initializer: the peer policy is `.automatic` for the helper bundled in the running app
    /// (`Contents/Helpers/lightwell-mcp`).
    public convenience init(directory: URL, handler: any AssistantToolHandler) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lightwell-mcp")
        self.init(directory: directory, handler: handler, peerPolicy: .automatic(helperURL: helper))
    }

    /// Initializer with an explicit peer policy (added).
    public init(directory: URL, handler: any AssistantToolHandler, peerPolicy: PeerPolicy) {
        self.directory = directory
        self.handler = handler
        self.peerPolicy = peerPolicy
        let index = Self.instanceCounter.add(1, ordering: .relaxed).oldValue
        self.socketPath = Self.socketPath(directory: directory, pid: getpid(), index: index)
    }

    /// Socket path rule (PLAN 3.6), with a per-process index for additional servers.
    static func socketPath(directory: URL, pid: Int32, index: Int) -> String {
        let suffix = index == 0 ? "" : "-\(index)"
        let primary = directory.appendingPathComponent("s-\(pid)\(suffix).sock").path
        if primary.utf8.count <= 103 { return primary }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("lightwell-\(pid)\(suffix).sock")
    }

    deinit {
        let started = state.withLock { $0.started && !$0.stopped }
        if started { stop() }
    }

    public func start() throws {
        let alreadyStarted = state.withLock { $0.started }
        if alreadyStarted { throw IPCServerError.alreadyStarted }
        guard let requirement = PeerVerifier.requirementString(for: peerPolicy), PeerVerifier.compile(requirement) != nil else {
            throw IPCServerError.peerPolicyUnavailable
        }
        let pathBytes = Array(socketPath.utf8)
        let address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw IPCServerError.socketPathTooLong(path: socketPath)
        }
        try SecureFile.ensureDirectory(directory)
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        if socketDirectory == directory.path { chmod(socketDirectory, 0o700) }
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCServerError.socket(errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // The node must never be reachable while wider than 0600. umask is process wide (changing it
        // races with other threads), so bind inside a fresh 0700 staging folder, chmod, then rename
        // the node into place. Without room for the staging path, bind in place: the socket folder
        // is 0700 (or the per-user TMPDIR) anyway.
        let stage = socketDirectory + "/.lw-" + String(UUID().uuidString.prefix(6))
        let stagePath = stage + "/s"
        let staged = stagePath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) && mkdir(stage, 0o700) == 0
        let bindPath = staged ? stagePath : socketPath
        defer { if staged { rmdir(stage) } }
        guard Self.bind(fd, path: bindPath) == 0 else {
            let error = errno
            close(fd)
            throw IPCServerError.bind(errno: error)
        }
        chmod(bindPath, 0o600)
        if staged, rename(stagePath, socketPath) != 0 {
            let error = errno
            close(fd)
            unlink(stagePath)
            throw IPCServerError.bind(errno: error)
        }
        guard listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            unlink(socketPath)
            throw IPCServerError.listen(errno: error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        state.withLock {
            $0.started = true
            $0.listenFD = fd
            $0.requirement = requirement
            $0.source = source
        }
        source.resume()
    }

    private static func bind(_ fd: Int32, path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Maps a live session's nonce to its thread. Never log the nonce.
    public func register(nonce: String, thread: UUID) {
        nonces.withLock { $0[nonce] = thread }
    }

    /// Forgets a session's nonce (added). Existing connections keep working.
    public func unregister(nonce: String) {
        _ = nonces.withLock { $0.removeValue(forKey: nonce) }
    }

    public func stop() {
        // Client fds are shut down under the lock; connections close their fd under the same lock, so
        // a number reused by an unrelated socket is never touched.
        let source = state.withLock { state -> (any DispatchSourceRead)? in
            state.stopped = true
            for fd in state.clients { shutdown(fd, SHUT_RDWR) }
            let source = state.source
            state.source = nil
            state.listenFD = -1
            return source
        }
        source?.cancel()
        unlink(socketPath)
        nonces.withLock { $0.removeAll() }
    }

    /// Rejection codes so far, oldest first (added; at most 100 kept).
    public var rejections: [IPCRejection] {
        state.withLock { $0.rejections }
    }

    /// Connections that passed peer verification and `hello` (added).
    public var acceptedConnections: Int {
        state.withLock { $0.accepted }
    }

    // MARK: - Connections

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let admitted = state.withLock { state -> Bool? in
                guard !state.stopped else { return false }
                guard state.pending < Self.maxPendingConnections else { return nil }
                state.pending += 1
                state.clients.insert(client)
                return true
            }
            guard admitted == true else {
                close(client)
                if admitted == nil { _ = reject(.tooManyPending) }
                continue
            }
            let thread = Thread { [self] in self.serve(client) }
            thread.name = "lightwell.ipc.connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            state.withLock { state in
                state.clients.remove(fd)
                close(fd)
            }
        }
        var reader = IPCLineReader()
        let greeted = verifyAndGreet(fd, reader: &reader)
        state.withLock { state in
            state.pending -= 1
            if greeted != nil { state.accepted += 1 }
        }
        guard let thread = greeted else { return }
        setTimeout(fd, seconds: 0)
        while case .line(let data) = reader.read(from: fd) {
            guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else {
                // Answer with an error when the id can be read; otherwise drop the connection so the
                // helper does not wait for its timeout.
                guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue,
                      let line = try? IPC.encodeLine(IPCResponse(id: Int(id), error: IPCError(code: -32600, message: "invalid request"))),
                      Self.writeAll(fd, line)
                else { return }
                continue
            }
            let response: IPCResponse
            switch IPC.Method(rawValue: request.method) {
            case .callTool:
                guard let params = try? Self.decode(CallToolParams.self, from: request.params) else {
                    response = IPCResponse(id: request.id, error: IPCError(code: -32602, message: "callTool needs name and arguments"))
                    break
                }
                let result = callHandler(name: params.name, arguments: params.arguments, thread: thread)
                response = IPCResponse(id: request.id, result: ["text": .string(result.text), "isError": .bool(result.isError)])
            case .ping:
                response = IPCResponse(id: request.id, result: ["ok": true])
            case .hello, nil:
                response = IPCResponse(id: request.id, error: IPCError(code: -32601, message: "unsupported method"))
            }
            guard let line = try? IPC.encodeLine(response), Self.writeAll(fd, line) else { return }
        }
    }

    /// Peer check, then `hello`. Returns the session's thread, or nil after recording a rejection.
    private func verifyAndGreet(_ fd: Int32, reader: inout IPCLineReader) -> UUID? {
        guard let token = PeerVerifier.peerAuditToken(socket: fd) else { return reject(.peerTokenUnavailable) }
        guard let requirementText = state.withLock({ $0.requirement }),
              let requirement = PeerVerifier.compile(requirementText)
        else { return reject(.policyUnavailable) }
        guard PeerVerifier.verify(auditToken: token, requirement: requirement) else { return reject(.peerUnverified) }

        setTimeout(fd, seconds: Self.helloTimeout)
        let data: Data
        switch reader.read(from: fd) {
        case .line(let line): data = line
        case .tooLong: return reject(.malformed)
        case .closed: return reject(.closedBeforeHello)
        }
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else { return reject(.malformed) }
        guard request.method == IPC.Method.hello.rawValue,
              let hello = try? Self.decode(HelloParams.self, from: request.params)
        else { return reject(.notHello) }
        guard hello.protocol == IPC.protocolVersion else { return reject(.protocolMismatch) }
        guard let thread = lookup(nonce: hello.nonce) else { return reject(.badNonce) }
        guard let line = try? IPC.encodeLine(IPCResponse(id: request.id, result: ["ok": true])), Self.writeAll(fd, line) else {
            return reject(.closedBeforeHello)
        }
        return thread
    }

    /// Constant-time comparison against every registered nonce.
    private func lookup(nonce: String) -> UUID? {
        let candidate = Array(nonce.utf8)
        return nonces.withLock { table in
            var match: UUID?
            for (key, thread) in table {
                let bytes = Array(key.utf8)
                var difference = UInt8(bytes.count == candidate.count ? 0 : 1)
                for index in 0..<min(bytes.count, candidate.count) { difference |= bytes[index] ^ candidate[index] }
                if difference == 0 { match = thread }
            }
            return match
        }
    }

    private func reject(_ reason: IPCRejection) -> UUID? {
        state.withLock { state in
            state.rejections.append(reason)
            if state.rejections.count > 100 { state.rejections.removeFirst(state.rejections.count - 100) }
        }
        Self.logger.notice("helper connection rejected: \(reason.rawValue, privacy: .public)")
        return nil
    }

    private func callHandler(name: String, arguments: JSONValue, thread: UUID) -> ToolCallResult {
        let box = Mutex<ToolCallResult?>(nil)
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task.detached {
            let result = await handler.handle(name: name, arguments: arguments, thread: thread)
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        let result = box.withLock { $0 } ?? ToolCallResult(text: "The app could not answer.", isError: true)
        // Single choke point for the 24 KiB result cap (PLAN 3.7).
        return ToolOutput.enforceSizeLimit(result)
    }

    private func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Newline framing over a blocking socket, at most `IPC.maxLineBytes` per line.
struct IPCLineReader {
    enum Outcome {
        case line(Data)
        case tooLong
        case closed
    }

    private var buffer = Data()

    mutating func read(from fd: Int32) -> Outcome {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return .line(line)
            }
            if buffer.count > IPC.maxLineBytes { return .tooLong }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return .closed }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
