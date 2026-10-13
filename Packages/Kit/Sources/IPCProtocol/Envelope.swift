import Foundation

/// Any JSON value. Integers are kept apart from doubles so byte counts round-trip exactly.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let v): v
        case .double(let v) where v.rounded() == v && abs(v) < 9.0e15: Int64(v)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Socket protocol between the helper and the app (PLAN 3.6).
public enum IPC {
    public static let protocolVersion = 1
    /// Newline-delimited UTF-8 JSON, one message per line, at most 1 MiB per line.
    public static let maxLineBytes = 1 << 20
    /// Environment variable carrying the per-session nonce to the helper. Never print its value.
    public static let nonceEnvironmentKey = "LIGHTWELL_MCP_NONCE"
    /// Environment variable carrying the socket path to the helper.
    public static let socketEnvironmentKey = "LIGHTWELL_MCP_SOCKET"

    public enum Method: String, Codable, Sendable {
        case hello
        case callTool
        case ping
    }

    /// Encodes one message as a single line (with trailing newline).
    public static func encodeLine(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

public struct IPCRequest: Codable, Sendable, Hashable {
    public var id: Int
    public var method: String
    public var params: JSONValue

    public init(id: Int, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct IPCError: Codable, Sendable, Hashable, Error {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct IPCResponse: Codable, Sendable, Hashable {
    public var id: Int
    public var result: JSONValue?
    public var error: IPCError?

    public init(id: Int, result: JSONValue? = nil, error: IPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// `hello` params sent by the helper right after connecting.
public struct HelloParams: Codable, Sendable, Hashable {
    public var nonce: String
    public var `protocol`: Int
    public var helperVersion: String

    public init(nonce: String, protocol: Int = IPC.protocolVersion, helperVersion: String) {
        self.nonce = nonce
        self.protocol = `protocol`
        self.helperVersion = helperVersion
    }
}

/// `callTool` params.
public struct CallToolParams: Codable, Sendable, Hashable {
    public var name: String
    public var arguments: JSONValue

    public init(name: String, arguments: JSONValue) {
        self.name = name
        self.arguments = arguments
    }
}

/// Result of one tool call: JSON text for the model plus an error flag.
public struct ToolCallResult: Codable, Sendable, Hashable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}
