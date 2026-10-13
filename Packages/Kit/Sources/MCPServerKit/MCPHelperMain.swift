import Darwin
import Foundation
import IPCProtocol

/// Entry point of the `lightwell-mcp` helper (stdio MCP server, PLAN 3.6 and 3.7).
///
/// Usage: `lightwell-mcp --socket <path>` with the session nonce in `LIGHTWELL_MCP_NONCE`.
/// `tools/list` always works from the static catalog; without a socket or nonce, or when the app
/// cannot be reached, every call returns `ToolCatalog.appUnavailableText`.
public enum MCPHelperMain {
    public static let version = "1.0"

    /// Parsed command line and environment.
    public struct Options: Sendable, Hashable {
        public var socketPath: String?
        public var nonce: String?
        public var printVersion: Bool

        public init(socketPath: String? = nil, nonce: String? = nil, printVersion: Bool = false) {
            self.socketPath = socketPath
            self.nonce = nonce
            self.printVersion = printVersion
        }

        /// `--socket <path>` (or `--socket=<path>`) wins over `LIGHTWELL_MCP_SOCKET`; the nonce comes
        /// only from the environment so it never shows up in process listings.
        public static func parse(arguments: [String], environment: [String: String]) -> Options {
            var options = Options()
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--socket", index + 1 < arguments.count {
                    options.socketPath = arguments[index + 1]
                    index += 1
                } else if argument.hasPrefix("--socket=") {
                    options.socketPath = String(argument.dropFirst("--socket=".count))
                } else if argument == "--version" {
                    options.printVersion = true
                }
                index += 1
            }
            if options.socketPath?.isEmpty ?? true { options.socketPath = environment[IPC.socketEnvironmentKey] }
            if let value = environment[IPC.nonceEnvironmentKey], !value.isEmpty { options.nonce = value }
            return options
        }

        public func makeBackend() -> any ToolBackend {
            guard let socketPath, !socketPath.isEmpty, let nonce else { return UnavailableToolBackend() }
            return SocketToolBackend(socketPath: socketPath, nonce: nonce)
        }
    }

    public static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let options = Options.parse(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
        if options.printVersion {
            FileHandle.standardOutput.write(Data("lightwell-mcp \(version)\n".utf8))
            exit(0)
        }
        if options.socketPath == nil { Diagnostics.log("no --socket given, tool calls will report that the app is unavailable") }
        let server = MCPServer(backend: options.makeBackend())
        let output = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            guard let response = server.handle(line: line) else { continue }
            do {
                try output.write(contentsOf: Data((response + "\n").utf8))
            } catch {
                // The client went away.
                exit(0)
            }
        }
        exit(0)
    }
}
