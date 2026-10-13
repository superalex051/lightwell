import AIBridge
import CleanupKit
import Foundation
import RulesKit
import ScanKit

/// Realistic fake content so the UI can be built and run before the engines land.
/// Everything here is fixture data (file names, sample chat), not UI copy, so it is not localized.
public enum PreviewData {
    private static let gb: UInt64 = 1_000_000_000
    private static let mb: UInt64 = 1_000_000

    public static let home = "/Users/preview"
    public static let threadID = UUID(uuidString: "6F1D2C34-8A0B-4C55-9E21-3B7A1F0D9C11")!

    // MARK: Volumes

    public static let volume = VolumeInfo(
        url: URL(fileURLWithPath: "/"),
        name: "Macintosh HD",
        kind: .internalDisk,
        fsType: "apfs",
        capacity: 994 * gb,
        available: 182 * gb,
        availableImportant: 214 * gb,
        isEncrypted: true
    )

    public static let externalVolume = VolumeInfo(
        url: URL(fileURLWithPath: "/Volumes/Field Drive"),
        name: "Field Drive",
        kind: .external,
        fsType: "apfs",
        capacity: 2_000 * gb,
        available: 1_240 * gb,
        availableImportant: 1_240 * gb,
        isRemovable: true,
        isSSD: true
    )

    public static let volumes = [volume, externalVolume]

    // MARK: Tree

    public static func tree(for target: ScanTarget) -> PreviewTree {
        switch target {
        case .volume(let volume) where volume == externalVolume:
            PreviewTree(rootPath: volume.url.path, rootName: volume.name, entries: [
                .folder("Footage", [
                    .file("A001_Interview.mov", 182 * gb),
                    .file("A002_Broll.mov", 141 * gb),
                    .file("A003_Drone.mov", 96 * gb),
                ]),
                .folder("Archive 2024", [.file("Projects.sparsebundle", 210 * gb)]),
                .file("Notes.txt", 12_000),
            ])
        case .volume(let volume):
            volumeTree(rootName: volume.name)
        case .folder(let url):
            PreviewTree(rootPath: url.path, entries: [
                .folder("Assets", [.file("hero.psd", 2 * gb), .file("logo.svg", 40_000)]),
                .folder("node_modules", [.file("bundle.js", 820 * mb), .file("cache.bin", 450 * mb)]),
                .file("render.mp4", 3 * gb),
                .file("README.md", 6_000),
            ])
        }
    }

    public static func volumeTree(rootName: String = "Macintosh HD") -> PreviewTree {
        PreviewTree(rootPath: "/", rootName: rootName, entries: [
            .folder("Users", [
                .folder("preview", [
                    .folder("Library", [
                        .folder("Developer", [
                            .folder("Xcode", [
                                .folder("DerivedData", [
                                    .folder("Lightwell-abc123", [.file("Build.db", 6 * gb), .file("Index.noindex", 3 * gb)]),
                                    .folder("Atlas-def456", [.file("Build.db", 4 * gb)]),
                                ]),
                                .folder("iOS DeviceSupport", [.file("18.4 (22E240)", 7 * gb), .file("18.2 (22C152)", 6 * gb)]),
                            ]),
                            .folder("CoreSimulator", [.folder("Devices", [.file("iPhone 16 Pro", 11 * gb), .file("iPad Air", 5 * gb)])]),
                        ]),
                        .folder("Caches", [
                            .folder("com.apple.Safari", [.file("WebKitCache", 1_400 * mb)]),
                            .folder("Homebrew", [.file("downloads", 2_100 * mb)]),
                            .folder("com.spotify.client", [.file("Data", 3_300 * mb)]),
                        ]),
                        .folder("Application Support", [
                            .folder("MobileSync", [.folder("Backup", [.file("00008110-001A", 38 * gb)])]),
                            .folder("Slack", [.file("Cache", 900 * mb)]),
                            .folder("Steam", [.folder("steamapps", [.file("common", 96 * gb)])]),
                        ]),
                        .folder("Containers", [
                            .folder("com.docker.docker", [.file("Docker.raw", 64 * gb)]),
                            .folder("com.apple.mail", [.file("Data", 9 * gb)]),
                        ]),
                        .restricted("Mail"),
                        .restricted("Messages"),
                    ]),
                    .folder("Movies", [.file("Trip to Lisbon.mov", 24 * gb), .file("Screen Recording.mov", 3 * gb)]),
                    .folder("Pictures", [.package("Photos Library.photoslibrary", [.file("originals", 268 * gb), .file("resources", 14 * gb)])]),
                    .folder("Music", [.folder("Logic", [.file("Sound Library", 64 * gb)]), .file("Podcast Masters", 22 * gb)]),
                    .folder("Documents", [
                        .folder("Taxes", [.file("2025.pdf", 4 * mb)]),
                        .file("Thesis.pages", 380 * mb),
                    ]),
                    .folder("Downloads", [
                        .file("Xcode_27.xip", 12 * gb),
                        .file("Install macOS.dmg", 14 * gb),
                        .file("photos-export.zip", 6 * gb),
                    ]),
                    .folder("Projects", [
                        .folder("web-shop", [.folder("node_modules", [.file("packages", 1_800 * mb)]), .file("src", 60 * mb)]),
                        .folder("ml-notebooks", [.folder(".venv", [.file("lib", 2_600 * mb)]), .file("data.parquet", 4 * gb)]),
                    ]),
                ]),
            ]),
            .folder("Applications", [
                .package("Xcode.app", [.file("Contents", 13 * gb)]),
                .package("Final Cut Pro.app", [.file("Contents", 6 * gb)]),
                .package("Slack.app", [.file("Contents", 500 * mb)]),
            ]),
            .folder("Library", [.folder("Application Support", [.file("GarageBand", 4 * gb)])]),
            .folder("System", [.file("Library", 18 * gb)]),
            .folder("private", [.folder("var", [.file("vm", 6 * gb)])]),
        ])
    }

    // MARK: Categories

    /// A category described by paths, resolved against whatever preview tree is shown.
    public struct CategoryFixture: Sendable {
        public var ruleID: String
        public var title: String
        public var categoryID: String
        public var risk: Risk
        public var paths: [String]
        public var action: RuleAction
        public var explanation: String
        public var commandHint: String?

        public func resolve(in tree: any TreeReading) -> CategoryResult? {
            let nodes = paths.compactMap { tree.node(atPath: $0) }
            guard !nodes.isEmpty else { return nil }
            return CategoryResult(
                ruleID: ruleID, title: title, categoryID: categoryID, risk: risk,
                bytes: nodes.reduce(0) { $0 + tree.size($1) }, count: nodes.count, nodes: nodes,
                action: action, explanation: explanation, commandHint: commandHint
            )
        }
    }

    public static let categoryFixtures: [CategoryFixture] = [
        CategoryFixture(
            ruleID: "xcode.derivedData", title: "Xcode build data", categoryID: "developer", risk: .safe,
            paths: ["\(home)/Library/Developer/Xcode/DerivedData"], action: .trash,
            explanation: "Intermediate build products. Xcode rebuilds them the next time you build."
        ),
        CategoryFixture(
            ruleID: "xcode.deviceSupport", title: "Device support files", categoryID: "developer", risk: .safe,
            paths: ["\(home)/Library/Developer/Xcode/iOS DeviceSupport"], action: .trash,
            explanation: "Debug symbols copied from devices. They come back when you connect the device again."
        ),
        CategoryFixture(
            ruleID: "user.caches", title: "App caches", categoryID: "caches", risk: .safe,
            paths: ["\(home)/Library/Caches/com.apple.Safari", "\(home)/Library/Caches/Homebrew", "\(home)/Library/Caches/com.spotify.client"],
            action: .trash, explanation: "Files apps keep to load faster. Apps recreate them as needed."
        ),
        CategoryFixture(
            ruleID: "simulator.devices", title: "Simulator devices", categoryID: "developer", risk: .review,
            paths: ["\(home)/Library/Developer/CoreSimulator/Devices"], action: .guide,
            explanation: "Simulated devices with their apps and data. Remove unused ones from Xcode.",
            commandHint: "xcrun simctl delete unavailable"
        ),
        CategoryFixture(
            ruleID: "downloads.installers", title: "Old installers", categoryID: "downloads", risk: .review,
            paths: ["\(home)/Downloads/Xcode_27.xip", "\(home)/Downloads/Install macOS.dmg"], action: .trash,
            explanation: "Disk images and archives you already installed from."
        ),
        CategoryFixture(
            ruleID: "dev.nodeModules", title: "Project dependencies", categoryID: "projects", risk: .review,
            paths: ["\(home)/Projects/web-shop/node_modules", "\(home)/Projects/ml-notebooks/.venv"], action: .trash,
            explanation: "Packages your projects can download again with their install command."
        ),
        CategoryFixture(
            ruleID: "ios.backups", title: "iPhone and iPad backups", categoryID: "appData", risk: .dangerous,
            paths: ["\(home)/Library/Application Support/MobileSync/Backup"], action: .guide,
            explanation: "Device backups may be the only copy of your data. Manage them in Finder."
        ),
    ]

    public static var categories: [CategoryResult] {
        let tree = volumeTree()
        return categoryFixtures.compactMap { $0.resolve(in: tree) }
    }

    // MARK: Queue

    public static var queue: [QueueItem] {
        [
            QueueItem(
                path: "\(home)/Library/Developer/Xcode/DerivedData", bytes: 13 * gb, freesAbout: 13 * gb,
                risk: .safe, ruleID: "xcode.derivedData", source: .category("xcode.derivedData"), isSelected: true
            ),
            QueueItem(
                path: "\(home)/Downloads/Install macOS.dmg", bytes: 14 * gb, freesAbout: 14 * gb,
                risk: .review, ruleID: "downloads.installers", source: .user, isSelected: true
            ),
            QueueItem(
                path: "\(home)/Projects/web-shop/node_modules", bytes: 1_800 * mb, freesAbout: 1_800 * mb,
                risk: .review, ruleID: "dev.nodeModules",
                source: .assistant(thread: threadID, reason: "Dependencies for a project untouched for 8 months; reinstall with npm install."),
                isSelected: false
            ),
        ]
    }

    public static var recentlyTrashed: [TrashedRecord] {
        [TrashedRecord(
            originalPath: "\(home)/Downloads/old-backup.zip",
            trashedURL: URL(fileURLWithPath: "\(home)/.Trash/old-backup.zip"),
            bytes: 2 * gb,
            date: Date(timeIntervalSince1970: 1_791_000_000)
        )]
    }

    // MARK: Assistant

    public static var threads: [ThreadRecord] {
        [
            ThreadRecord(id: threadID, title: "Make room for a new project", createdAt: Date(timeIntervalSince1970: 1_791_500_000), updatedAt: Date(timeIntervalSince1970: 1_791_500_600), sessionID: "preview-session"),
            ThreadRecord(title: "What is System Data?", createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_300)),
        ]
    }

    public static var chat: [ChatItem] {
        [
            ChatItem(kind: .user("I need about 30 GB for a new video project. What can go?")),
            ChatItem(kind: .tool(ToolActivity(id: "tool-1", name: "get_disk_overview", state: .succeeded, durationMs: 40))),
            ChatItem(kind: .tool(ToolActivity(id: "tool-2", name: "get_category_summary", state: .succeeded, durationMs: 85))),
            ChatItem(kind: .tool(ToolActivity(id: "tool-3", name: "get_largest_items", detail: "path: ~/Downloads, limit: 20", state: .succeeded, durationMs: 120))),
            ChatItem(kind: .assistant(text: "You have 182 GB free right now. The quickest wins are Xcode build data (13 GB) and two installers in Downloads (26 GB). Your iPhone backup is large too, but it may be your only copy, so I left it alone.", isStreaming: false)),
            ChatItem(kind: .tool(ToolActivity(id: "tool-4", name: "propose_deletion", detail: "3 items", state: .succeeded, durationMs: 60))),
            ChatItem(kind: .proposal(ProposalBatch(
                summary: "Build data and installers you no longer need",
                queued: [
                    ProposedItem(path: "~/Library/Developer/Xcode/DerivedData", bytes: 13 * gb, risk: .safe, reason: "Xcode rebuilds this automatically."),
                    ProposedItem(path: "~/Downloads/Xcode_27.xip", bytes: 12 * gb, risk: .review, reason: "Xcode 27 is already installed."),
                ],
                rejected: [
                    RejectedProposal(path: "~/Library/Application Support/MobileSync/Backup", block: .backup, message: BlockReason.backup.message),
                ]
            ))),
            ChatItem(kind: .assistant(text: "I added two items to your cleanup queue, unselected. Review them there; nothing is deleted until you confirm.", isStreaming: false)),
        ]
    }

    public static let usage = UsageSummary(inputTokens: 18_400, outputTokens: 1_250, costCents: 4, turns: 3)

    // MARK: Stores

    /// A fully populated app model for previews and the placeholder app.
    @MainActor
    public static func appModel(launchOptions: AppLaunchOptions = AppLaunchOptions()) -> AppModel {
        AppModel(
            volumes: volumes,
            recentFolders: [URL(fileURLWithPath: "\(home)/Projects"), URL(fileURLWithPath: "\(home)/Movies")],
            cleanup: CleanupModel(queue: queue, recentlyTrashed: recentlyTrashed, isPreview: true),
            assistant: AssistantModel(availability: .ready(version: "2.1.296"), threads: threads, active: threadID, items: chat, usage: usage),
            fda: .denied,
            settings: AppSettings(),
            launchOptions: launchOptions,
            previewTreeProvider: { tree(for: $0) },
            previewCategories: categoryFixtures
        )
    }
}

extension AppModel {
    /// Preview-backed model (SwiftUI previews and the UI test walkthrough without a fixture root).
    public static func preview(launchOptions: AppLaunchOptions = AppLaunchOptions()) -> AppModel {
        PreviewData.appModel(launchOptions: launchOptions)
    }
}
