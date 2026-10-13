import AIBridge
import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Assistant store end to end: AssistantModel -> ClaudeSession(fake-claude) -> mcp-helper -> IPCServer
/// (peer verified by cdhash) -> the real ToolHandler on a fixture scan -> CleanupModel.
@Suite("Assistant with fake-claude and the real tool handler", .serialized)
@MainActor
struct AssistantModelTests {
    static var helperCdhash: String {
        PeerVerifier.signingInfo(at: Products.url("mcp-helper"))?.cdhash ?? ""
    }

    static func services(_ fixture: HomeFixture, claude: URL = Products.url("fake-claude"), script: JSONValue? = nil) throws -> AssistantServices {
        let files = fixture.root.appendingPathComponent("app-files")
        let directory = files.appendingPathComponent("assistant")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let script {
            try JSONEncoder().encode(script).write(to: directory.appendingPathComponent("fake-claude-script.json"))
        }
        return AssistantServices(
            directory: directory,
            ipcDirectory: files.appendingPathComponent("ipc"),
            helperURL: Products.url("mcp-helper"),
            peerPolicy: .cdhash(helperCdhash),
            claudeOverride: claude,
            systemPromptTemplate: systemPromptTemplateText
        )
    }

    @Test func proposalFromFakeClaudeLandsInTheQueueUnselected() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture, assistant: try Self.services(fixture))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }

        await assistant.waitForRecheck()
        #expect(assistant.availability == .needsConsent)
        assistant.acceptConsent()
        #expect(app.model.settings.assistantConsentAccepted)
        // The CLI is looked for only now, after the consent (PLAN 3.11).
        await assistant.waitForRecheck()
        guard case .ready = assistant.availability else { Issue.record("not ready: \(assistant.availability)"); return }

        let paths = ["~/Library/Developer/Xcode/DerivedData/App-1", "~/Downloads/old-installer.dmg", "~/Library/Keychains/login.keychain-db"]
        assistant.send("Please suggest " + paths.joined(separator: " "))
        #expect(assistant.isResponding)
        #expect(await waitUntil { !assistant.isResponding })

        let kinds = assistant.items.map(\.kind)
        #expect(kinds.contains { if case .user = $0 { true } else { false } })
        let tools = assistant.items.compactMap { item -> ToolActivity? in if case .tool(let a) = item.kind { a } else { nil } }
        #expect(tools.map(\.name) == ["propose_deletion"])
        #expect(tools.allSatisfy { $0.state == .succeeded })
        let batch = try #require(assistant.items.compactMap { item -> ProposalBatch? in if case .proposal(let b) = item.kind { b } else { nil } }.first)
        #expect(batch.queued.map(\.path) == Array(paths.prefix(2)))
        #expect(batch.rejected.map(\.path) == [paths[2]])
        #expect(!kinds.contains { if case .error = $0 { true } else { false } }, "\(kinds)")

        let queue = app.model.cleanup.queue
        #expect(queue.map(\.path) == [fixture.path("home/Library/Developer/Xcode/DerivedData/App-1"), fixture.path("home/Downloads/old-installer.dmg")])
        #expect(queue.allSatisfy { !$0.isSelected && $0.source.isAssistant && $0.identity != nil })
        #expect(!queue.contains { $0.path.contains("Keychains") })

        #expect(assistant.usage.turns == 1)
        let thread = try #require(assistant.active)
        let saved = ThreadStore(directory: fixture.root.appendingPathComponent("app-files/assistant")).thread(thread)
        #expect(saved?.turns == 1)
        #expect(saved?.title.hasPrefix("Please suggest") == true)

        // A second message reuses the same live session.
        assistant.send("What uses the most space?")
        #expect(await waitUntil { !assistant.isResponding })
        let names = assistant.items.compactMap { item -> String? in if case .tool(let a) = item.kind { a.name } else { nil } }
        #expect(names == ["propose_deletion", "get_disk_overview"])
        #expect(assistant.items.contains { if case .assistant(_, false) = $0.kind { true } else { false } })
        #expect(assistant.usage.turns == 2)
    }

    @Test func stopInterruptsAStreamingReply() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture, assistant: try Self.services(fixture))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        app.model.settings.assistantConsentAccepted = true
        assistant.recheck()
        await assistant.waitForRecheck()
        assistant.send("Tell me a long story [slow]")
        #expect(await waitUntil { assistant.items.contains { if case .assistant(_, true) = $0.kind { true } else { false } } })
        assistant.stop()
        #expect(!assistant.isResponding)
        #expect(await waitUntil { assistant.items.contains { if case .notice(let text) = $0.kind { text == L10n.stopped } else { false } } })
        assistant.send("And now?")
        #expect(await waitUntil { !assistant.isResponding && assistant.usage.turns == 2 })
    }

    @Test func apiKeyLoginIsRefusedWithACard() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let script: JSONValue = ["authStatus": ["loggedIn": true, "authMethod": "api_key_helper"]]
        let app = try await AppHarness(fixture: fixture, assistant: try Self.services(fixture, script: script))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        app.model.settings.assistantConsentAccepted = true
        assistant.recheck()
        await assistant.waitForRecheck()
        assistant.send("Find big files")
        #expect(await waitUntil { assistant.refusal != nil })
        let refusal = try #require(assistant.refusal)
        #expect(refusal.refusal.keyOrigin == .keyHelper)
        #expect(refusal.reason == L10n.refusalReason(.keyHelper))
        #expect(!refusal.advice.isEmpty)
        #expect(assistant.items.contains { if case .notice(let text) = $0.kind { text == refusal.title } else { false } })
        #expect(!assistant.isResponding)
        #expect(app.model.cleanup.queue.isEmpty)
    }

    @Test func missingCLIAndDisabledStates() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture, assistant: try Self.services(fixture, claude: fixture.root.appendingPathComponent("missing-claude")))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        #expect(assistant.availability == .needsConsent, "nothing is looked for before the consent")
        app.model.settings.assistantConsentAccepted = true
        assistant.recheck()
        await assistant.waitForRecheck()
        #expect(assistant.availability == .notInstalled)
        app.model.settings.assistantEnabled = false
        #expect(assistant.availability == .disabled)
        assistant.enable()
        #expect(app.model.settings.assistantEnabled)
        await assistant.waitForRecheck()
        #expect(assistant.availability == .notInstalled)
    }

    @Test func notSignedInComesFromAuthStatus() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let script: JSONValue = ["authStatus": ["loggedIn": false]]
        let app = try await AppHarness(fixture: fixture, assistant: try Self.services(fixture, script: script))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        app.model.settings.assistantConsentAccepted = true
        assistant.recheck()
        await assistant.waitForRecheck()
        #expect(assistant.availability == .notSignedIn)
    }

    @Test func threadsSwitchAndClear() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture, assistant: try Self.services(fixture))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        app.model.settings.assistantConsentAccepted = true
        assistant.recheck()
        await assistant.waitForRecheck()
        assistant.send("Hello")
        #expect(await waitUntil { !assistant.isResponding })
        let first = try #require(assistant.active)
        let firstItems = assistant.items.count
        assistant.newThread()
        #expect(assistant.items.isEmpty)
        #expect(assistant.threads.count == 2)
        assistant.select(first)
        #expect(assistant.items.count == firstItems)
        #expect(assistant.usage.turns == 1)
        assistant.clearThreads()
        #expect(assistant.threads.isEmpty)
        #expect(ThreadStore(directory: fixture.root.appendingPathComponent("app-files/assistant")).threads.isEmpty)
    }
}
