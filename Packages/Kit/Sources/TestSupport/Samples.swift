import Foundation

/// Access to the recorded claude CLI transcripts in `Tests/Fixtures/cli-samples/` (stream parser and MCP tests).
/// The transcripts are redacted: home paths, session ids, message ids and the local tool inventory are synthetic.
public enum Samples {
    public enum SampleError: Error, Sendable {
        case directoryNotFound
    }

    /// `Tests/Fixtures/cli-samples`, found by walking up from this source file to the package root.
    public static func directory(file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Tests/Fixtures/cli-samples", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url = url.deletingLastPathComponent()
        }
        throw SampleError.directoryNotFound
    }

    /// URL of one sample, e.g. `"02-mcp-partial.jsonl"`.
    public static func url(_ name: String) throws -> URL {
        try directory().appendingPathComponent(name)
    }

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// Non-empty lines of a `.jsonl` sample.
    public static func lines(_ name: String) throws -> [String] {
        String(decoding: try data(name), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// File names of every sample.
    public static func all() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory().path).sorted()
    }
}
