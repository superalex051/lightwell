import CleanupKit
import Darwin
import Foundation
import RulesKit
import ScanKit
import Testing
import TestSupport
import VizKit
@testable import AppCore

@Suite("Scan session, settings, FDA probe, launch options", .serialized)
@MainActor
struct StoreTests {
    @Test func injectedTreeSessionClassifiesAndColorsTheMap() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let session = ScanSessionModel(target: .folder(fixture.root), tree: fixture.tree, services: fixture.services())
        session.startScan()
        #expect(session.state == .finished)
        let source = try #require(session.mapSource)
        #expect(source.mapIdentityObject === fixture.tree)
        let revision = session.mapRevision
        let sourceRevision = source.mapRevision
        #expect(await waitUntil { !session.isClassifying && !session.categories.isEmpty })
        #expect(session.mapRevision != revision, "categories bump the map revision")
        #expect(source.mapRevision != sourceRevision)
        #expect(session.mapSource === source, "one map source per tree")
        let app1 = try fixture.node("home/Library/Developer/Xcode/DerivedData/App-1")
        #expect(source.mapCategory(app1) == SpaceFamily.developer.rawValue)
        #expect(session.family(of: try fixture.node("home/Library/Caches/com.example.app")) == .caches)
        #expect(session.safeCategories.contains { $0.ruleID == "xcode.deriveddata" })
        #expect(session.category(covering: try fixture.node("home/Library/Developer/Xcode/DerivedData/App-1/build.o"))?.ruleID == "xcode.deriveddata")
        #expect(session.reclaimableBytes([.safe]) > 0)
        #expect(await waitUntil { session.volume != nil })
        #expect(session.summary?.hidden == 0, "folder scans show no hidden space")
    }

    @Test func navigationHistory() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let session = ScanSessionModel(target: .folder(fixture.root), tree: fixture.tree, services: fixture.services())
        session.startScan()
        let home = try fixture.node("home")
        let library = try fixture.node("home/Library")
        session.navigate(to: home)
        session.navigate(to: library)
        #expect(session.breadcrumb.count == 3)
        session.goBack()
        #expect(session.current == home)
        session.goForward()
        #expect(session.current == library)
        session.goUp()
        #expect(session.current == home)
        #expect(session.canGoBack)
    }

    @Test func stubOrRealScannerFinishesAFolderScan() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let session = ScanSessionModel(target: .folder(fixture.root), services: fixture.services())
        session.startScan()
        #expect(await waitUntil { session.state == .finished })
        let tree = try #require(session.tree)
        #expect(tree.path(tree.root) == ScanSessionModel.canonicalRoot(fixture.root), "\(tree.path(tree.root)) vs \(ScanSessionModel.canonicalRoot(fixture.root))")
        #expect(session.engine != nil)
        #expect(session.cleanupContext != nil)
    }

    @Test func fdaProbeIsTriState() {
        #expect(FDAProbe.check { _ in .readable } == .granted)
        #expect(FDAProbe.check { _ in .denied } == .denied)
        #expect(FDAProbe.check { _ in .inconclusive } == .unknown)
        #expect(FDAProbe.check { $0 == FDAProbe.primaryPath ? .inconclusive : .readable } == .granted)
        #expect(FDAProbe.check { $0 == FDAProbe.primaryPath ? .inconclusive : .denied } == .denied)
        #expect(FDAProbe.outcome(errno: EPERM) == .denied)
        #expect(FDAProbe.outcome(errno: EACCES) == .denied)
        #expect(FDAProbe.outcome(errno: ENOENT) == .inconclusive)
        // The live probe only opens and closes; whatever this machine says is a valid state.
        #expect([FDAStatus.granted, .denied, .unknown].contains(FDAProbe.check()))
    }

    @Test func settingsDecodeOlderAndPartialJSON() throws {
        let partial = Data(#"{"countClonesOnce":false,"assistantModel":"haiku"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: partial)
        #expect(!settings.countClonesOnce)
        #expect(settings.assistantModel == "haiku")
        #expect(settings.blockAPIKeys)
        #expect(settings.assistantTokenGuard == AppSettings.defaultTokenGuard)
        #expect(!settings.assistantConsentAccepted)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)

        let volatile = SettingsStore.volatile
        volatile.save(AppSettings(assistantEnabled: false))
        #expect(volatile.load() == AppSettings())
    }

    @Test func settingsChangesAreSavedByTheModel() {
        let suite = "com.alexluncan.lightwell.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let model = AppModel(settings: store.load(), settingsStore: store)
        model.settings.excludedPaths = ["/tmp/x"]
        #expect(store.load().excludedPaths == ["/tmp/x"])
    }

    @Test func launchOptionsAndTestModeWiring() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let suite = "com.alexluncan.lightwell.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: [
            "LightwellUITestMode": true,
            "LightwellFixtureRoot": fixture.root.path,
            "LightwellFakeClaude": fixture.path("no-such-fake"),
        ])
        let options = AppLaunchOptions.current(defaults)
        #expect(options.usesFixture)
        #expect(options.fixtureHome?.path == fixture.home)

        let model = AppModel.live(launchOptions: options, defaults: defaults, assistantRoot: fixture.root.appendingPathComponent("app-files"))
        defer { model.shutdown() }
        #expect(model.volumes.isEmpty)
        let canonical = ScanSessionModel.canonicalRoot(fixture.root)
        #expect(model.recentFolders.map(\.path) == [canonical])
        #expect(model.home == canonical + "/home")
        #expect(model.settings.onboardingCompleted)
        #expect(model.fda == .granted)
        model.settings.assistantModel = "haiku"
        #expect(defaults.data(forKey: SettingsStore.key) == nil, "UI test mode never saves settings")
        await model.assistant.waitForRecheck()
        #expect(model.assistant.availability == .needsConsent, "nothing runs before the consent")
        model.assistant.acceptConsent()
        await model.assistant.waitForRecheck()
        #expect(model.assistant.availability == .notInstalled, "a missing fake CLI shows the setup card")

        let session = model.startScan(.folder(fixture.root))
        #expect(await waitUntil { session.state == .finished })
        #expect(session.engine?.home == canonical + "/home")
        #expect(model.quitBlockers == QuitBlockers(queueHasItems: false, isScanning: false, isDeleting: false))
    }

    @Test func categorizerFamilies() throws {
        #expect(SpaceFamily(ruleCategory: "packages") == .caches)
        #expect(SpaceFamily(ruleCategory: "developer") == .developer)
        #expect(SpaceFamily(ruleCategory: "trash") == .system)
        #expect(SpaceFamily(ruleCategory: "cloud") == .projects)
        #expect(SpaceFamily(ruleCategory: "unknown-id") == .other)
        #expect(NodeCategorizer.heuristic(name: "Xcode.app", isTopLevel: false) == .apps)
        #expect(NodeCategorizer.heuristic(name: "System", isTopLevel: true) == .system)
        #expect(NodeCategorizer.heuristic(name: "System", isTopLevel: false) == nil)
    }
}

@Suite("Shared byte formatter")
struct ByteFormatTests {
    @Test func threeSignificantDigits() {
        #expect(ByteFormat.string(693_400_000_000) == "693 GB")
        #expect(ByteFormat.string(19_530_000_000) == "19.5 GB")
        #expect(ByteFormat.string(4_017_000_000) == "4.02 GB")
        #expect(ByteFormat.string(4_000_000_000) == "4.00 GB")
        #expect(ByteFormat.string(19_000_000_000) == "19.0 GB")
        #expect(ByteFormat.string(999_600) == "1.00 MB")
        #expect(ByteFormat.string(1_000) == "1.00 KB")
        #expect(ByteFormat.string(512) == "512 bytes")
        #expect(ByteFormat.string(1) == "1 byte")
        #expect(MapText.size(19_530_000_000) == "19.5 GB")
    }
}
