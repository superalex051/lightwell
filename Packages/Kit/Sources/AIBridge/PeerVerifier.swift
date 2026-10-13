import Darwin
import Foundation
import Security

/// Who may connect to the IPC socket (PLAN 3.6).
public enum PeerPolicy: Sendable, Hashable {
    /// Signed by our team with the helper's identifier:
    /// `identifier "<id>" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`.
    case team(identifier: String, teamID: String)
    /// Exact code directory hash (ad-hoc signed builds): `cdhash H"<hex>"`. Hex, lowercase or uppercase.
    case cdhash(String)
    /// Any code signing requirement string.
    case requirement(String)
    /// Decided at `start()` from the app's own signature: team mode when the app has a team id
    /// (helper identifier read from the bundled helper's signature), cdhash of the bundled helper otherwise.
    case automatic(helperURL: URL)
}

/// Static signing details of a binary on disk.
public struct CodeSigningInfo: Sendable, Hashable {
    public var identifier: String?
    public var teamID: String?
    /// Lowercase hex code directory hash.
    public var cdhash: String?
}

public enum PeerVerifier {
    /// The requirement string a policy stands for. Nil when `.automatic` cannot be resolved
    /// (helper missing or unsigned), in which case every peer is rejected.
    public static func requirementString(for policy: PeerPolicy) -> String? {
        switch policy {
        case .team(let identifier, let teamID):
            return "identifier \(quoted(identifier)) and anchor apple generic and certificate leaf[subject.OU] = \(quoted(teamID))"
        case .cdhash(let hex):
            let clean = hex.lowercased().filter(\.isHexDigit)
            guard clean.count == 40 || clean.count == 64 else { return nil }
            return "cdhash H\"\(clean)\""
        case .requirement(let text):
            return text
        case .automatic(let helperURL):
            return resolve(.automatic(helperURL: helperURL)).flatMap(requirementString(for:))
        }
    }

    /// Turns `.automatic` into a concrete policy; other policies are returned unchanged.
    public static func resolve(_ policy: PeerPolicy) -> PeerPolicy? {
        guard case .automatic(let helperURL) = policy else { return policy }
        let helper = signingInfo(at: helperURL)
        if let team = ownSigningInfo()?.teamID, !team.isEmpty {
            let identifier = helper?.identifier ?? "\(Bundle.main.bundleIdentifier ?? "com.alexluncan.lightwell").mcp"
            return .team(identifier: identifier, teamID: team)
        }
        guard let cdhash = helper?.cdhash else { return nil }
        return .cdhash(cdhash)
    }

    /// Compiles a requirement string.
    public static func compile(_ requirement: String) -> SecRequirement? {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess else { return nil }
        return compiled
    }

    /// Checks the running process behind an audit token against the requirement.
    public static func verify(auditToken: audit_token_t, requirement: SecRequirement) -> Bool {
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Audit token of the process on the other end of a connected Unix socket.
    public static func peerAuditToken(socket fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size)
        else { return nil }
        return token
    }

    /// Signing details of a binary on disk.
    public static func signingInfo(at url: URL) -> CodeSigningInfo? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return info(of: staticCode)
    }

    /// Signing details of this process.
    public static func ownSigningInfo() -> CodeSigningInfo? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return info(of: staticCode)
    }

    private static func info(of staticCode: SecStaticCode) -> CodeSigningInfo? {
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any]
        else { return nil }
        let unique = (info[kSecCodeInfoUnique as String] as? Data).map { data in
            data.map { byte in byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16) }.joined()
        }
        return CodeSigningInfo(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            cdhash: unique
        )
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
