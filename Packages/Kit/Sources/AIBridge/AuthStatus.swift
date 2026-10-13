import Foundation
import IPCProtocol

/// Which key sources the "Block API keys" setting lets through (PLAN 3.2b).
///
/// Allowed: no key at all ("none": a Claude subscription OAuth login) and the key the CLI manages
/// itself after a Console `/login` ("/login managed key": API-credit logins, which the user relies on).
/// Anything else (`ANTHROPIC_API_KEY`, `apiKeyHelper`, ...) is a key Lightwell must not run on.
public enum APIKeyPolicy {
    public static let allowedKeySources: Set<String> = ["none", "/login managed key"]

    public static func allows(keySource: String) -> Bool {
        allowedKeySources.contains(keySource)
    }
}

/// The few non-secret fields of `claude auth status --json` (added).
///
/// Shape observed with CLI 2.1.296 on this Mac (OAuth login): `loggedIn` (Bool), `authMethod`
/// ("oauth_token"), `apiProvider` ("firstParty"), plus folder paths. The CLI adds `apiKeySource`
/// only when a key is in use, and `email`/`orgId` for some logins. Only the fields below are ever
/// read; nothing else is kept, logged or shown.
public struct ClaudeAuthStatus: Sendable, Hashable {
    public var loggedIn: Bool?
    /// One of "none", "third_party", "claude.ai", "api_key_helper", "oauth_token", "api_key" (CLI 2.1.296).
    public var authMethod: String?
    public var apiKeySource: String?

    public init(loggedIn: Bool? = nil, authMethod: String? = nil, apiKeySource: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiKeySource = apiKeySource
    }

    /// Parses the JSON printed by `auth status --json`; nil when it is not a JSON object.
    public static func parse(_ data: Data) -> ClaudeAuthStatus? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = value else { return nil }
        return ClaudeAuthStatus(
            loggedIn: value["loggedIn"]?.boolValue,
            authMethod: value["authMethod"]?.stringValue,
            apiKeySource: value["apiKeySource"]?.stringValue
        )
    }

    /// The key source that makes this login unacceptable, or nil when it is allowed. OAuth logins and
    /// unknown methods without a key source are allowed; `api_key` authentication is refused unless
    /// the key is the CLI's own `/login` managed key, and `api_key_helper` is always refused.
    public var disallowedKeySource: String? {
        if let apiKeySource, !APIKeyPolicy.allows(keySource: apiKeySource) { return apiKeySource }
        if authMethod == "api_key", apiKeySource == nil { return "api_key" }
        // A configured key helper whose error the CLI swallowed can report no key source at all.
        if authMethod == "api_key_helper" { return "apiKeyHelper" }
        return nil
    }

    /// Runs `<claude> auth status --json` with the given environment and folder (5 s timeout).
    /// Nil when the command fails, times out or prints something unparseable.
    public static func fetch(claude: URL, environment: [String: String], workingDirectory: URL, timeout: TimeInterval = 5) async -> ClaudeAuthStatus? {
        guard let output = await ProcessRunner.run(claude, arguments: ["auth", "status", "--json"], environment: environment, timeout: timeout, workingDirectory: workingDirectory),
              output.status == 0
        else { return nil }
        return parse(Data(output.stdout.utf8))
    }
}
