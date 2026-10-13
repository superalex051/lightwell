import AIBridge
import CleanupKit
import Foundation
import IPCProtocol
import Testing
import TestSupport
@testable import AppCore

/// Gated live smoke (PLAN 5.2) through the real stores: AssistantModel -> real `claude` (haiku) ->
/// mcp-helper -> IPCServer -> ToolHandler on a fixture scan -> CleanupModel. Nothing is executed.
/// Run with `LIGHTWELL_LIVE_CLAUDE=1`. The CLI creates `~/.claude/projects/<cwd slug>/` for the
/// fixture working directory (CLI bookkeeping, outside the fixture).
@Suite("Live assistant smoke", .serialized)
@MainActor
struct LiveAssistantTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTWELL_LIVE_CLAUDE"] == "1", "set LIGHTWELL_LIVE_CLAUDE=1"))
    func liveClaudeThroughTheRealToolHandler() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let claude = try await ClaudeLocator.locate(override: nil)
        var services = try AssistantModelTests.services(fixture, claude: claude.url)
        services.claudeOverride = claude.url
        let app = try await AppHarness(fixture: fixture, assistant: services)
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        app.model.settings.assistantModel = "haiku"
        app.model.settings.assistantMaxTurns = 10
        app.model.settings.assistantConsentAccepted = true
        assistant.recheck()
        await assistant.waitForRecheck()
        guard case .ready = assistant.availability else {
            Issue.record("assistant not ready: \(assistant.availability)")
            return
        }
        assistant.send("find safe things to clean")
        let finished = await waitUntil(timeout: 240) { !assistant.isResponding }
        #expect(finished)

        let tools = assistant.items.compactMap { item -> String? in if case .tool(let a) = item.kind { a.name } else { nil } }
        let errors = assistant.items.compactMap { item -> String? in if case .error(let text) = item.kind { text } else { nil } }
        let queue = app.model.cleanup.queue
        let root = fixture.root.path
        print("LIVE AppCore: claude \(claude.version ?? "?"), key source = \(assistant.keySource ?? "nil"), turns = \(assistant.usage.turns), tokens in/out = \(assistant.usage.inputTokens)/\(assistant.usage.outputTokens), cost cents = \(assistant.usage.costCents), tools = \(tools), queued = \(queue.map { $0.path.replacingOccurrences(of: root, with: "<fixture>") }), errors = \(errors.count)")
        #expect(errors.isEmpty)
        #expect(assistant.keySource == "none" || assistant.keySource == "/login managed key")
        #expect(tools.contains("propose_deletion"))
        #expect(!queue.isEmpty)
        #expect(queue.allSatisfy { $0.path.hasPrefix(root + "/") && !$0.isSelected && $0.source.isAssistant })
        #expect(!queue.contains { $0.path.contains("/Keychains") })
        #expect(assistant.usage.costCents < 10)
        #expect(app.model.cleanup.lastReport == nil, "nothing was executed")
    }
}
