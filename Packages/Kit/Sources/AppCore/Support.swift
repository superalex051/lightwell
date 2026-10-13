import AIBridge
import Darwin
import Foundation
import IPCProtocol
import ScanKit
import VizKit

/// Full Disk Access state.
public enum FDAStatus: String, Sendable, Hashable, Codable {
    case granted
    case denied
    case unknown
}

/// Probes Full Disk Access (PLAN 2.8): opens a TCC-protected file read-only, without reading it.
///
/// 1. `open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)`: success is granted,
///    EPERM or EACCES is denied.
/// 2. Anything else (for example the file is missing) is ambiguous, so the same probe runs on
///    `/Library/Preferences/com.apple.TimeMachine.plist`.
/// 3. Still ambiguous: unknown.
public enum FDAProbe {
    public static let primaryPath = "/Library/Application Support/com.apple.TCC/TCC.db"
    public static let fallbackPath = "/Library/Preferences/com.apple.TimeMachine.plist"

    /// Result of probing one path.
    public enum Outcome: Sendable, Hashable {
        case readable
        case denied
        case inconclusive
    }

    public static func check() -> FDAStatus {
        check(probe: openProbe)
    }

    /// Tri-state decision from an injectable probe (tests).
    public static func check(probe: (String) -> Outcome) -> FDAStatus {
        switch probe(primaryPath) {
        case .readable: return .granted
        case .denied: return .denied
        case .inconclusive:
            switch probe(fallbackPath) {
            case .readable: return .granted
            case .denied: return .denied
            case .inconclusive: return .unknown
            }
        }
    }

    /// Opens `path` read-only and closes it right away. Nothing is read.
    public static func openProbe(_ path: String) -> Outcome {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        return outcome(errno: errno)
    }

    static func outcome(errno code: Int32) -> Outcome {
        code == EPERM || code == EACCES ? .denied : .inconclusive
    }
}

/// User settings (PLAN 2.10 Settings screen), persisted as JSON in `UserDefaults` by `SettingsStore`.
public struct AppSettings: Sendable, Hashable, Codable {
    public var purgeableCountedAsFree: Bool
    public var notifyWhenScanFinishes: Bool
    public var excludedPaths: [String]
    public var countClonesOnce: Bool
    /// `nil` = automatic worker count.
    public var scanWorkers: Int?
    public var assistantEnabled: Bool
    public var claudePathOverride: String?
    public var assistantModel: String?
    public var assistantMaxTurns: Int
    /// Per-session spending cap in integer cents.
    public var assistantBudgetCents: Int
    /// Added: refuse sessions that would bill an API key instead of the CLI login (PLAN 3.2b, default on).
    public var blockAPIKeys: Bool
    /// Added: the user accepted the assistant privacy consent (PLAN 3.11).
    public var assistantConsentAccepted: Bool
    /// Added: per-thread cumulative token guard (input plus output, PLAN 3.2b), default 300k.
    public var assistantTokenGuard: Int
    /// Added: the first-run Full Disk Access onboarding was shown (finished or skipped).
    public var onboardingCompleted: Bool

    public static let defaultTokenGuard = 300_000

    public init(
        purgeableCountedAsFree: Bool = false,
        notifyWhenScanFinishes: Bool = true,
        excludedPaths: [String] = [],
        countClonesOnce: Bool = true,
        scanWorkers: Int? = nil,
        assistantEnabled: Bool = true,
        claudePathOverride: String? = nil,
        assistantModel: String? = nil,
        assistantMaxTurns: Int = 12,
        assistantBudgetCents: Int = 50,
        blockAPIKeys: Bool = true,
        assistantConsentAccepted: Bool = false,
        assistantTokenGuard: Int = AppSettings.defaultTokenGuard,
        onboardingCompleted: Bool = false
    ) {
        self.purgeableCountedAsFree = purgeableCountedAsFree
        self.notifyWhenScanFinishes = notifyWhenScanFinishes
        self.excludedPaths = excludedPaths
        self.countClonesOnce = countClonesOnce
        self.scanWorkers = scanWorkers
        self.assistantEnabled = assistantEnabled
        self.claudePathOverride = claudePathOverride
        self.assistantModel = assistantModel
        self.assistantMaxTurns = assistantMaxTurns
        self.assistantBudgetCents = assistantBudgetCents
        self.blockAPIKeys = blockAPIKeys
        self.assistantConsentAccepted = assistantConsentAccepted
        self.assistantTokenGuard = assistantTokenGuard
        self.onboardingCompleted = onboardingCompleted
    }

    enum CodingKeys: String, CodingKey {
        case purgeableCountedAsFree, notifyWhenScanFinishes, excludedPaths, countClonesOnce, scanWorkers
        case assistantEnabled, claudePathOverride, assistantModel, assistantMaxTurns, assistantBudgetCents
        case blockAPIKeys, assistantConsentAccepted, assistantTokenGuard, onboardingCompleted
    }

    /// Every key is optional, so settings saved by an older build (or a newer one) still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        purgeableCountedAsFree = try c.decodeIfPresent(Bool.self, forKey: .purgeableCountedAsFree) ?? d.purgeableCountedAsFree
        notifyWhenScanFinishes = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenScanFinishes) ?? d.notifyWhenScanFinishes
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? d.excludedPaths
        countClonesOnce = try c.decodeIfPresent(Bool.self, forKey: .countClonesOnce) ?? d.countClonesOnce
        scanWorkers = try c.decodeIfPresent(Int.self, forKey: .scanWorkers)
        assistantEnabled = try c.decodeIfPresent(Bool.self, forKey: .assistantEnabled) ?? d.assistantEnabled
        claudePathOverride = try c.decodeIfPresent(String.self, forKey: .claudePathOverride)
        assistantModel = try c.decodeIfPresent(String.self, forKey: .assistantModel)
        assistantMaxTurns = try c.decodeIfPresent(Int.self, forKey: .assistantMaxTurns) ?? d.assistantMaxTurns
        assistantBudgetCents = try c.decodeIfPresent(Int.self, forKey: .assistantBudgetCents) ?? d.assistantBudgetCents
        blockAPIKeys = try c.decodeIfPresent(Bool.self, forKey: .blockAPIKeys) ?? d.blockAPIKeys
        assistantConsentAccepted = try c.decodeIfPresent(Bool.self, forKey: .assistantConsentAccepted) ?? d.assistantConsentAccepted
        assistantTokenGuard = try c.decodeIfPresent(Int.self, forKey: .assistantTokenGuard) ?? d.assistantTokenGuard
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
    }
}

/// Saves `AppSettings` as one JSON value in `UserDefaults`. A store without defaults keeps nothing
/// (UI test mode and previews), so tests never touch the user's settings.
@MainActor
public final class SettingsStore {
    public static let key = "LightwellSettings.v1"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// A store that keeps nothing.
    public static var volatile: SettingsStore { SettingsStore(defaults: nil) }

    public var isPersistent: Bool { defaults != nil }

    public func load() -> AppSettings {
        guard let data = defaults?.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let defaults, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Launch arguments used by UI tests (PLAN 5.3):
/// `-LightwellUITestMode YES -LightwellFixtureRoot <dir> -LightwellFakeClaude <path>`.
public struct AppLaunchOptions: Sendable, Hashable {
    public var isUITestMode: Bool
    public var fixtureRoot: URL?
    public var fakeClaude: URL?
    /// `-LightwellUITestQuitPrompt YES`: UI test mode keeps the quit prompt for a non-empty
    /// queue (normally skipped there so test teardown never waits on an alert).
    public var uiTestQuitPrompt: Bool
    /// `-LightwellUITestDroppedEvents YES`: UI test mode feeds the live refresh a dropped-events
    /// notice right after each scan, so the postponed full refresh (and Refresh Now) can be tested.
    public var uiTestDroppedEvents: Bool

    public init(isUITestMode: Bool = false, fixtureRoot: URL? = nil, fakeClaude: URL? = nil, uiTestQuitPrompt: Bool = false, uiTestDroppedEvents: Bool = false) {
        self.isUITestMode = isUITestMode
        self.fixtureRoot = fixtureRoot
        self.fakeClaude = fakeClaude
        self.uiTestQuitPrompt = uiTestQuitPrompt
        self.uiTestDroppedEvents = uiTestDroppedEvents
    }

    /// Reads the arguments from `UserDefaults` (the argument domain).
    public static func current(_ defaults: UserDefaults = .standard) -> AppLaunchOptions {
        AppLaunchOptions(
            isUITestMode: defaults.bool(forKey: "LightwellUITestMode"),
            fixtureRoot: defaults.string(forKey: "LightwellFixtureRoot").map { URL(fileURLWithPath: $0) },
            fakeClaude: defaults.string(forKey: "LightwellFakeClaude").map { URL(fileURLWithPath: $0) },
            uiTestQuitPrompt: defaults.bool(forKey: "LightwellUITestQuitPrompt"),
            uiTestDroppedEvents: defaults.bool(forKey: "LightwellUITestDroppedEvents")
        )
    }

    /// Whether Cmd+Q asks before dropping a non-empty cleanup queue: always in normal use, and in
    /// UI test mode only with `-LightwellUITestQuitPrompt YES`.
    public var promptsBeforeDroppingQueue: Bool { !isUITestMode || uiTestQuitPrompt }

    /// Fixture mode is on only with the test flag and a fixture root.
    public var usesFixture: Bool { isUITestMode && fixtureRoot != nil }

    /// `<fixture>/home`: the home folder the rules and the safety policy see in UI test mode.
    public var fixtureHome: URL? {
        guard isUITestMode, let fixtureRoot else { return nil }
        return fixtureRoot.appendingPathComponent("home", isDirectory: true)
    }
}

/// Adapts any `TreeReading` to VizKit's `MapDataSource`. Build one per tree and keep it: the map's
/// layout cache is keyed by `mapIdentityObject` (the tree) and `mapRevision` (bumped when categories
/// change), so a kept source never re-lays out on unrelated updates.
public final class TreeMapSource: MapDataSource {
    public let tree: any TreeReading
    private var category: @Sendable (NodeID) -> String?
    public private(set) var mapRevision: UInt64 = 0

    public init(tree: any TreeReading, category: @escaping @Sendable (NodeID) -> String? = { _ in nil }) {
        self.tree = tree
        self.category = category
    }

    /// Replaces the category lookup (for example when RulesKit categories arrive) and bumps the revision.
    public func updateCategories(_ category: @escaping @Sendable (NodeID) -> String?) {
        self.category = category
        mapRevision &+= 1
    }

    public var mapIdentityObject: AnyObject { tree }
    public var generation: UInt64 { tree.generation }
    public func name(_ id: MapNodeID) -> String { tree.name(id) }
    public func size(_ id: MapNodeID) -> UInt64 { tree.size(id) }
    public func children(_ id: MapNodeID) -> [MapNodeID] { tree.children(id) }
    public func mapCategory(_ id: MapNodeID) -> String? { category(id) }
    public func mapIsContainer(_ id: MapNodeID) -> Bool {
        let flags = tree.flags(id)
        return flags.contains(.directory) && !flags.contains(.package) && !tree.children(id).isEmpty
    }
    public func mapIsLocked(_ id: MapNodeID) -> Bool { tree.flags(id).contains(.restricted) }
}
