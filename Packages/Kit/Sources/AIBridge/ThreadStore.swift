import Foundation
import Synchronization

/// Persisted metadata of one assistant conversation.
public struct ThreadRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// CLI session id for `--resume`.
    public var sessionID: String?
    /// Model alias the thread was started with (added).
    public var model: String?
    /// Cumulative tokens over every turn (added). Input includes cache reads and writes.
    public var inputTokens: Int
    public var outputTokens: Int
    /// Cumulative estimated cost in millionths of a US dollar (added). Integer so it sums exactly;
    /// `estimatedCostCents` rounds it for display.
    public var estimatedCostMicros: Int
    /// Turns completed (added).
    public var turns: Int

    public init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date, sessionID: String? = nil, model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0, estimatedCostMicros: Int = 0, turns: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessionID = sessionID
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostMicros = estimatedCostMicros
        self.turns = turns
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, sessionID, model, inputTokens, outputTokens, estimatedCostMicros, turns
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        estimatedCostMicros = try c.decodeIfPresent(Int.self, forKey: .estimatedCostMicros) ?? 0
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    /// Estimated cost rounded to whole cents.
    public var estimatedCostCents: Int { (estimatedCostMicros + 5_000) / 10_000 }

    /// Thread title from the first user message: whitespace collapsed, at most `limit` characters,
    /// cut at a word boundary when possible.
    public static func title(fromFirstMessage message: String, limit: Int = 60) -> String {
        let collapsed = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let prefix = String(collapsed.prefix(limit))
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > limit / 2 {
            return String(prefix[..<space]) + "..."
        }
        return prefix + "..."
    }
}

/// `assistant/threads.json` (PLAN 3.4): thread list with cumulative usage. Thread safe.
public final class ThreadStore: Sendable {
    public static let fileName = "threads.json"

    private struct Document: Codable {
        var version = 1
        var threads: [ThreadRecord]
    }

    public let fileURL: URL
    private let records: Mutex<[ThreadRecord]>

    /// Loads the file if it exists; a missing or unreadable file starts empty.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(Document.self, from: $0) }?.threads ?? []
        records = Mutex(loaded)
    }

    /// `<directory>/threads.json`.
    public convenience init(directory: URL) {
        self.init(fileURL: directory.appendingPathComponent(Self.fileName))
    }

    /// Newest first.
    public var threads: [ThreadRecord] {
        records.withLock { $0.sorted { $0.updatedAt > $1.updatedAt } }
    }

    public func thread(_ id: UUID) -> ThreadRecord? {
        records.withLock { $0.first { $0.id == id } }
    }

    /// Creates a thread titled from its first message.
    @discardableResult
    public func createThread(id: UUID = UUID(), firstMessage: String, model: String?, now: Date = Date()) throws -> ThreadRecord {
        let record = ThreadRecord(
            id: id,
            title: ThreadRecord.title(fromFirstMessage: firstMessage),
            createdAt: now,
            updatedAt: now,
            sessionID: ClaudeCommandBuilder.sessionID(for: id),
            model: model
        )
        try upsert(record)
        return record
    }

    public func upsert(_ record: ThreadRecord) throws {
        try mutate { list in
            if let index = list.firstIndex(where: { $0.id == record.id }) {
                list[index] = record
            } else {
                list.append(record)
            }
            return true
        }
    }

    /// Adds one turn's usage and cost to the thread totals.
    @discardableResult
    public func recordTurn(thread id: UUID, result: TurnResult, now: Date = Date()) throws -> ThreadRecord? {
        var updated: ThreadRecord?
        try mutate { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            if let usage = result.usage {
                list[index].inputTokens += usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens
                list[index].outputTokens += usage.outputTokens
            }
            list[index].estimatedCostMicros += result.estimatedCostMicros
            list[index].turns += 1
            list[index].updatedAt = now
            updated = list[index]
            return true
        }
        return updated
    }

    public func remove(_ id: UUID) throws {
        try mutate { list in
            list.removeAll { $0.id == id }
            return true
        }
    }

    /// Mutation and save under one lock, so concurrent writers can never save an older snapshot last.
    /// `body` returns whether anything changed (and needs saving).
    private func mutate(_ body: (inout [ThreadRecord]) -> Bool) throws {
        try records.withLock { list in
            var copy = list
            guard body(&copy) else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(Document(threads: copy))
            try SecureFile.ensureDirectory(fileURL.deletingLastPathComponent())
            try SecureFile.write(data, to: fileURL)
            list = copy
        }
    }
}
