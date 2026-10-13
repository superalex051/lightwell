import Darwin
import Foundation
import IPCProtocol
import Synchronization

/// Forwards tool calls to the app over its Unix socket (PLAN 3.6).
///
/// Connects lazily on the first call, says `hello` with the session nonce, then sends `callTool`.
/// A broken connection is re-established once per call; when that fails the call returns
/// `ToolCatalog.appUnavailableText`. Diagnostics go to stderr and never include the nonce.
public final class SocketToolBackend: ToolBackend {
    private struct State {
        var fd: Int32 = -1
        var reader = LineReader()
        var nextID = 1
    }

    private let socketPath: String
    private let nonce: String
    private let timeoutSeconds: Int
    private let state = Mutex(State())

    public init(socketPath: String, nonce: String, timeoutSeconds: Int = 120) {
        self.socketPath = socketPath
        self.nonce = nonce
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {
        state.withLock { Self.disconnect(&$0) }
    }

    public func callTool(name: String, arguments: JSONValue) -> ToolCallResult {
        state.withLock { state in
            for attempt in 0..<2 {
                if state.fd < 0 {
                    if let failure = connect(&state) {
                        Diagnostics.log("app connection failed (\(failure)), attempt \(attempt + 1)")
                        continue
                    }
                }
                let params: JSONValue = ["name": .string(name), "arguments": arguments]
                switch exchange(&state, method: IPC.Method.callTool.rawValue, params: params) {
                case .success(let response):
                    if let error = response.error { return ToolCallResult(text: error.message, isError: true) }
                    guard let result = response.result,
                          let text = result["text"]?.stringValue
                    else { return ToolCallResult(text: "The app sent an unreadable reply.", isError: true) }
                    return ToolCallResult(text: text, isError: result["isError"]?.boolValue ?? false)
                case .failure(let failure):
                    Diagnostics.log("app call failed (\(failure)), attempt \(attempt + 1)")
                    Self.disconnect(&state)
                    // Resend only after a broken connection; a slow or oversized reply would repeat the work.
                    switch failure {
                    case .timeout:
                        return ToolCallResult(text: "The app took too long to answer. Try a narrower request.", isError: true)
                    case .lineTooLong:
                        return ToolCallResult(text: "The app reply was over the 1 MiB limit. Narrow the query: use a smaller limit, a more specific path or filter, or fetch the next page with cursor.", isError: true)
                    case .badReply:
                        return ToolCallResult(text: "The app sent an unreadable reply.", isError: true)
                    default:
                        continue
                    }
                }
            }
            return ToolCallResult(text: ToolCatalog.appUnavailableText, isError: true)
        }
    }

    // MARK: - Connection

    enum Failure: Error, CustomStringConvertible {
        case socket(Int32)
        case connect(Int32)
        case pathTooLong
        case write(Int32)
        case closed
        case timeout
        case lineTooLong
        case badReply
        case helloRefused

        var description: String {
            switch self {
            case .socket(let e): "socket errno \(e)"
            case .connect(let e): "connect errno \(e)"
            case .pathTooLong: "socket path too long"
            case .write(let e): "write errno \(e)"
            case .closed: "closed by app"
            case .timeout: "timed out"
            case .lineTooLong: "reply too long"
            case .badReply: "unreadable reply"
            case .helloRefused: "hello refused"
            }
        }
    }

    private func connect(_ state: inout State) -> Failure? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .socket(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            return .pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            return .connect(error)
        }
        state.fd = fd
        state.reader = LineReader()

        let hello = HelloParams(nonce: nonce, helperVersion: MCPHelperMain.version)
        guard let params = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(hello)) else {
            Self.disconnect(&state)
            return .badReply
        }
        switch exchange(&state, method: IPC.Method.hello.rawValue, params: params) {
        case .success(let response) where response.result?["ok"]?.boolValue == true:
            return nil
        case .success:
            Self.disconnect(&state)
            return .helloRefused
        case .failure(let failure):
            Self.disconnect(&state)
            return failure
        }
    }

    private func exchange(_ state: inout State, method: String, params: JSONValue) -> Result<IPCResponse, Failure> {
        let id = state.nextID
        state.nextID += 1
        guard let line = try? IPC.encodeLine(IPCRequest(id: id, method: method, params: params)) else { return .failure(.badReply) }
        if let failure = Self.writeAll(state.fd, line) { return .failure(failure) }
        while true {
            switch state.reader.readLine(from: state.fd) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let data):
                guard let response = try? JSONDecoder().decode(IPCResponse.self, from: data) else { return .failure(.badReply) }
                // Replies arrive in order; skip anything stale.
                if response.id == id { return .success(response) }
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Failure? {
        var failure: Failure?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = .write(errno)
                    return
                }
                offset += written
            }
        }
        return failure
    }

    private static func disconnect(_ state: inout State) {
        if state.fd >= 0 { close(state.fd) }
        state.fd = -1
        state.reader = LineReader()
    }
}

/// Newline framing over a blocking file descriptor, at most `IPC.maxLineBytes` per line.
struct LineReader {
    private var buffer = Data()

    mutating func readLine(from fd: Int32) -> Result<Data, SocketToolBackend.Failure> {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return .success(Data(line))
            }
            if buffer.count > IPC.maxLineBytes { return .failure(.lineTooLong) }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .failure(.timeout) }
            if count <= 0 { return .failure(.closed) }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// Diagnostics on stderr only (stdout carries JSON-RPC). Never pass secrets here.
enum Diagnostics {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("lightwell-mcp: \(message)\n".utf8))
    }
}
