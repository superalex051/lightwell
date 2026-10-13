import Foundation
import ScanKit
import Testing
@testable import RulesKit
import TestSupport

@Suite("RuleEngine.categories")
struct CategoryTests {
    typealias E = InMemoryTree.Entry

    static func homeTree(root: String = virtualHome) -> InMemoryTree {
        InMemoryTree(rootPath: root, entries: [
            .dir("Library", [
                .dir("Caches", [
                    .dir("com.spotify.client", [.file("data.bin", 1_000)]),
                    .dir("Homebrew", [.file("wget.tar.gz", 500)]),
                    .dir("com.apple.Safari", [.file("cache.db", 200)]),
                    .dir("com.apple.dt.Xcode", [.file("index", 300)]),
                ]),
                .dir("Developer", [.dir("Xcode", [
                    .dir("DerivedData", [.dir("A-abc", [.file("x.o", 100)]), .dir("B-def", [.file("y.o", 50)])]),
                    .dir("iOS DeviceSupport", [.dir("17.0 (21A)", [.file("s", 10)]), .dir("18.0 (22A)", [.file("s", 20)])]),
                    .dir("Archives", [.dir("2025-01-01", [.file("a", 40)]), .dir("2026-09-01", [.file("b", 30)])]),
                ])]),
                .dir("Mobile Documents", [.dir("proj", [.file("package.json", 1), .dir("node_modules", [.file("m", 60)])])]),
            ]),
            .dir("Projects", [
                .dir("site", [
                    .file("package.json", 1),
                    .dir("node_modules", [
                        .file("a.js", 400),
                        .dir("foo", [.file("package.json", 1), .dir("node_modules", [.file("b.js", 50)])]),
                    ]),
                ]),
                .dir("loose", [.dir("node_modules", [.file("c.js", 70)])]),
            ]),
            .dir("Downloads", [
                .file("old.dmg", 900), .file("new.dmg", 800), .file("notes.txt", 5),
                .dir("proj", [.file("package.json", 1), .dir("node_modules", [.file("e.js", 30)])]),
                .dir("Old Mac", [.file("notes", 3), .package("Trip.photoslibrary", [.file("db", 700)])]),
            ]),
            .dir(".Trash", [.dir("proj", [.file("package.json", 1), .file("readme", 9), .dir("node_modules", [.file("d.js", 90)])])]),
            .dir("Pictures", [.package("Photos Library.photoslibrary", [.file("db", 2_000)])]),
        ])
    }

    static func metadata(root: String = virtualHome) -> FakeMetadata {
        FakeMetadata(
            modified: [
                root + "/Library/Developer/Xcode/Archives/2025-01-01": daysAgo(300),
                root + "/Library/Developer/Xcode/Archives/2026-09-01": daysAgo(20),
                root + "/Projects/site": daysAgo(200),
                root + "/Projects/site/package.json": daysAgo(90),
                root + "/.Trash/proj": daysAgo(10),
            ],
            added: [root + "/Downloads/old.dmg": daysAgo(60), root + "/Downloads/new.dmg": daysAgo(2)]
        )
    }

    func categories(_ tree: InMemoryTree, root: String = virtualHome) -> [String: CategoryResult] {
        let engine = RuleEngine(home: virtualHome, metadata: Self.metadata(root: root), now: { fixedNow })
        return Dictionary(uniqueKeysWithValues: engine.categories(in: tree).map { ($0.ruleID, $0) })
    }

    func names(_ result: CategoryResult?, _ tree: InMemoryTree) -> [String] {
        (result?.nodes ?? []).map { tree.path($0).replacingOccurrences(of: virtualHome + "/", with: "~/") }
    }

    @Test func aggregatesPerRule() {
        let tree = Self.homeTree()
        let c = categories(tree)
        #expect(names(c["caches.user"], tree) == ["~/Library/Caches/com.spotify.client"])
        #expect(c["caches.user"]?.bytes == 1_000)
        #expect(names(c["homebrew.cache"], tree) == ["~/Library/Caches/Homebrew"])
        #expect(names(c["caches.apple"], tree) == ["~/Library/Caches/com.apple.Safari"])
        #expect(names(c["xcode.caches"], tree) == ["~/Library/Caches/com.apple.dt.Xcode"])
        #expect(c["xcode.deriveddata"]?.bytes == 150)
        #expect(c["xcode.deriveddata"]?.count == 2)
        #expect(c["xcode.deriveddata"]?.risk == .safe)
        // keepNewest 1: the newest device support folder stays out of the category.
        #expect(names(c["xcode.devicesupport"], tree) == ["~/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A)"])
        // minAgeDays 180: only the old archive.
        #expect(names(c["xcode.archives"], tree) == ["~/Library/Developer/Xcode/Archives/2025-01-01"])
        #expect(c["xcode.archives"]?.ageDaysByNode.values.first == 300)
    }

    @Test func detectorsFindArtifactsAndInstallers() {
        let tree = Self.homeTree()
        let c = categories(tree)
        // Topmost node_modules only (the nested one inside foo is part of it); loose has no marker;
        // the one in iCloud Drive is protected; the one inside a Trash item is not offered (moving
        // it to the Trash frees nothing); the one in Downloads/proj is carved out of that item.
        #expect(Set(names(c["dev.artifacts"], tree)) == ["~/Projects/site/node_modules", "~/Downloads/proj/node_modules"])
        let site = tree.node(atPath: virtualHome + "/Projects/site/node_modules")!
        #expect(c["dev.artifacts"]?.ageDaysByNode[site] == 90)
        #expect(c["dev.artifacts"]?.bytes == 451 + 30)
        #expect(names(c["downloads.installers"], tree) == ["~/Downloads/old.dmg"])
        // "Old Mac" holds a Photos library, so it is never offered as a review item.
        #expect(Set(names(c["downloads.items"], tree)) == ["~/Downloads/new.dmg", "~/Downloads/notes.txt", "~/Downloads/proj"])
        #expect(c["downloads.items"]?.bytes == 800 + 5 + 1)
    }

    @Test func droppedNestedRegionsGiveTheirBytesBack() {
        let rules = [
            Rule(id: "outer.area", categoryID: "c", risk: .review, title: "Outer", explanation: "E",
                 match: [RuleMatch(path: "~/Area", kind: .subtree)], action: .trash),
            Rule(id: "inner.old", categoryID: "c", risk: .safe, title: "Inner", explanation: "E",
                 match: [RuleMatch(path: "~/Area/Inner", kind: .childrenOf)], action: .trash, minAgeDays: 10),
        ]
        let tree = InMemoryTree(rootPath: virtualHome, entries: [
            .dir("Area", [.file("own", 5), .dir("Inner", [.dir("old", [.file("a", 20)]), .dir("new", [.file("b", 7)])])]),
        ])
        let meta = FakeMetadata(modified: [
            virtualHome + "/Area/Inner/old": daysAgo(30),
            virtualHome + "/Area/Inner/new": daysAgo(1),
        ])
        let engine = RuleEngine(home: virtualHome, rules: rules, metadata: meta, now: { fixedNow })
        let c = Dictionary(uniqueKeysWithValues: engine.categories(in: tree).map { ($0.ruleID, $0) })
        #expect(names(c["inner.old"], tree) == ["~/Area/Inner/old"])
        #expect(c["inner.old"]?.bytes == 20)
        // The too-new child went back to the enclosing item: 32 total minus the 20 still offered.
        #expect(c["outer.area"]?.bytes == 12)
    }

    @Test func protectedDescendantsFromScanData() {
        let tree = InMemoryTree(rootPath: virtualHome, entries: [
            .dir("Library", [.dir("Application Support", [
                .dir("MobileSync", [.dir("Backup", [.dir("00008101", [.file("Manifest.db", 10)])])]),
                .dir("Google", [.dir("Chrome", [.dir("Default", [.file("History", 10)])])]),
                .dir("Slack", [.dir("Cache", [.file("x", 10)])]),
            ])]),
            .dir("Documents", [.dir("Old", [.file("a", 1), .package("Trip.photoslibrary", [.dir("database", [.file("db", 10)])])])]),
            .dir("Archive", [.dir("Stuff", [.dir("Backups.backupdb", [.dir("mac", [.file("x", 1)])])])]),
            .dir("Downloads", [.dir("Apps", [.package("Tool.app", [.dir("Contents", [.file("bin", 10)])])])]),
            .dir(".local", [.dir("share", [.dir("claude", [.file("v", 1)])])]),
        ])
        let engine = RuleEngine(home: virtualHome, metadata: FakeMetadata())
        func check(_ relative: String) -> ProtectedDescendant? {
            engine.protectedDescendant(of: tree.node(atPath: virtualHome + "/" + relative)!, in: tree)
        }
        #expect(check("Library/Application Support/MobileSync")?.classification.risk == .dangerous)
        #expect(check("Library/Application Support/MobileSync")?.path == virtualHome + "/Library/Application Support/MobileSync/Backup")
        #expect(check("Library/Application Support/Google")?.classification.risk == .dangerous)
        #expect(check("Documents/Old")?.classification.risk == .dangerous)
        #expect(check("Documents/Old")?.path == virtualHome + "/Documents/Old/Trip.photoslibrary")
        #expect(check("Archive/Stuff")?.classification.block == .backup)
        #expect(check(".local/share")?.classification.block == .userData)
        #expect(check("Library/Application Support/Slack") == nil)
        // A whole app bundle is fine to remove; its internals are not "protected descendants".
        #expect(check("Downloads/Apps") == nil)
    }

    @Test func nestedMatchesAreNeverDoubleCounted() {
        let tree = Self.homeTree()
        let results = RuleEngine(home: virtualHome, metadata: Self.metadata(), now: { fixedNow }).categories(in: tree)
        let c = Dictionary(uniqueKeysWithValues: results.map { ($0.ruleID, $0) })
        // The Trash item keeps all its bytes (nothing inside it is offered separately).
        #expect(names(c["trash.items"], tree) == ["~/.Trash/proj"])
        #expect(c["trash.items"]?.bytes == 100)
        // No node is listed twice, and no listed node contains another listed node of the same rule.
        var seen: Set<NodeID> = []
        for result in results {
            for node in result.nodes {
                #expect(seen.insert(node).inserted, "node listed twice")
                for other in result.nodes where other != node {
                    #expect(!tree.ancestry(of: other).contains(node), "nested nodes in \(result.ruleID)")
                }
            }
        }
        // Total of trash categories never exceeds the tree size.
        let total = results.filter { $0.action == .trash }.reduce(UInt64(0)) { $0 + $1.bytes }
        #expect(total <= tree.size(tree.root))
    }

    @Test func protectedAndGuideItems() {
        let tree = Self.homeTree()
        let c = categories(tree)
        #expect(names(c["icloud.drive"], tree) == ["~/Library/Mobile Documents"])
        #expect(c["icloud.drive"]?.action == .guide)
        #expect(names(c["photos.library"], tree) == ["~/Pictures/Photos Library.photoslibrary"])
        #expect(c["photos.library"]?.risk == .dangerous)
        #expect(!names(c["dev.artifacts"], tree).contains { $0.contains("Mobile Documents") })
    }

    @Test func rootInsideARuleOffersItsChildren() {
        let root = virtualHome + "/Library/Caches/Homebrew"
        let tree = InMemoryTree(rootPath: root, entries: [.dir("downloads", [.file("a", 10)]), .dir("api", [.file("b", 5)])])
        let c = categories(tree, root: root)
        #expect(c["homebrew.cache"]?.count == 2)
        #expect(c["homebrew.cache"]?.bytes == 15)
        #expect(!(c["homebrew.cache"]?.nodes.contains(tree.root) ?? true))

        let cachesRoot = virtualHome + "/Library/Caches"
        let caches = InMemoryTree(rootPath: cachesRoot, entries: [.dir("com.x", [.file("a", 7)])])
        #expect(categories(caches, root: cachesRoot)["caches.user"]?.bytes == 7)
    }

    @Test func dataVolumePathsMatchTheSameRules() {
        let dataRoot = "/System/Volumes/Data" + virtualHome
        let tree = Self.homeTree(root: dataRoot)
        let engine = RuleEngine(home: virtualHome, metadata: FakeMetadata(), now: { fixedNow })
        let ids = Set(engine.categories(in: tree).map(\.ruleID))
        #expect(ids.isSuperset(of: ["caches.user", "homebrew.cache", "xcode.deriveddata", "dev.artifacts", "downloads.items"]))

        // A whole-volume tree reaches home through System/Volumes/Data.
        let volume = InMemoryTree(rootPath: "/", entries: [
            .dir("System", [.dir("Volumes", [.dir("Data", [.dir("Users", [.dir("lightwell-test-home", [
                .dir("Library", [.dir("Caches", [.dir("com.x", [.file("a", 11)])])]),
            ])])])])]),
        ])
        #expect(engine.categories(in: volume).first { $0.ruleID == "caches.user" }?.bytes == 11)
    }

    @Test func categoriesOnFixtureSnapshot() throws {
        try withFixtureHome { fx, home in
            try fx.file("home/Library/Caches/com.example/blob", size: 8192)
            try fx.file("home/Code/app/package.json", size: 100)
            try fx.file("home/Code/app/node_modules/x/index.js", size: 4096)
            let tree = try InMemoryTree.snapshot(of: fx.url("home"))
            let engine = RuleEngine(home: home, metadata: LiveFileMetadata())
            let c = Dictionary(uniqueKeysWithValues: engine.categories(in: tree).map { ($0.ruleID, $0) })
            #expect(c["caches.user"]?.count == 1)
            #expect(c["dev.artifacts"]?.count == 1)
            #expect((c["dev.artifacts"]?.ageDaysByNode.values.first ?? -1) == 0)
        }
    }
}
