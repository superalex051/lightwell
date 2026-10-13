import Foundation

/// Renders the bundled `assistant-system-prompt.md` template into the per-session system prompt
/// file passed with `--system-prompt-file` (PLAN 3.8).
///
/// Placeholders look like `{{name}}`. Known names: `scanAge` (how old the scan snapshot is, in words)
/// and `scannedRoot` (the scanned folder, `~` form). Unknown placeholders are left as they are.
public enum SystemPromptRenderer {
    /// Resource name of the template in the app bundle (`App/Resources/assistant-system-prompt.md`).
    public static let templateResourceName = "assistant-system-prompt"
    public static let templateResourceExtension = "md"
    /// Name of the rendered file inside the assistant folder.
    public static let fileName = "system-prompt.md"

    public static func render(template: String, values: [String: String]) -> String {
        var output = template
        for (key, value) in values {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }

    /// Renders with the standard values.
    public static func render(template: String, scanAgeSeconds: Int?, scannedRoot: String?) -> String {
        render(template: template, values: [
            "scanAge": describeScanAge(seconds: scanAgeSeconds),
            "scannedRoot": scannedRoot ?? "no scan yet",
        ])
    }

    /// Placeholders still present after rendering.
    public static func unresolvedPlaceholders(in text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { break }
            names.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return names
    }

    /// Writes the rendered prompt with mode 0600.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> URL {
        try SecureFile.ensureDirectory(url.deletingLastPathComponent())
        try SecureFile.write(Data(text.utf8), to: url)
        return url
    }

    /// Plain English age of the scan, for the model ("no scan yet", "2 minutes", "3 hours", "5 days").
    public static func describeScanAge(seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "no scan yet" }
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        switch seconds {
        case ..<60: return "less than a minute"
        case ..<3600: return unit(seconds / 60, "minute")
        case ..<86_400: return unit(seconds / 3600, "hour")
        default: return unit(seconds / 86_400, "day")
        }
    }
}
