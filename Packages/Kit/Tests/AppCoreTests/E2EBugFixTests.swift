import Foundation
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Product bugs found by the E2E suite (Task 7 report, PB-1 to PB-5).
@Suite("E2E product bug fixes", .serialized)
@MainActor
struct E2EBugFixTests {
    /// PB-5: a paused countdown deletes nothing, keeps its seconds, and runs only after a resume.
    @Test func pausedCountdownDeletesNothingUntilResumed() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let notes = try fixture.node("home/Downloads/notes.txt")
        cleanup.add(fixture.tree.summary(of: notes), source: .user)

        cleanup.requestRun(mode: .permanent)
        #expect(cleanup.countdownRemaining == CleanupModel.countdownSeconds)
        try await Task.sleep(for: .milliseconds(1200))
        cleanup.pauseCountdown()
        #expect(cleanup.isCountdownPaused)
        let held = try #require(cleanup.countdownRemaining)
        #expect(held <= CleanupModel.countdownSeconds)

        // Longer than the whole countdown: nothing moves while it is paused.
        try await Task.sleep(for: .seconds(Double(CleanupModel.countdownSeconds) + 1.5))
        #expect(cleanup.countdownRemaining == held)
        #expect(!cleanup.isRunning)
        #expect(cleanup.lastReport == nil)
        #expect(!cleanup.canRun, "a paused countdown still blocks a second run")
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/Downloads/notes.txt")))

        // A second pause is harmless; a resume continues from the held seconds and runs.
        cleanup.pauseCountdown()
        cleanup.resumeCountdown()
        #expect(!cleanup.isCountdownPaused)
        #expect(cleanup.countdownRemaining == held)
        #expect(await waitUntil(timeout: 15) { cleanup.lastReport != nil && !cleanup.isRunning })
        #expect(cleanup.lastReport?.mode == .permanent)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("home/Downloads/notes.txt")))
    }

    /// PB-5: Quit Anyway stops a paused countdown for good; resume after a stop does nothing.
    @Test func stoppingAPausedCountdownCancelsIt() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let notes = try fixture.node("home/Downloads/notes.txt")
        cleanup.add(fixture.tree.summary(of: notes), source: .user)

        cleanup.requestRun(mode: .permanent)
        cleanup.pauseCountdown()
        cleanup.stopCountdown()
        #expect(cleanup.countdownRemaining == nil)
        #expect(!cleanup.isCountdownPaused)
        cleanup.resumeCountdown()
        #expect(cleanup.countdownRemaining == nil, "nothing to resume after a stop")
        try await Task.sleep(for: .seconds(Double(CleanupModel.countdownSeconds) + 1.5))
        #expect(cleanup.lastReport == nil)
        #expect(cleanup.canRun)
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/Downloads/notes.txt")))

        // Pause and resume without a countdown are no-ops.
        cleanup.pauseCountdown()
        #expect(!cleanup.isCountdownPaused)
        cleanup.resumeCountdown()
        #expect(cleanup.countdownRemaining == nil)
    }

    /// PB-4: UI test mode asks before dropping the queue only with `-LightwellUITestQuitPrompt YES`.
    @Test func quitPromptLaunchArgument() throws {
        #expect(AppLaunchOptions().promptsBeforeDroppingQueue)
        #expect(!AppLaunchOptions(isUITestMode: true).promptsBeforeDroppingQueue)
        #expect(AppLaunchOptions(isUITestMode: true, uiTestQuitPrompt: true).promptsBeforeDroppingQueue)

        let suite = "lightwell-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "LightwellUITestMode")
        #expect(!AppLaunchOptions.current(defaults).promptsBeforeDroppingQueue)
        defaults.set(true, forKey: "LightwellUITestQuitPrompt")
        #expect(AppLaunchOptions.current(defaults).promptsBeforeDroppingQueue)
    }
}
