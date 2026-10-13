import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Task 9 item 4: no claude process or login shell before the assistant consent.
@Suite("Assistant consent gates the CLI", .serialized)
@MainActor
struct FinalReviewConsentTests {
    // MARK: Item 4: nothing runs before the consent

    /// A stand-in `claude` that leaves a marker file each time it runs.
    static func markingCLI(_ fixture: HomeFixture) throws -> (cli: URL, marker: URL) {
        let marker = fixture.root.appendingPathComponent("cli-ran")
        let cli = fixture.root.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli, marker)
    }

    @Test func theCLIIsNotStartedBeforeTheConsent() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let (cli, marker) = try Self.markingCLI(fixture)
        let app = try await AppHarness(fixture: fixture, assistant: try AssistantModelTests.services(fixture, claude: cli))
        let assistant = app.model.assistant
        defer { assistant.shutdown() }
        #expect(assistant.availability == .needsConsent)
        assistant.checkIfNeeded()
        assistant.recheck()
        await assistant.waitForRecheck()
        #expect(assistant.availability == .needsConsent)
        #expect(!assistant.hasLookedForCLI)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no claude process before the consent")

        assistant.acceptConsent()
        await assistant.waitForRecheck()
        #expect(assistant.hasLookedForCLI)
        #expect(FileManager.default.fileExists(atPath: marker.path), "the CLI is looked for after the consent")
    }

    @Test func afterTheConsentTheCLIIsLookedForWhenTheAssistantIsShown() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let (cli, marker) = try Self.markingCLI(fixture)
        let model = AppModel(
            cleanup: CleanupModel(configuration: .fixture(root: fixture.root, home: fixture.home)),
            settings: AppSettings(assistantConsentAccepted: true),
            home: fixture.home
        )
        model.connect(assistantServices: try AssistantModelTests.services(fixture, claude: cli), snapshots: .disabled, metadata: .none)
        let assistant = model.assistant
        defer { model.shutdown() }
        #expect(assistant.availability == .checking)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "nothing runs at launch")

        assistant.checkIfNeeded()
        await assistant.waitForRecheck()
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(assistant.availability != .checking, "the check ran to the end")
    }
}
