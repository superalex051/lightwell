import Foundation
import Testing
@testable import RulesKit
import TestSupport

/// (path, rule id, risk, block) for every R3 B1 row with a path.
let classifyTable: [(String, String?, Risk, BlockReason?)] = [
    ("~/Library/Caches/com.spotify.client", "caches.user", .safe, nil),
    ("~/Library/Caches/com.spotify.client/Data/blob.bin", "caches.user", .safe, nil),
    ("~/Library/Caches/com.apple.Safari", "caches.apple", .review, nil),
    ("~/Library/Caches/CloudKit", "caches.icloud", .review, nil),
    ("~/Library/Caches/com.apple.bird/session", "caches.icloud", .review, nil),
    ("~/Library/Developer/Xcode/DerivedData/App-abcdef", "xcode.deriveddata", .safe, nil),
    ("~/Library/Developer/Xcode/Archives/2026-01-01", "xcode.archives", .review, nil),
    ("~/Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)", "xcode.devicesupport", .safe, nil),
    ("~/Library/Developer/Xcode/watchOS DeviceSupport/11.0", "xcode.devicesupport", .safe, nil),
    ("~/Library/Developer/Xcode/tvOS DeviceSupport/18.0", "xcode.devicesupport", .safe, nil),
    ("~/Library/Developer/Xcode/visionOS DeviceSupport/2.0", "xcode.devicesupport", .safe, nil),
    ("~/Library/Developer/Xcode/macOS DeviceSupport/15.0", "xcode.devicesupport", .safe, nil),
    ("~/Library/Developer/CoreSimulator/Devices/5A1F0000-0000-0000-0000-000000000000", "simulator.devices", .review, nil),
    ("/Library/Developer/CoreSimulator/Images/runtime.dmg", "simulator.runtimes", .review, nil),
    ("/Library/Developer/CoreSimulator/Volumes/iOS_22A3351", "simulator.runtimes", .review, nil),
    ("~/Library/Developer/CoreSimulator/Caches/dyld", "simulator.caches", .safe, nil),
    ("~/Library/Developer/Xcode/UserData/Previews/Simulator Devices", "xcode.previews", .safe, nil),
    ("~/Library/Developer/XCPGDevices/ABC", "xcode.previews", .safe, nil),
    ("~/Library/Caches/com.apple.dt.Xcode", "xcode.caches", .safe, nil),
    ("~/.npm/_cacache", "npm.cache", .safe, nil),
    ("~/Library/Caches/Yarn", "yarn.cache", .safe, nil),
    ("~/.yarn/berry/cache", "yarn.cache", .safe, nil),
    ("~/Library/pnpm/store", "pnpm.store", .safe, nil),
    ("~/.pnpm-store", "pnpm.store", .safe, nil),
    ("~/.bun/install/cache", "bun.cache", .safe, nil),
    ("~/Library/Caches/Homebrew", "homebrew.cache", .safe, nil),
    ("~/Library/Caches/Homebrew/downloads/abc--wget.tar.gz", "homebrew.cache", .safe, nil),
    ("~/Library/Caches/pip", "pip.cache", .safe, nil),
    ("~/.cache/uv", "uv.cache", .safe, nil),
    ("~/Library/Caches/pypoetry", "poetry.cache", .safe, nil),
    ("~/.gradle/caches", "gradle.cache", .review, nil),
    ("~/.m2/repository", "maven.repository", .review, nil),
    ("~/.cargo/registry", "cargo.registry", .review, nil),
    ("~/Library/Caches/go-build", "go.buildcache", .safe, nil),
    ("~/go/pkg/mod", "go.modcache", .review, nil),
    ("~/Library/Caches/CocoaPods", "cocoapods.cache", .safe, nil),
    ("~/Library/Caches/org.swift.swiftpm", "swiftpm.cache", .safe, nil),
    ("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "docker.disk", .review, nil),
    // A guide rule inside a protected dot folder: the guidance still shows, the files stay blocked.
    ("~/.orbstack/data", "orbstack.data", .never, .userData),
    ("~/.ollama/models", "ai.models", .review, nil),
    ("~/.cache/huggingface/hub", "ai.models", .review, nil),
    ("~/.lmstudio/models/qwen", "ai.models", .review, nil),
    ("~/.Trash/old.zip", "trash.items", .review, nil),
    ("/Volumes/Field Drive/.Trashes/501/clip.mov", "trash.items", .review, nil),
    ("~/Downloads/movie.mov", "downloads.items", .review, nil),
    ("~/Library/Application Support/MobileSync/Backup/00008101-abc", "ios.backups", .dangerous, nil),
    ("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/ABC", "mail.downloads", .safe, nil),
    ("~/Library/Messages/Attachments/ab/01", "messages.attachments", .never, .userData),
    ("~/Pictures/Photos Library.photoslibrary", "photos.library", .dangerous, nil),
    ("~/Pictures/Photos Library.photoslibrary/originals/a.heic", "photos.library", .never, .userData),
    ("~/Library/Mobile Documents/com~apple~CloudDocs/a.txt", "icloud.drive", .never, .cloudSynced),
    ("~/Library/CloudStorage/GoogleDrive-me", "cloud.providers", .never, .cloudSynced),
    ("~/Library/Logs/SomeApp", "logs.user", .safe, nil),
    ("/Library/Logs/DiagnosticReports/x.ips", "logs.system", .review, nil),
    ("/private/var/log/system.log", "logs.system", .review, nil),
    ("/var/log/install.log", "logs.system", .review, nil),
    ("/cores/core.123", "system.coredumps", .review, nil),
    ("/Applications/Foo.app", "apps.installed", .review, nil),
    ("~/Applications/Game.app", "apps.installed", .review, nil),
    ("/Applications/Xcode.app", "apps.xcode", .review, nil),
    ("/Applications/Xcode-26.0.app", "apps.xcode", .review, nil),
    ("/Applications/Foo.app/Contents/Resources/fr.lproj", "app.languagefiles", .never, .systemPath),
    ("~/Library/Application Support/Google/Chrome/Default", "browser.profiles", .dangerous, nil),
    ("/private/var/vm/sleepimage", "system.memoryfiles", .never, .systemPath),
    ("/private/var/vm/swapfile0", "system.memoryfiles", .never, .systemPath),
    ("/private/var/folders/ab/cdef123/T", "system.tempitems", .never, .systemPath),
    // Not matched by any rule.
    ("~/Documents/report.pdf", nil, .review, nil),
    ("~/Library/Caches", nil, .never, .protectedRoot),
    ("~/Library/Developer/Xcode/DerivedData", nil, .review, nil),
    ("/System/Library/CoreServices", nil, .never, .systemPath),
]

@Suite("RuleEngine.classify")
struct ClassifyTests {
    func runTable(home: String) {
        let engine = RuleEngine(home: home, metadata: FakeMetadata(), now: { fixedNow })
        for (pattern, ruleID, risk, block) in classifyTable {
            for path in variants(expand(pattern, home: home)) {
                let c = engine.classify(path: path)
                #expect(c.ruleID == ruleID && c.risk == risk && c.block == block,
                        "\(path): got \(c.ruleID ?? "nil") \(c.risk) \(c.block?.rawValue ?? "nil")")
                if let ruleID, c.ruleID == ruleID {
                    #expect(c.explanation == engine.rule(withID: ruleID)?.explanation)
                    #expect(c.categoryID == engine.rule(withID: ruleID)?.categoryID)
                }
            }
        }
    }

    @Test func b1TableVirtualHome() {
        runTable(home: virtualHome)
    }

    @Test func b1TableFixtureHome() throws {
        try withFixtureHome { _, home in runTable(home: home) }
    }

    @Test func neverRulesAlwaysCarryABlock() {
        let engine = RuleEngine(home: virtualHome, metadata: FakeMetadata())
        for (pattern, _, risk, block) in classifyTable where risk == .never {
            #expect(block != nil)
            #expect(engine.classify(path: expand(pattern, home: virtualHome)).block != nil, "\(pattern)")
        }
    }

    @Test func devArtifactsNeedTheirProjectMarker() throws {
        try withFixtureHome { fx, home in
            try fx.file("home/Projects/site/package.json", size: 10)
            try fx.file("home/Projects/site/node_modules/left-pad/index.js", size: 10)
            try fx.file("home/Projects/loose/node_modules/x.js", size: 10)
            try fx.file("home/Projects/rusty/Cargo.toml", size: 10)
            try fx.dir("home/Projects/rusty/target/debug")
            try fx.file("home/Projects/py/.venv/pyvenv.cfg", size: 10)
            try fx.file("home/Projects/ios/Podfile", size: 10)
            try fx.dir("home/Projects/ios/Pods")
            let engine = RuleEngine(home: home, metadata: LiveFileMetadata())
            #expect(engine.classify(path: home + "/Projects/site/node_modules").ruleID == "dev.artifacts")
            #expect(engine.classify(path: home + "/Projects/site/node_modules/left-pad/index.js").ruleID == "dev.artifacts")
            #expect(engine.classify(path: home + "/Projects/loose/node_modules").ruleID == nil)
            #expect(engine.classify(path: home + "/Projects/rusty/target").ruleID == "dev.artifacts")
            #expect(engine.classify(path: home + "/Projects/py/.venv").ruleID == "dev.artifacts")
            #expect(engine.classify(path: home + "/Projects/ios/Pods").ruleID == "dev.artifacts")
            #expect(engine.classify(path: home + "/Projects/site/node_modules").risk == .review)
        }
    }

    @Test func oldInstallersByAge() {
        let dl = virtualHome + "/Downloads"
        let meta = FakeMetadata(
            modified: [dl + "/fresh.pkg": daysAgo(400)],
            added: [dl + "/old.dmg": daysAgo(45), dl + "/fresh.pkg": daysAgo(3), dl + "/Tool.ZIP": daysAgo(31)]
        )
        let engine = RuleEngine(home: virtualHome, metadata: meta, now: { fixedNow })
        #expect(engine.classify(path: dl + "/old.dmg").ruleID == "downloads.installers")
        #expect(engine.classify(path: dl + "/Tool.ZIP").ruleID == "downloads.installers")
        // Added recently: the added date wins over an old modification date.
        #expect(engine.classify(path: dl + "/fresh.pkg").ruleID == "downloads.items")
        // Unknown age is never treated as old.
        #expect(engine.classify(path: dl + "/unknown.dmg").ruleID == "downloads.items")
        // Only directly inside Downloads.
        #expect(engine.classify(path: dl + "/folder/old.dmg").ruleID == "downloads.items")
    }

    static let benchmarkPaths: [String] = (0..<2_000).flatMap { i in
        [
            "\(virtualHome)/Library/Caches/com.vendor.app\(i)/data/blob\(i).bin",
            "\(virtualHome)/Library/Developer/Xcode/DerivedData/Proj-\(i)/Build/Intermediates.noindex/x.o",
            "\(virtualHome)/Documents/Folder \(i)/notes \(i).txt",
            "/Applications/App\(i).app",
            "\(virtualHome)/Library/Containers/com.apple.app\(i)/Data/Library/x",
            // Dev artifact names cost a marker lookup on disk (real lstat via LiveFileMetadata).
            "\(virtualHome)/Projects/app\(i)/node_modules/pkg/index.js",
        ]
    }

    /// Lexical path (tree paths): < 5 us per path in release.
    @Test func classifyIsFast() {
        let engine = RuleEngine(home: virtualHome, metadata: LiveFileMetadata())
        let paths = Self.benchmarkPaths
        _ = engine.classify(path: paths[0], resolveSymlinks: false)
        let elapsed = ContinuousClock().measure {
            for path in paths { _ = engine.classify(path: path, resolveSymlinks: false) }
        }
        let perPath = elapsed / paths.count
        print("classify (lexical): \(perPath) per path over \(paths.count) paths")
        #if DEBUG
        let limit = Duration.microseconds(40)
        #else
        let limit = Duration.microseconds(5)
        #endif
        #expect(perPath < limit)
    }

    /// The frozen `classify(path:)` also resolves the parent with realpath (arbitrary paths).
    @Test func classifyWithRealpathIsMeasured() {
        let engine = RuleEngine(home: virtualHome, metadata: LiveFileMetadata())
        let paths = Self.benchmarkPaths
        _ = engine.classify(path: paths[0])
        let elapsed = ContinuousClock().measure {
            for path in paths { _ = engine.classify(path: path) }
        }
        let perPath = elapsed / paths.count
        print("classify (with realpath): \(perPath) per path over \(paths.count) paths")
        #if DEBUG
        let limit = Duration.microseconds(120)
        #else
        let limit = Duration.microseconds(50)
        #endif
        #expect(perPath < limit)
    }
}
