import Foundation
import ScanKit
import Testing
@testable import RulesKit
import TestSupport

/// Expected outcome of `SafetyPolicy.check`.
enum Expect: Equatable, CustomStringConvertible {
    case blocked(BlockReason)
    case dangerous
    case allowed

    var description: String {
        switch self {
        case .blocked(let r): "blocked(\(r.rawValue))"
        case .dangerous: "dangerous"
        case .allowed: "allowed"
        }
    }

    init(_ c: Classification) {
        if let block = c.block { self = .blocked(block) } else if c.risk == .dangerous { self = .dangerous } else { self = .allowed }
    }
}

/// Every path class of PLAN 2.5.
let policyTable: [(String, Expect)] = [
    // Never: system (subtree).
    ("/System", .blocked(.systemPath)),
    ("/System/Library/Kernels/kernel", .blocked(.systemPath)),
    ("/System/Applications/Calculator.app", .blocked(.systemPath)),
    ("/System/Volumes/Preboot/abc", .blocked(.systemPath)),
    ("/usr", .blocked(.systemPath)),
    ("/usr/bin/ls", .blocked(.systemPath)),
    ("/bin/zsh", .blocked(.systemPath)),
    ("/sbin/mount", .blocked(.systemPath)),
    ("/private/var/db/receipts", .blocked(.systemPath)),
    ("/var/db/receipts", .blocked(.systemPath)),
    ("/private/var/vm/sleepimage", .blocked(.systemPath)),
    ("/private/etc/hosts", .blocked(.systemPath)),
    ("/etc/hosts", .blocked(.systemPath)),
    ("/private/var/folders/zz/abc123/C/com.example", .blocked(.systemPath)),
    ("/private/var/folders", .blocked(.systemPath)),
    ("/Library/Apple/System", .blocked(.systemPath)),
    ("/Library/Extensions/Some.kext", .blocked(.systemPath)),
    ("/Library/Keychains/System.keychain", .blocked(.systemPath)),
    ("/Library/Preferences/SystemConfiguration/preferences.plist", .blocked(.systemPath)),
    ("/dev/disk0", .blocked(.systemPath)),
    ("/cores", .blocked(.systemPath)),
    ("/.Spotlight-V100/Store-V2", .blocked(.systemPath)),
    ("/.fseventsd/0001", .blocked(.systemPath)),
    ("/.DocumentRevisions-V100/db", .blocked(.systemPath)),
    ("/.vol/1/2", .blocked(.systemPath)),
    ("/Volumes/Field Drive/.Spotlight-V100", .blocked(.systemPath)),
    ("/Applications/Foo.app/Contents/MacOS/Foo", .blocked(.systemPath)),
    ("/Applications/Foo.app/Contents", .blocked(.systemPath)),
    // Never: roots (exact).
    ("/", .blocked(.protectedRoot)),
    ("/Applications", .blocked(.protectedRoot)),
    ("/Library", .blocked(.protectedRoot)),
    ("/Users", .blocked(.protectedRoot)),
    ("/Users/someone-else", .blocked(.protectedRoot)),
    ("/Volumes", .blocked(.protectedRoot)),
    ("/Volumes/Field Drive", .blocked(.protectedRoot)),
    ("~", .blocked(.protectedRoot)),
    ("~/Library", .blocked(.protectedRoot)),
    ("~/Documents", .blocked(.protectedRoot)),
    ("~/Desktop", .blocked(.protectedRoot)),
    ("~/Downloads", .blocked(.protectedRoot)),
    ("~/Pictures", .blocked(.protectedRoot)),
    ("~/Movies", .blocked(.protectedRoot)),
    ("~/Music", .blocked(.protectedRoot)),
    ("~/Library/Caches", .blocked(.protectedRoot)),
    // Never: user data.
    ("~/Library/Keychains/login.keychain-db", .blocked(.userData)),
    ("~/Library/Mail/V10/x.emlx", .blocked(.userData)),
    ("~/Library/Messages/chat.db", .blocked(.userData)),
    ("~/Library/Photos/Libraries", .blocked(.userData)),
    ("~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", .blocked(.userData)),
    ("~/Library/Application Support/AddressBook/Sources", .blocked(.userData)),
    ("~/Library/Calendars/Calendar.sqlitedb", .blocked(.userData)),
    ("~/Library/Safari/History.db", .blocked(.userData)),
    ("~/Library/Accounts/Accounts4.sqlite", .blocked(.userData)),
    ("~/Library/Cookies/Cookies.binarycookies", .blocked(.userData)),
    ("~/Library/IdentityServices/ids.db", .blocked(.userData)),
    ("~/Library/Sharing/x", .blocked(.userData)),
    ("~/Library/Biome/streams", .blocked(.userData)),
    ("~/Library/Daemon Containers/abc", .blocked(.userData)),
    ("~/Library/Autosave Information/doc", .blocked(.userData)),
    ("~/Library/Containers/com.apple.Notes", .blocked(.userData)),
    ("~/Library/Containers/com.apple.Notes/Data/Library/x", .blocked(.userData)),
    ("~/Library/Group Containers/group.com.apple.notes", .blocked(.userData)),
    ("~/Library/Preferences/com.example.app.plist", .blocked(.userData)),
    ("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .blocked(.userData)),
    ("~/.ssh/id_ed25519", .blocked(.userData)),
    ("~/.gnupg/pubring.kbx", .blocked(.userData)),
    ("~/.config/gh/hosts.yml", .blocked(.userData)),
    ("~/.claude/projects/x.jsonl", .blocked(.userData)),
    ("~/.local/bin/claude", .blocked(.userData)),
    ("~/.local/share/claude/versions/2.1.296", .blocked(.userData)),
    ("~/.zshrc", .blocked(.userData)),
    ("~/.Trash", .blocked(.userData)),
    ("~/Library/Mobile Documents/com~apple~CloudDocs/a.txt", .blocked(.cloudSynced)),
    ("~/Library/CloudStorage/GoogleDrive-me/My Drive", .blocked(.cloudSynced)),
    // Never: backups.
    ("/Volumes/TM/Backups.backupdb/mac/2026-01-01", .blocked(.backup)),
    ("/Volumes/Field Drive/old.backupdb", .blocked(.backup)),
    ("/Volumes/.timemachine/abc/2026.backup", .blocked(.backup)),
    ("/Volumes/NAS/Mac.sparsebundle", .blocked(.backup)),
    ("/Volumes/NAS/Mac.backupbundle/bands/0", .blocked(.backup)),
    // A dangerous pattern never lifts a block from an ancestor.
    ("~/Library/Mobile Documents/com~apple~CloudDocs/Lib.photoslibrary", .blocked(.cloudSynced)),
    ("~/Library/CloudStorage/GoogleDrive-me/Lib.photoslibrary", .blocked(.cloudSynced)),
    ("~/Library/Mail/V10/Old.photoslibrary", .blocked(.userData)),
    ("/Volumes/TM/Backups.backupdb/mac/Latest/Users/x/Pictures/Lib.photoslibrary", .blocked(.backup)),
    ("/System/Library/Demo.photoslibrary", .blocked(.systemPath)),
    ("~/.config/app/Lib.photoslibrary", .blocked(.userData)),
    // Top-level dot folders are protected with their contents; B1 caches inside are exceptions.
    ("~/.aws/credentials", .blocked(.userData)),
    ("~/.kube/config", .blocked(.userData)),
    ("~/.docker/config.json", .blocked(.userData)),
    ("~/.local/share", .blocked(.userData)),
    ("~/.local/share/claude", .blocked(.userData)),
    ("~/.cache", .blocked(.userData)),
    ("~/.cache/other-tool/data", .blocked(.userData)),
    ("~/.npm", .blocked(.userData)),
    ("~/.npm/_cacache/index-v5", .allowed),
    ("~/.yarn/berry/cache/pkg.zip", .allowed),
    ("~/.bun/install/cache/x", .allowed),
    ("~/.cache/huggingface/hub", .allowed),
    ("~/.gradle/caches/8.0", .allowed),
    ("~/.m2/repository/org", .allowed),
    ("~/.cargo/registry/cache", .allowed),
    ("~/.ollama/models/blobs", .allowed),
    ("~/.lmstudio/models/qwen", .allowed),
    ("~/.pnpm-store/v3", .allowed),
    // Dangerous.
    ("~/Pictures/Photos Library.photoslibrary", .dangerous),
    ("~/Library/Application Support/MobileSync/Backup/00008101-abc", .dangerous),
    ("~/Library/Application Support/Google/Chrome/Default", .dangerous),
    ("~/Library/Application Support/Firefox/Profiles/abc.default", .dangerous),
    // Allowed (exceptions and ordinary items).
    ("/usr/local/bin/tool", .allowed),
    ("/private/var/log/system.log", .allowed),
    ("/var/log/install.log", .allowed),
    ("/private/var/tmp/x", .allowed),
    ("/private/tmp/x", .allowed),
    ("/tmp/x", .allowed),
    ("/cores/core.123", .allowed),
    ("/Applications/Foo.app", .allowed),
    ("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/doc.pdf", .allowed),
    ("~/Library/Containers/com.docker.docker", .allowed),
    ("~/Library/Caches/com.spotify.client", .allowed),
    ("~/Projects/site/node_modules", .allowed),
    ("~/.npm/_cacache", .allowed),
    ("~/.cache/uv", .allowed),
    ("~/.cache", .blocked(.userData)),
    ("~/.pnpm-store", .allowed),
    ("~/.Trash/old.zip", .allowed),
    ("~/Documents/report.pdf", .allowed),
]

@Suite("SafetyPolicy")
struct SafetyPolicyTests {
    func runTable(home: String) {
        let policy = SafetyPolicy(home: home)
        for (pattern, expected) in policyTable {
            for path in variants(expand(pattern, home: home)) {
                let got = Expect(policy.check(path: path, isDirectory: true, volume: nil))
                #expect(got == expected, "\(path) with home \(home): got \(got), expected \(expected)")
            }
        }
    }

    @Test func tableWithVirtualHome() {
        runTable(home: virtualHome)
    }

    @Test func tableWithFixtureHome() throws {
        // The fixture home lives under $TMPDIR (/private/var/folders), which is itself protected.
        try withFixtureHome { _, home in runTable(home: home) }
    }

    @Test func fixtureAreaOutsideHomeStaysProtected() throws {
        try withFixtureHome { fx, home in
            let policy = SafetyPolicy(home: home)
            let outside = try fx.file("work/a.bin", size: 16).path
            #expect(policy.check(path: outside, isDirectory: false, volume: nil).block == .systemPath)
        }
    }

    @Test func symlinkedParentCannotEscape() throws {
        try withFixtureHome { fx, home in
            try fx.dir("home/Library/Keychains")
            try fx.symlink("home/Library/Caches/evil", to: "/System")
            try fx.symlink("home/Library/Caches/keys", to: home + "/Library/Keychains")
            let policy = SafetyPolicy(home: home)
            // Through the link the real target is judged.
            #expect(policy.check(path: home + "/Library/Caches/evil/Library/Frameworks", isDirectory: true, volume: nil).block == .systemPath)
            #expect(policy.check(path: home + "/Library/Caches/keys/login.keychain-db", isDirectory: false, volume: nil).block == .userData)
            // The link itself is an ordinary cache item: removing it removes only the link.
            #expect(policy.check(path: home + "/Library/Caches/evil", isDirectory: false, volume: nil).block == nil)
        }
    }

    @Test func scanRootIsProtectedButNotItsContents() {
        let root = virtualHome + "/Projects"
        let policy = SafetyPolicy(home: virtualHome, scanRoot: root)
        #expect(policy.check(path: root, isDirectory: true, volume: nil).block == .scanRoot)
        #expect(policy.check(path: "/System/Volumes/Data" + root, isDirectory: true, volume: nil).block == .scanRoot)
        #expect(policy.check(path: root + "/site", isDirectory: true, volume: nil).block == nil)
        let more = SafetyPolicy(home: virtualHome).addingScanRoot(root)
        #expect(more.check(path: root, isDirectory: true, volume: nil).block == .scanRoot)
    }

    @Test func readOnlyVolumeAndVolumeRoot() {
        let policy = SafetyPolicy(home: virtualHome)
        let ro = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/Disc"), name: "Disc", kind: .removable, fsType: "cd9660", capacity: 1, available: 0, availableImportant: 0, isReadOnly: true)
        #expect(policy.check(path: "/Volumes/Disc/a.txt", isDirectory: false, volume: ro).block == .readOnlyVolume)
        let rw = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/Work"), name: "Work", kind: .external, fsType: "apfs", capacity: 1, available: 1, availableImportant: 1)
        #expect(policy.check(path: "/Volumes/Work", isDirectory: true, volume: rw).block == .protectedRoot)
        #expect(policy.check(path: "/Volumes/Work/old", isDirectory: true, volume: rw).block == nil)
    }

    @Test func relativeAndDotDotPaths() {
        let policy = SafetyPolicy(home: virtualHome)
        #expect(policy.check(path: "Library/Caches/x", isDirectory: true, volume: nil).block == .notInScan)
        #expect(policy.check(path: virtualHome + "/Library/Caches/../Keychains/x", isDirectory: false, volume: nil).block == .userData)
        #expect(policy.check(path: "/usr/local/../bin/x", isDirectory: false, volume: nil).block == .systemPath)
    }

    @Test func protectedPathsInsideAFolder() {
        let policy = SafetyPolicy(home: virtualHome)
        let support = virtualHome + "/Library/Application Support"
        let mobile = policy.protectedDescendant(of: support + "/MobileSync")
        #expect(mobile?.classification.risk == .dangerous)
        #expect(mobile?.path == support + "/MobileSync/Backup")
        #expect(policy.protectedDescendant(of: support + "/Google")?.path == support + "/Google/Chrome")
        // Blocks are reported before dangerous entries.
        #expect(policy.protectedDescendant(of: support)?.isBlocked == true)
        #expect(policy.protectedDescendant(of: virtualHome + "/.local")?.classification.block == .userData)
        #expect(policy.protectedDescendant(of: "/Volumes/Field Drive")?.classification.block == .systemPath)
        #expect(policy.protectedDescendant(of: "/System/Volumes/Data" + support + "/Google")?.classification.risk == .dangerous)
        #expect(policy.protectedDescendant(of: virtualHome + "/Projects") == nil)
        #expect(policy.protectedDescendant(of: support + "/Slack") == nil)
    }

    @Test func nestedDirectoryPatterns() {
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Trip.photoslibrary", parentName: "Old")?.risk == .dangerous)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Backups.backupdb", parentName: "Stuff")?.block == .backup)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Mac.backupbundle", parentName: nil)?.block == .backup)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Backup", parentName: "MobileSync")?.risk == .dangerous)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Chrome", parentName: "Google")?.risk == .dangerous)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Profiles", parentName: "Firefox")?.risk == .dangerous)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Backup", parentName: "Projects") == nil)
        #expect(SafetyPolicy.nestedDirectoryClass(name: "Tool.app", parentName: "Apps") == nil)
    }

    @Test func blockMessagesExistForEveryReason() {
        for reason in BlockReason.allCases {
            #expect(!reason.message.isEmpty)
            #expect(!reason.message.contains("\u{2014}") && !reason.message.contains("\u{2013}"))
        }
    }
}
