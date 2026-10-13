import Darwin
import Foundation
import IPCProtocol
import Security

public enum AssistantFileError: Error, Sendable, Hashable {
    case createDirectory(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case notADirectory(path: String)
}

/// Writes the per-session MCP config (PLAN 3.3): 0600, one `disk` stdio server, nonce in its env.
public enum MCPConfigWriter {
    /// `mcp-<thread>.json`.
    public static func configURL(directory: URL, thread: UUID) -> URL {
        directory.appendingPathComponent("mcp-\(thread.uuidString.lowercased()).json")
    }

    /// 32 random bytes as 64 lowercase hex characters. Never log the result.
    public static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // arc4random is a CSPRNG on Darwin as well.
            arc4random_buf(&bytes, bytes.count)
        }
        return bytes.map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    /// The config document.
    public static func configData(helperURL: URL, socketPath: String, nonce: String) -> Data {
        let config: JSONValue = [
            "mcpServers": [
                .init(stringLiteral: ToolCatalog.serverName): [
                    "type": "stdio",
                    "command": .string(helperURL.path),
                    "args": ["--socket", .string(socketPath)],
                    "env": [.init(stringLiteral: IPC.nonceEnvironmentKey): .string(nonce)],
                ],
            ],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(config)) ?? Data()
    }

    /// Writes the config with mode 0600 (created that way, never world readable even briefly).
    @discardableResult
    public static func write(to url: URL, helperURL: URL, socketPath: String, nonce: String) throws -> URL {
        try SecureFile.ensureDirectory(url.deletingLastPathComponent())
        try SecureFile.write(configData(helperURL: helperURL, socketPath: socketPath, nonce: nonce), to: url)
        return url
    }

    /// Deletes the config at session end.
    public static func remove(at url: URL) {
        unlink(url.path)
    }
}

/// Owner-only files and folders for everything under `Application Support/Lightwell/assistant`.
enum SecureFile {
    /// Creates the folder (and parents) and sets 0700 on the leaf.
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw AssistantFileError.notADirectory(path: url.path) }
        } else {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw AssistantFileError.createDirectory(path: url.path, errno: errno)
            }
        }
        chmod(url.path, 0o700)
    }

    /// Writes `data` to a 0600 temporary file in the same folder and renames it over `url`.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AssistantFileError.write(path: url.path, errno: errno) }
        fchmod(fd, 0o600)
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        close(fd)
        guard failure == 0, rename(temporary.path, url.path) == 0 else {
            let error = failure != 0 ? failure : errno
            unlink(temporary.path)
            throw AssistantFileError.write(path: url.path, errno: error)
        }
    }
}
