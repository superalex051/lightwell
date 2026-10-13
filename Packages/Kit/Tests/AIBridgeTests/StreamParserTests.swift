import Foundation
import IPCProtocol
import Testing
import TestSupport
@testable import AIBridge

extension StreamEvent {
    /// Case name, for counting.
    var kind: String {
        switch self {
        case .initialized: "initialized"
        case .status: "status"
        case .messageStart: "messageStart"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .toolUseStart: "toolUseStart"
        case .toolInputDelta: "toolInputDelta"
        case .blockStop: "blockStop"
        case .messageDelta: "messageDelta"
        case .assistantMessage: "assistantMessage"
        case .toolResult: "toolResult"
        case .thinkingTokens: "thinkingTokens"
        case .apiRetry: "apiRetry"
        case .controlResponse: "controlResponse"
        case .result: "result"
        case .unknown: "unknown"
        case .processExited: "processExited"
        case .refused: "refused"
        }
    }
}

func parseAll(_ data: Data) -> (events: [StreamEvent], parser: StreamJSONParser) {
    var parser = StreamJSONParser()
    var events = parser.feed(data)
    events += parser.finish()
    return (events, parser)
}

func counts(_ events: [StreamEvent]) -> [String: Int] {
    events.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
}

@Suite("Stream-json parser")
struct StreamParserTests {
    /// Golden event counts per recorded transcript (see the mapping on `StreamJSONParser`).
    static let golden: [String: [String: Int]] = [
        "01-basic-stream-json.jsonl": ["unknown": 13, "initialized": 1, "assistantMessage": 1, "result": 1],
        "02-mcp-partial.jsonl": [
            "initialized": 1, "status": 3, "messageStart": 3, "textDelta": 45, "toolUseStart": 2, "toolInputDelta": 15,
            "blockStop": 3, "messageDelta": 3, "assistantMessage": 3, "toolResult": 2, "result": 1,
        ],
        "02-trimmed.jsonl": [
            "initialized": 1, "status": 1, "messageStart": 1, "toolUseStart": 1, "toolInputDelta": 1, "textDelta": 1,
            "blockStop": 1, "messageDelta": 1, "assistantMessage": 2, "toolResult": 1, "result": 1,
        ],
        "04-stream-input.jsonl": ["initialized": 2, "assistantMessage": 2, "result": 2],
        "05-interrupt.jsonl": [
            "initialized": 1, "status": 1, "messageStart": 1, "thinkingDelta": 2, "textDelta": 92, "blockStop": 2,
            "messageDelta": 1, "assistantMessage": 2, "thinkingTokens": 2, "controlResponse": 1, "result": 1,
        ],
    ]

    @Test func everySampleLineParses() throws {
        let samples = try Samples.all().filter { $0.hasSuffix(".jsonl") }
        #expect(Set(samples) == Set(Self.golden.keys))
        for name in samples {
            let data = try Samples.data(name)
            let (events, parser) = parseAll(data)
            #expect(parser.malformedLines == 0, "\(name)")
            #expect(parser.linesRead == (try Samples.lines(name)).count, "\(name)")
            #expect(counts(events) == Self.golden[name], "\(name): \(counts(events))")
        }
    }

    @Test(arguments: ["01-basic-stream-json.jsonl", "02-mcp-partial.jsonl", "02-trimmed.jsonl", "04-stream-input.jsonl", "05-interrupt.jsonl"])
    func byteSplitFeedingGivesIdenticalOutput(name: String) throws {
        let data = try Samples.data(name)
        let whole = parseAll(data).events

        var single = StreamJSONParser()
        var oneByOne: [StreamEvent] = []
        for byte in data { oneByOne += single.feed(Data([byte])) }
        oneByOne += single.finish()
        #expect(oneByOne == whole)

        var generator = SplitMix(seed: 42)
        var chunked = StreamJSONParser()
        var random: [StreamEvent] = []
        var index = data.startIndex
        while index < data.endIndex {
            let size = Int(generator.next() % 700) + 1
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            random += chunked.feed(data[index..<end])
            index = end
        }
        random += chunked.finish()
        #expect(random == whole)
    }

    @Test func mcpTranscriptDetails() throws {
        let events = parseAll(try Samples.data("02-mcp-partial.jsonl")).events
        guard case .initialized(let info) = events.first else {
            Issue.record("first event is not init")
            return
        }
        #expect(info.mcpServers == [MCPServerStatus(name: "daisy", status: "connected")])
        #expect(info.apiKeySource == "none")
        #expect(info.supportsInterrupt)
        #expect(info.model == "claude-sonnet-5-5")
        #expect(info.version == "2.1.296")

        let starts = events.compactMap { event -> (String, String)? in
            if case .toolUseStart(let id, let name) = event { return (id, name) }
            return nil
        }
        #expect(starts.map(\.1) == ["mcp__daisy__get_largest_items", "mcp__daisy__propose_deletion"])
        let deltaIDs = Set(events.compactMap { event -> String? in
            if case .toolInputDelta(let id, _) = event { return id }
            return nil
        })
        #expect(deltaIDs == Set(starts.map(\.0)))

        let results = events.compactMap { event -> (String, String, Bool)? in
            if case .toolResult(let id, let text, let isError) = event { return (id, text, isError) }
            return nil
        }
        #expect(results.map(\.0) == starts.map(\.0))
        #expect(results[1].1 == "Queued 1 item(s) for user confirmation. Nothing was deleted.")
        #expect(results.allSatisfy { !$0.2 })

        guard case .result(let result) = events.last else {
            Issue.record("last event is not result")
            return
        }
        #expect(result.subtype == "success")
        #expect(!result.isError)
        #expect(result.numTurns == 3)
        #expect(result.terminalReason == "completed")
        #expect(result.usage?.outputTokens == 423)
        #expect(result.estimatedCostMicros == 13_052)
        #expect(result.permissionDenials.isEmpty)
        #expect(events.contains(.messageDelta(stopReason: "tool_use")))
        #expect(events.contains(.messageDelta(stopReason: "end_turn")))
        #expect(events.contains(.status("requesting")))
    }

    @Test func interruptTranscriptDetails() throws {
        let events = parseAll(try Samples.data("05-interrupt.jsonl")).events
        #expect(events.contains(.controlResponse(requestID: "req_1", subtype: "success")))
        #expect(events.contains(.thinkingTokens(50)))
        guard case .result(let result) = events.last else {
            Issue.record("last event is not result")
            return
        }
        #expect(result.subtype == "error_during_execution")
        #expect(result.isError)
        #expect(result.terminalReason == "aborted_streaming")
    }

    @Test func multiTurnInputHasTwoInits() throws {
        let events = parseAll(try Samples.data("04-stream-input.jsonl")).events
        let inits = events.filter { $0.kind == "initialized" }
        #expect(inits.count == 2)
        let texts = events.compactMap { event -> String? in
            if case .result(let result) = event { return result.text }
            return nil
        }
        #expect(texts.count == 2)
    }

    @Test func malformedAndUnknownLines() {
        let input = """
        not json
        {"no_type":1}
        [1,2]
        {"type":"system","subtype":"hook_started"}
        {"type":"brand_new_event","subtype":"x","extra":{"a":1}}
        {"type":"stream_event","event":{"type":"ping"}}
        {"type":"stream_event","event":{"type":"message_stop"}}
        {"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":1200,"error_status":529,"error":"overloaded"}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"plain","is_error":true}]}}
        {"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":12,"total_cost_usd":0,"permission_denials":[{"tool_name":"Bash","tool_use_id":"x","tool_input":{}}],"api_error_status":null}

        """
        let (events, parser) = parseAll(Data(input.utf8))
        #expect(parser.malformedLines == 3)
        #expect(events == [
            .unknown(type: "system", subtype: "hook_started"),
            .unknown(type: "brand_new_event", subtype: "x"),
            .unknown(type: "stream_event", subtype: "ping"),
            .apiRetry(attempt: 2, max: 10, delayMs: 1200, errorStatus: 529, error: "overloaded"),
            .toolResult(toolUseID: "t1", text: "plain", isError: true),
            .result(TurnResult(subtype: "error_max_turns", isError: true, numTurns: 12, totalCostUSD: 0, permissionDenials: ["Bash"])),
        ])
    }

    @Test func splitInsideUTF8AndCRLF() {
        let line = Data("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Disk \u{1F4BE} ok\"}}}\r\n".utf8)
        let emoji = line.firstIndex(of: 0xF0)!
        var parser = StreamJSONParser()
        #expect(parser.feed(line[..<(emoji + 2)]).isEmpty)
        #expect(parser.feed(line[(emoji + 2)...]) == [.textDelta("Disk \u{1F4BE} ok")])
    }

    @Test func finalLineWithoutNewline() {
        var parser = StreamJSONParser()
        #expect(parser.feed(Data(#"{"type":"system","subtype":"status","status":"requesting"}"#.utf8)).isEmpty)
        #expect(parser.finish() == [.status("requesting")])
    }
}

/// Small deterministic generator for chunk sizes.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
