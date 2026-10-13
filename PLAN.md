# Lightwell: build plan (v1)

Native macOS disk space analyzer and cleaner with a built-in AI assistant driven by the local `claude` CLI.
License MIT. Name **Lightwell** (decided 12 Oct 2026), bundle id `com.alexluncan.lightwell`. Code below still says `AppName`/`appname`: WS0 substitutes `Lightwell`/`lightwell` everywhere. Visual direction: **design A (Daylight)** from `design/mockup.html` + `design/design-notes.md`, plus B's assistant tool log as an "Advanced" view and C's serif summary on the first-run overview. Visual specs (palette, type, materials) come from design-notes.md direction A.

Sources: private design research notes (R1 engine, R2 UI and features, R3 claude CLI and cleanup survey). The design research is not included in the public repository; the recorded CLI transcripts the tests need live, redacted, in `Packages/Kit/Tests/Fixtures/cli-samples/`.

**Clean-room rule (applies to every builder):** learn behavior from research, never copy DaisyDisk code, assets, palette, icons or wording. Write original copy. Do not open `/Applications/DaisyDisk.app` or its helper.

---

## 0. Verified on this Mac (12 Oct 2026)

| Fact | Result |
|---|---|
| Host | macOS 26.6.2 (25G83), arm64 |
| Xcode | 27.0 (27A266a), Swift 6.4, SDK `macosx27.0` (only macOS SDK). Deployment target set to **26.0** so builds run on 26.6 |
| XcodeGen | 2.46.0 at `/opt/homebrew/bin/xcodegen` (already installed). Tuist, mint: not installed |
| Signing identity | An Apple Development identity (team id in your local `Signing.local.xcconfig`) |
| Headless probe (`/tmp/appname-probe`, throwaway) | XcodeGen app + local SPM package + `tool` target embedded in `Contents/Helpers` built with `xcodebuild`, signed with the identity, hardened runtime flag on both, `codesign --verify --deep --strict` OK |
| XCUITest headless | `xcodebuild test` ran a UI test that launched the app and found an element by accessibility id: passed (5.4 s) |
| `swift test` | Swift Testing works for the local package |
| APFS clones | `getattrlistbulk` with `FSOPT_ATTR_CMN_EXTENDED` + `ATTR_CMNEXT_CLONEID`/`ATTR_CMNEXT_PRIVATESIZE`: two clones of a 4 MB file return the same clone id and private size 0. Constants present in SDK (`sys/attr.h`, `EF_*` in `sys/stat.h`) |
| Firmlinks | `/Users` and `/System/Volumes/Data/Users` have identical `(dev, ino)`; same for `/private`. `/usr/share/firmlinks` lists 19 entries |
| Socket peer identity | `LOCAL_PEERTOKEN` (audit token) available in `sys/un.h`; `kSecGuestAttributeAudit` in `SecCode.h` |
| Claude CLI | `~/.local/bin/claude` -> `~/.local/share/claude/versions/2.1.296`. Not on GUI PATH. zsh wraps it in a function (GUI never sees it) |
| Gotchas found | Tool target needs explicit `PRODUCT_BUNDLE_IDENTIFIER`; UI test bundle needs `GENERATE_INFOPLIST_FILE: YES`; `ATTR_CMN_RETURNED_ATTRS` must be wrapped `attrgroup_t(...)` individually (UInt32 overflow); no `timeout` binary on macOS (use a watchdog loop) |

---

## 1. Goals and non-goals (v1)

### Goals

| # | Feature | Notes |
|---|---|---|
| G1 | Scan any mounted volume or any folder | Start screen lists volumes; Scan Folder (Cmd+O), drag folder onto window or Dock icon |
| G2 | Fast native engine | `getattrlistbulk`, bottom-up aggregation, hard links once, APFS clones aware, firmlinks, never cross mount points, never follow symlinks |
| G3 | Explore | Interactive space map (original visualization from design/, default squarified treemap per direction A; NOT a sunburst) + sorted children list + breadcrumb + back/forward + "smaller items" grouping + package handling |
| G4 | Explain every byte (volume scans) | Free, purgeable (info only), hidden/unreadable, other volumes in container, local snapshots (count + guidance) |
| G5 | Reclaimable view | Categories from the knowledge base (R3 B1) with risk `safe / review / dangerous / never`, sizes, explanation, one-click "add safe items" |
| G6 | Cleanup queue | Staging area; Move to Trash (default) or Delete Permanently (explicit, countdown with Stop); revalidation at execute time; result report; "recently trashed" list with "delete these permanently" |
| G7 | Quick Look, Reveal in Finder, Copy Path, Open in Terminal | |
| G8 | AI assistant | `claude` CLI child process (stream-json), bundled stdio MCP helper, Unix socket back to app, proposals land in the queue, user confirms |
| G9 | Live refresh | FSEvents on scanned root, shallow re-scan of dirty folders, tree updated in place |
| G10 | FDA onboarding | Detect, explain, deep link to System Settings, drag-the-app-icon target, relaunch |
| G11 | Full accessibility | Real AX roles and identifiers on every control and on every map tile |
| G12 | Localization | English only; all user-facing strings in String Catalogs so other languages can be added later |

### Non-goals (v1) with justification

| Deferred | Why |
|---|---|
| Privileged root helper | Highest-risk surface (a root helper that can delete any path must be locked down to one verified client). With FDA, user-owned files cover nearly all reclaimable space on this Mac (R3 C2). v1 shows root-only space honestly as "needs administrator" and offers a copyable Terminal command. v2: `SMAppService.daemon` + peer code-signing requirement + narrow validated API |
| Cloud drive scanning (Dropbox/GDrive/OneDrive/Box) | OAuth, token storage, API deletion semantics; out of scope for a local tool |
| Running tool-based cleanups (`simctl`, `brew cleanup`, `npm cache clean`) | v1 shows the exact command with Copy; app executes only file moves/deletes it can validate |
| Snapshot sizes and deletion | Size requires an undocumented `fsctl`; v1 lists snapshots (`tmutil listlocalsnapshots`) and offers copyable commands |
| Purging purgeable space | Private CarbonCore API; macOS manages it. Show only |
| Persistent scan cache across launches | v1.1; FSEvents covers in-session freshness |
| App uninstaller / orphan leftovers detection | High false-positive risk (R3 B3: 73 of 94 false orphans). v1.1 with the correct container-metadata algorithm |
| Unused-apps ranking | `kMDItemLastUsedDate` mostly null (R3 C3); needs fallback chain. v1.1 |
| Duplicate finder, CSV export, Sparkle updates, analytics, licensing | Not needed for personal v1 |
| Language-file stripping | Breaks code signatures (R3 B1: never) |
| Clearing `uchg` immutable flags | Respect user locks; report "locked" instead |

### Accounting and safety principles

| Area | AppName |
|---|---|
| APFS clones | Clone-aware accounting (shared bytes counted once per clone family) and honest "frees N bytes" estimates |
| Deletion | Trash is default; permanent is explicit |
| Privileged access | No root helper in v1; MCP socket verifies peer code signature + per-session nonce |
| Freshness | FSEvents-driven refresh |
| Hard links | Reclaimable estimate is 0 unless all links (or all clone owners) are queued |
| Accessibility | Full AX (also enables XCUITest) |
| `uchg` locks | Never cleared |

---

## 2. Architecture

### 2.1 Project generation: XcodeGen (decision)

| Option | Verdict |
|---|---|
| **XcodeGen** | **Chosen.** Installed, verified headless end to end (app + SPM package + embedded helper + signing + XCUITest). Declarative `project.yml`, `.xcodeproj` regenerated, not committed, so parallel builders never conflict on `project.pbxproj` |
| Tuist | Not installed; heavier, own CLI/cache; no benefit here |
| SwiftPM only | Cannot natively produce a signed `.app` with Info.plist, entitlements, embedded helper and UI test bundle |

Rules: `project.yml` and `Packages/Kit/Package.swift` are written once by WS0 with every target pre-declared; only the orchestrator edits them afterwards. Contributors run `brew install xcodegen` (documented in README); nothing installed globally by agents.

### 2.2 Repository layout and ownership

```
<repo>/
  AGENTS.md README.md LICENSE PLAN.md .gitignore Makefile project.yml        WS0 (orchestrator after)
  Config/Base.xcconfig            APP_NAME, APP_BUNDLE_ID, versions          WS0
  Config/Signing.xcconfig         defaults + `#include? "Signing.local.xcconfig"`  WS0
  Config/Signing.local.xcconfig.example (real one gitignored)                WS0
  Config/App.entitlements Config/Helper.entitlements                         WS0
  App/AppNameApp.swift App/Info.plist                                        WS0 shell, WS7b after
  App/Resources/Localizable.xcstrings InfoPlist.xcstrings Assets.xcassets    WS0 skeleton; keys added by WS7b/WS8 (see 4.4)
  App/Resources/assistant-system-prompt.md                                   WS5
  App/Screens/{Start,Scan,Explore,Reclaim,Cleanup,Settings,Onboarding}/      WS7b
  App/Screens/Assistant/                                                     WS8
  App/Components/ App/Commands/ App/Theme/                                   WS7b
  Helpers/MCPHelper/main.swift    one line: `MCPHelperMain.run()`            WS6
  Packages/Kit/Package.swift      single package, many targets               WS0
  Packages/Kit/Sources/ScanKit/{Core,Volume,Accounting}/                     WS1
  Packages/Kit/Sources/ScanKit/{Live,Query}/                                 WS2
  Packages/Kit/Sources/RulesKit/ (+ Resources/rules.json)                    WS3
  Packages/Kit/Sources/CleanupKit/                                           WS4
  Packages/Kit/Sources/AIBridge/                                             WS5
  Packages/Kit/Sources/IPCProtocol/Envelope.swift                            WS0
  Packages/Kit/Sources/IPCProtocol/Tools.swift                               WS6
  Packages/Kit/Sources/MCPServerKit/                                         WS6
  Packages/Kit/Sources/VizKit/                                               WS7a
  Packages/Kit/Sources/AppCore/                                              WS0 stubs, WS9 after
  Packages/Kit/Sources/TestSupport/                                          WS0 skeleton, WS10 after
  Packages/Kit/Sources/scanbench/   (executable)                             WS1
  Packages/Kit/Sources/mcp-helper/  (executable, one line, for swift test)   WS6
  Packages/Kit/Sources/fake-claude/ (executable)                             WS10
  Packages/Kit/Tests/<Target>Tests/                                          owner of <Target>
  UITests/                                                                   WS10
  scripts/lint.sh scripts/install.sh                                         WS0
  design/                                                                    read-only
```

The package is named `Kit` (not the app name) so the final rename touches only `Config/Base.xcconfig`, `project.yml` target names and strings.

### 2.3 Modules

| Target | Kind | Depends on | Responsibility |
|---|---|---|---|
| ScanKit | lib | Darwin, Foundation, Synchronization, DiskArbitration, CoreServices | Scanner, arena tree, hard links, clones, firmlinks, volume catalog, space accounting, FSEvents refresh, queries |
| RulesKit | lib | ScanKit | Knowledge base, path classifier, SafetyPolicy (protected paths), category aggregation, dev-artifact and old-installer detectors |
| CleanupKit | lib | ScanKit, RulesKit | Queue model, deletion executor (trash/permanent), revalidation, reports, recently-trashed store |
| IPCProtocol | lib | Foundation | Socket envelope, `JSONValue`, MCP tool catalog and argument/result types (shared by app and helper) |
| MCPServerKit | lib | IPCProtocol | Stdio JSON-RPC 2.0 MCP server loop + socket client; `MCPHelperMain.run()` |
| AIBridge | lib | IPCProtocol | Claude locator, process session, stream-json parser, session store, MCP config + prompt writer, IPC server with peer verification |
| VizKit | lib | SwiftUI | Space map layout (pure), rendering (`Canvas`), hit testing, animation, AX children; palette via protocol |
| AppCore | lib | all libs above | `@Observable` stores (AppModel, ScanSessionModel, CleanupModel, AssistantModel), ToolHandler, FDA probe, settings |
| TestSupport | lib | ScanKit | Fixture tree builder, oracle walker, in-memory fake tree, sample loaders |
| scanbench, mcp-helper, fake-claude | exe | as needed | Benchmark, helper for tests, deterministic CLI double |
| AppName (Xcode) | app | Kit products | SwiftUI screens only |
| AppNameMCP (Xcode `tool`) | exe | MCPServerKit | Embedded at `Contents/Helpers/appname-mcp`, bundle id `$(APP_BUNDLE_ID).mcp` |
| AppNameUITests (Xcode) | ui-test | | E2E |

Swift settings: language mode 6 everywhere. App target `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; packages default nonisolated. No third-party dependencies in v1.

### 2.4 Scan engine

**Attribute set per `getattrlistbulk` call:** `ATTR_CMN_RETURNED_ATTRS | NAME | OBJTYPE | FILEID`, dir `LINKCOUNT | MOUNTSTATUS`, file `LINKCOUNT | ALLOCSIZE` (local) or `TOTALSIZE` (network), plus extended `CMNEXT_PRIVATESIZE | CMNEXT_CLONEID` when the volume reports `VOL_CAP_INT_CLONE`. Options `FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED`. Buffer 64 KB per worker (fewer syscalls than 4 KB). No dates in hot path; dates fetched lazily (`lstat`) for display and age rules.

**Concurrency model (decision):** dedicated OS threads, not Swift tasks. `getattrlistbulk` blocks; blocking the cooperative pool (width = cores) would starve the app.
- Fixed pool of N `Thread`s, `Mutex`-protected LIFO work stack (Synchronization module). Worker continues depth-first on one child, pushes the rest.
- N default: 32 on SSD (perf test sweeps 8/16/32/48 and fixes the default), 4 on rotational or network. Override in Settings (advanced).
- Each directory task enumerates its entries into a worker-local scratch, then commits the children as one contiguous block into the arena.
- Parent pending-children counter (`Atomic<UInt32>` side array, freed after scan). On zero: sum sizes, sort children by size desc, notify parent. No second pass.
- Progress: absolute when volume object count is available (`ATTR_VOL_OBJCOUNT`), else relative fractions split per child. Published to the main actor at most 10 Hz via `AsyncStream<ScanEvent>`.
- Cancel: atomic flag checked per batch; target < 200 ms to stop.
- Watchdog: per-batch heartbeat; "file system not responding" after 30 s without progress.

**Data model (arena):**
```
struct Node {           // stride must be <= 32 bytes
  var size: UInt64       // aggregated allocated (or logical) bytes, dedup rules applied
  var parent: UInt32     // NodeID, .max = none
  var firstChild: UInt32 // children contiguous [firstChild, firstChild+childCount), sorted by size desc
  var childCount: UInt32
  var nameRef: UInt32    // into UTF-8 name slab (no String per node)
  var descendants: UInt32
  var nameLength: UInt16
  var flags: UInt16      // directory, package, symlink, hardlink, hardlinkSecondary, cloned, restricted, mountPoint, firmlinkSkipped, missing
}
```
- `NodeID = UInt32` (4.29 billion nodes max). Chunked storage (chunks of 2^20 nodes), names in chunked slab.
- Side tables only where needed: hard links `[inode: [NodeID]]`, clones `[cloneID: (sharedBytes, members)]`, restricted dirs list.
- **Memory budget:** <= 64 bytes per node average including names and side tables; whole app <= 150 MB baseline + 64 B/node. 5M nodes -> about 470 MB peak. Measured by `scanbench` and a unit test with 2M synthetic nodes.
- Post-scan the tree is read-mostly: `ScanTree` final class, internal `pthread_rwlock`, `generation: UInt64` bumped on every mutation. Mutations: `removeSubtree`, `replaceChildren(of:)` (refresh), `markMissing`. Ancestor sizes updated on mutation.
- Path lookup: walk from root by name (lazy per-directory name index for dirs > 256 children).

**Size accounting rules:**
| Rule | Spec |
|---|---|
| Size field | Local: allocated (`ATTR_FILE_ALLOCSIZE`). Network: logical |
| Symlinks | Never followed; counted as their own allocation |
| Hard links | Every inode once. Primary = lexicographically smallest path (deterministic); secondaries contribute 0 to ancestors and show `sizeInLinks` in UI |
| Clones | Per file: private = `PRIVATESIZE`, shared = alloc - private. Each clone family (same `CLONEID`) contributes its shared bytes once, at the primary (smallest path). Setting "Count clones once" default on; off = every clone at full size (needed for `du` comparisons) |
| Mount points | Leaves (size 0), except the Data volume when scanning `/` (below) |
| Firmlinks (scanning `/`) | Walk `/` naturally (firmlinks resolve to Data). At scan start stat each `/System/Volumes/Data/<target>` from `/usr/share/firmlinks` and record `(dev, ino)`. When the walk enters `/System/Volumes/Data`, skip children whose `(dev, ino)` is in that set. Result: natural paths (`/Users/...`), Data-only paths still counted, no double counting |
| Packages | Directory with known package extension (`.app .appex .bundle .framework .plugin .kext .photoslibrary .xcarchive .sparsebundle .rtfd .pages .numbers .key .fcpbundle .musiclibrary .imovielibrary .xcodeproj .playground` ...) or lazily confirmed via `NSWorkspace.isFilePackage` off the hot path. One segment until "Show Package Contents" |
| Restricted (EACCES / EPERM) | Node flagged `restricted`, size 0, listed; contributes to hidden space |
| Volume summary | capacity = `volumeTotalCapacity`; free = `volumeAvailableCapacity`; purgeable = max(0, `availableCapacityForImportantUsage` - free); otherVolumes (APFS) = `ATTR_VOL_SIZE - (ATTR_VOL_SPACEUSED + ATTR_VOL_SPACEFREE)`; used = capacity - free; hidden = max(0, used - scanned - otherVolumes); purgeable shown as info inside hidden when it overlaps |
| Folder scans | No hidden/free rows |

**Volume catalog:** `URLResourceKey` volume keys + DiskArbitration description (internal/external/removable/network/disk image, encrypted, read-only, SSD). Mount/unmount via `NSWorkspace` notifications -> `AsyncStream<[VolumeInfo]>`. APFS sibling volumes grouped under the container; only the user-facing volume per group is shown.

**FSEvents refresh (WS2):** `FSEventStreamCreate` on scanned root, latency 2 s, `WatchRoot`, dispatch queue. Directory-level events -> dirty set -> after 3 s idle, shallow re-enumerate each dirty dir: match existing children by `(name, fileid)`, keep unchanged subtrees, fully scan new subdirs, drop vanished. `MustScanSubDirs`/`UserDropped`/`KernelDropped` -> full subtree rescan. `RootChanged`/unmount -> scan marked stale with banner. Paths being deleted by our executor are suppressed (already applied).

### 2.5 Safety policy and protected paths (RulesKit)

Evaluated on: add-to-queue (UI), `propose_deletion` (assistant), and again in the executor right before each move/delete.

Canonicalization: realpath of the parent directory + last component (never resolve the item itself), strip `/System/Volumes/Data` prefix, compare case-insensitively unless the volume is case-sensitive, expand `~` against the injected `home` (tests inject a fixture home).

| Class | Paths (match kind) |
|---|---|
| Never: system (subtree) | `/System` (incl. `/System/Applications`, `/System/Volumes/*` roots), `/usr` except `/usr/local`, `/bin`, `/sbin`, `/private/var/db`, `/private/var/vm`, `/private/etc`, `/private/var/folders` (bulk), `/Library/Apple`, `/Library/Extensions`, `/Library/Keychains`, `/Library/Preferences/SystemConfiguration`, `/dev`, `/cores` (review only), `/.Spotlight-V100`, `/.fseventsd`, `/.DocumentRevisions-V100`, `/.vol` |
| Never: roots (exact, contents allowed) | `/`, volume roots, `/Applications`, `/Library`, `/Users`, `/Volumes`, `~`, `~/Library`, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, the scan root itself |
| Never: user data (subtree) | `~/Library/Keychains`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Photos`, `*.photoslibrary` contents, `~/Library/Application Support/AddressBook`, `~/Library/Calendars`, `~/Library/Safari`, `~/Library/Accounts`, `~/Library/Cookies`, `~/Library/IdentityServices`, `~/Library/Sharing`, `~/Library/Biome`, `~/Library/Daemon Containers`, `~/Library/Autosave Information`, `~/Library/Containers/com.apple.*` and `~/Library/Group Containers/group.com.apple.*` (bulk), `~/Library/Preferences` (bulk), `~/.ssh`, `~/.gnupg`, `~/.config` (bulk), `~/.claude` (bulk), `~/.local/bin`, `~/.local/share/claude`, top-level dotfiles in `~` |
| Never: backups | anything under `Backups.backupdb`, `*.backupdb`, Time Machine sparsebundles, `/Volumes/.timemachine` |
| Dangerous (whole item may be queued by the user only after explicit per-item acknowledgement; assistant proposals rejected) | `*.photoslibrary` (whole), `~/Library/Application Support/MobileSync/Backup`, browser profiles (Chrome, Firefox) |
| Allowed exceptions (beat a shorter never-prefix) | `/private/var/log` (review, admin), `/private/var/tmp`, `/private/tmp`, `/usr/local` |
| Other refusals | read-only volume, item not in current scan, item changed since scan (`dev/ino` mismatch), special rows (free/hidden/purgeable/other volumes) |

Each refusal has a `BlockReason` enum case with an English message (original wording).

### 2.6 Knowledge base (rules.json)

Schema (one object per rule, validated by tests):
```json
{"id":"xcode.deriveddata","category":"developer","risk":"safe",
 "title":"...","explanation":"...",
 "match":[{"path":"~/Library/Developer/Xcode/DerivedData","kind":"childrenOf"}],
 "action":{"type":"trash"},
 "preconditions":[{"type":"appNotRunning","bundleID":"com.apple.dt.Xcode"}],
 "minAgeDays":null,"keepNewest":null,"commandHint":null}
```
`kind`: `exact | subtree | childrenOf | glob`. `action.type`: `trash | guide` (guide = show `commandHint` with Copy, never executed). Rules from R3 B1 all ported (caches per app, DerivedData, DeviceSupport keep newest, CoreSimulator caches/devices/runtimes, previews, npm/yarn/pnpm/bun/brew/pip/uv/poetry/gradle/maven/cargo/go/CocoaPods/SwiftPM, Docker/OrbStack, AI model caches, Trash, old installers in Downloads, Mail Downloads, logs, Xcode Archives). Code detectors: dev artifacts (`node_modules` with sibling `package.json`, `.next`, `dist`/`build` with project marker, `target` with `Cargo.toml`, `Pods` with `Podfile`, `.venv`, `.expo`) flagged review with project age; installer `.dmg/.pkg/.zip` in Downloads older than 30 days. Category aggregation picks the topmost matching node per rule, never double counts nested matches.

### 2.7 Cleanup and deletion flow

1. **Queue** (staging, nothing touched on disk). Item = path, NodeID, `(dev, ino)` identity, size, reclaimable estimate, risk, rule, source (`user | category(id) | assistant(threadID, reason)`), selected flag. Adding a parent absorbs queued children; adding a child of a queued parent is a no-op. Assistant items arrive unselected. Queue survives navigation, not relaunch (v1).
2. **Reclaimable estimate:** file size, minus secondary hard links not queued (0 if any link stays), minus clone-shared bytes when other family members stay. UI shows "frees about X" vs "size Y".
3. **Confirm sheet:** counts per risk, total, mode. Trash (default button). Delete Permanently: secondary action, then 5 s countdown with Stop (our own wording). Dangerous items need a per-item acknowledgement checkbox.
4. **Executor** (`actor CleanupExecutor`), per item: `lstat` -> compare `(dev, ino)` with scan record (mismatch -> skip "changed since scan") -> SafetyPolicy again -> app precondition (e.g. Xcode not running) -> `FileManager.trashItem(at:resultingItemURL:)` or `removeItem` (no symlink following; symlink itself is removed). EPERM on `uchg` -> failure "locked", no flag clearing. Network volume without Trash -> failure with "delete permanently instead?" offer. Progress stream, cancel between items.
5. **After:** tree mutation (removeSubtree, ancestor sizes), volume summary refresh, report (freed now / moved to Trash / failed with reasons). Trash note: space is freed only when the Trash is emptied; "Recently moved to Trash" list (we hold `resultingItemURL`) offers "Delete these permanently" without emptying the user's whole Trash.
6. **Quit guards:** non-empty queue, scan running, deletion running.
7. **Test mode guard:** executor `allowedRoot` (fixture dir) refuses everything outside it; `TrashProviding` injected (`FixtureTrash` moves into `<fixture>/.test-trash`).

### 2.8 Full Disk Access onboarding

- Probe: `open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)`; success = granted, EPERM/EACCES = denied; ambiguous -> probe `/Library/Preferences/com.apple.TimeMachine.plist`. Tri-state `unknown/denied/granted`. Builder must re-verify on 26.6 (risk R6).
- Onboarding screen (first launch and Settings > Permissions): why FDA (names and sizes only, never contents), step list, "Open System Settings" (`x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`, fallback `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`), draggable app icon (`NSItemProvider` with the bundle URL), re-probe on `didBecomeKey`, "Relaunch" button (`open -n` on own bundle after exit via a tiny `/bin/sh` wait loop). Skippable: app works without FDA, hidden space explains why.
- TCC grants are bound to the designated requirement: Apple Development signing keeps it stable across rebuilds; ad-hoc builds lose the grant every build (reason to use the identity).

### 2.9 Entitlements, signing, Info.plist

- Not sandboxed (FDA, spawning `claude`, reading `~/.claude` via the CLI). Hardened runtime on for app and helper. `App.entitlements`: empty dict (no exceptions needed; spawning external binaries is allowed under hardened runtime). Helper: same.
- `Config/Signing.xcconfig`: `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = -`, `DEVELOPMENT_TEAM =` then `#include? "Signing.local.xcconfig"`. Each builder's local file sets `DEVELOPMENT_TEAM` to their own team id and `CODE_SIGN_IDENTITY = Apple Development`. Forks build ad-hoc out of the box.
- Bundle ids: Release `$(APP_BUNDLE_ID)`, Debug `$(APP_BUNDLE_ID).dev` (separate TCC grant, no clash with installed copy). Helper `$(APP_BUNDLE_ID).mcp`.
- Info.plist: `LSMinimumSystemVersion 26.0`, `LSApplicationCategoryType public.app-category.utilities`, `CFBundleDocumentTypes` for `public.folder` and `public.volume` (role Viewer) so folders/disks open via Dock drop, `NSSupportsSuddenTermination NO`.
- Privacy strings (InfoPlist.xcstrings, English, original wording, pattern "reads names and sizes only, never contents"): `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`, `NSFileProviderDomainUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSCalendarsUsageDescription`, `NSContactsUsageDescription`, `NSRemindersUsageDescription`. No Apple Events (Open in Terminal uses `NSWorkspace.open(_:withApplicationAt:)`).

### 2.10 UI (screens and components, no visual decisions)

| Screen | Components | Key AX ids (prefix contract) |
|---|---|---|
| Start | Volume rows (icon, name, kind/size description, usage bar, free amount, Scan button), Scan Folder button, drop target, recent folders, FDA banner | `start.volume.<name>`, `start.scanFolder`, `start.fdaBanner` |
| Scanning | Progress (determinate or indeterminate), items scanned, current path, Cancel | `scan.progress`, `scan.cancel` |
| Explore | Toolbar (back, forward, breadcrumb, rescan, queue badge, assistant toggle), space map (header label = current folder + size), children list (name, size, share bar, risk badge), special rows (free, hidden, purgeable, other volumes, smaller items), inspector (path, size, frees-about, category, explanation), context menu | `explore.map`, `explore.tile.<name>`, `explore.list.row.<name>`, `explore.breadcrumb.<n>`, `explore.back`, `explore.forward` |
| Reclaim (tab beside Folders in Explore sidebar) | Categories grouped by risk, bytes, expand to items, "Add safe items", guidance with Copy command | `reclaim.category.<ruleID>`, `reclaim.addSafe` |
| Cleanup queue (drawer/panel) | Rows with checkbox, risk, source badge (You/Category/Assistant + reason), size, frees-about; totals; Move to Trash; Delete Permanently; confirm sheet; countdown with Stop; report; recently trashed | `queue.row.<name>`, `queue.trash`, `queue.deletePermanently`, `queue.countdown.stop`, `queue.report` |
| Assistant (inspector panel) | Availability card, consent sheet, thread picker, message list (streamed text, tool activity chips, proposal cards with "Review in queue"), composer, Stop, usage footer | `assistant.input`, `assistant.send`, `assistant.stop`, `assistant.proposal.<n>`, `assistant.setup` |
| Settings | General (purgeable counted as free, notifications), Scanning (exclusions, count clones once, workers), Assistant (enable, CLI path override + detected version, model, max turns, budget, clear threads), Permissions (FDA status), About (MIT, version) | `settings.*` |
| Onboarding | FDA steps, open settings, drag icon, relaunch, skip | `onboarding.*` |

Menus/shortcuts: Cmd+O Scan Folder; Cmd+R Rescan Folder; Shift+Cmd+R Rescan; Cmd+Up Enclosing Folder; Cmd+[ / Cmd+] Back/Forward; Space Quick Look; Cmd+Delete Add to Cleanup; Cmd+L Show Cleanup Queue; Cmd+Shift+A Toggle Assistant; Cmd+, Settings. Dock tile progress, completion notification.

Space map spec (VizKit): **clean-room, original visualization** (no sunburst, no rings, no angular hue). Visualization follows the direction the user picks in `design/mockup.html` + `design/design-notes.md`; default is direction A: two-level squarified treemap (current folder's children as tiles, one level of grandchildren nested inside, label inside tiles above a min size). Tiles below a minimum area (default 0.15% of the map, tuned in perf) merge into one "smaller items" tile per parent (expandable); hover highlights tile + shows name/size; click drills down with a zoom transition; analytic hit testing on tile rects; `Canvas` with cached rects per tree generation; per-tile AX children. Colors by cleanup category/file kind via a `MapPalette` protocol (theme implements it). Layout API is generic (`MapLayout` protocol) so direction B (icicle) or C (unit grid) can be swapped in without touching the app.

---

## 3. AI integration spec

### 3.1 Process topology

```
AppName.app (AppCore: AssistantModel, ToolHandler; AIBridge: ClaudeSession, IPCServer)
  spawns  claude -p ... --mcp-config <AppSupport>/assistant/mcp-<session>.json
            spawns  AppName.app/Contents/Helpers/appname-mcp --socket <path>   (stdio MCP)
                      connects  Unix socket <path>  -> IPCServer (peer verified + nonce)
  reads   claude stdout NDJSON -> StreamJSONParser -> chat UI
```

### 3.2 Binary discovery (`ClaudeLocator`)

1. User override (Settings file picker). 2. First executable of `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.npm-global/bin/claude`, `~/.claude/local/claude`. 3. Fallback once: `/bin/zsh -l -c 'command -v claude'` (no `-i`), take last stdout line, 5 s timeout. 4. Resolve symlink at each spawn, never cache the versioned path. 5. `claude --version` shown in Settings. 6. Feature-detect via `system/init.capabilities` (require `interrupt_receipt_v1`), not version compare.

### 3.2b Authentication and billing: follows the CLI login, never asks for a key (user requirement)

- Lightwell never requests, stores or passes an API key. It runs whatever account the user's `claude` CLI is signed into, exactly like terminal Claude Code: a Claude subscription login (Pro/Max) or a Console org login (API credits, e.g. startup credits). The user switches accounts with `claude` -> `/login` in Terminal; Lightwell follows on the next session.
- Verified on this Mac (12 Oct 2026): CLI login is OAuth (`claude auth status` -> `authMethod: oauth_token`, `credentials-file · user_oauth`), stream-json `system/init.apiKeySource == "none"`, no `ANTHROPIC_API_KEY` in env.
- Settings > Assistant shows "Signed in as <organization>" (`claude auth status --text`, email hidden) and the key source from `init.apiKeySource`. Setting "Block API keys" (default ON): if `apiKeySource != "none"` (env var or apiKeyHelper key) the session is refused with a card explaining why. A subscription login vs a Console-credits login is not reliably distinguishable from the CLI, so the UI states the org name and lets the user decide.
- Guards: never `--bare`; child env is the scrubbed allowlist in 3.3 (no `ANTHROPIC_*` inherited).
- `total_cost_usd` is shown as "estimated usage" (real charge only on API-credit logins). Caps are usage guards: `--max-turns 12` per message and an app-side per-thread token guard (default 300k cumulative input+output, configurable) with a "Continue" button.

### 3.3 Exact invocation

```
<claude> -p
  --input-format stream-json --output-format stream-json --verbose --include-partial-messages
  --session-id <uuid>        (new thread)   |   --resume <uuid>   (reopen thread)
  --model <setting, default sonnet> --max-turns 12
  --setting-sources "" --disable-slash-commands
  --strict-mcp-config --mcp-config <AppSupport>/AppName/assistant/mcp-<session>.json
  --tools ""
  --allowedTools "mcp__disk__get_disk_overview mcp__disk__get_largest_items mcp__disk__list_children mcp__disk__get_category_summary mcp__disk__inspect_path mcp__disk__search_items mcp__disk__get_cleanup_queue mcp__disk__propose_deletion"
  --permission-mode dontAsk
  --system-prompt-file <AppSupport>/AppName/assistant/system-prompt.md
cwd  = ~/Library/Application Support/AppName/assistant/   (0700, app-owned, empty)
env  = HOME, USER, LOGNAME, LANG, TMPDIR, PATH=/usr/bin:/bin   (nothing else inherited)
```
Never `--bare` (drops OAuth), never `--safe-mode` (drops our MCP server), never `--dangerously-skip-permissions`. MCP server name is `disk` (independent of final app name).

MCP config file (0600, written per session, deleted on session end):
```json
{"mcpServers":{"disk":{"type":"stdio","command":"<bundle>/Contents/Helpers/appname-mcp","args":["--socket","<socketPath>"],"env":{"APPNAME_MCP_NONCE":"<per-session random 32 bytes hex>"}}}}
```
(The nonce is app-generated, not a user secret; it is never logged or shown.)

### 3.4 Session lifecycle

- One live `claude` process per active thread (long-lived stream-json input). Message = `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}` + newline.
- Expect `system/init` once per turn (seen twice in `04-stream-input.jsonl`): verify `mcp_servers[name=disk].status == "connected"` on the first; tolerate repeats.
- Interrupt: `{"type":"control_request","request_id":"req_<n>","request":{"subtype":"interrupt"}}`; expect `control_response` then `result` `error_during_execution`.
- Idle 10 min or thread switch: close stdin (clean exit). App quit: interrupt, close stdin, SIGTERM after 3 s.
- Threads persisted in `assistant/threads.json` (id, title from first message, created, model, cumulative tokens, cumulative estimated cost). Reopen with `--resume <id>`; crash -> offer Retry (respawn with `--resume`).
- stdout read line by line (`FileHandle.bytes.lines` or readability handler with a byte buffer that handles split UTF-8); stderr drained to a 256 KB ring buffer saved to `assistant/logs/<session>.log` (shown only under "Details"); never log env or the nonce.

### 3.5 Stream-json parser contract (`StreamEvent`)

`initialized(InitInfo{sessionID, model, mcpServers, capabilities, version})`, `status(String)`, `messageStart(id)`, `textDelta(String)`, `thinkingDelta` (count only, content not shown), `toolUseStart(id, name)`, `toolInputDelta(id, partialJSON)`, `blockStop`, `messageDelta(stopReason)`, `assistantMessage(blocks)`, `toolResult(toolUseID, text, isError)`, `thinkingTokens(Int)`, `apiRetry(attempt, max, delayMs, errorStatus, error)`, `controlResponse(requestID, subtype)`, `result(TurnResult{subtype, isError, text, numTurns, durationMs, usage, totalCostUSD, permissionDenials, terminalReason, apiErrorStatus})`, `unknown(type, subtype)`. Unknown fields and types ignored (forward compatible), malformed lines logged and skipped. Signature deltas ignored.

### 3.6 IPC (helper <-> app)

- Socket: `~/Library/Application Support/AppName/ipc/s-<pid>.sock`, dir 0700, socket 0600. If the path exceeds 103 bytes (`sun_path` limit), use `$TMPDIR/appname-<pid>.sock`.
- Framing: newline-delimited UTF-8 JSON, max line 1 MiB.
- Messages: `{"id":1,"method":"hello","params":{"nonce":"...","protocol":1,"helperVersion":"1.0"}}` -> `{"id":1,"result":{"ok":true}}`; `{"id":2,"method":"callTool","params":{"name":"get_largest_items","arguments":{...}}}` -> `{"id":2,"result":{"text":"<json>","isError":false}}`; `ping`.
- **Peer verification on accept** (before reading anything): `getsockopt(LOCAL_PEERTOKEN)` -> `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` -> `SecCodeCheckValidity` with a requirement built at runtime from the app's own signature: `identifier "<APP_BUNDLE_ID>.mcp" and anchor apple generic and certificate leaf[subject.OU] = "<own team>"`; if the app is ad-hoc signed (no team) require `cdhash` equal to the bundled helper's static code cdhash. Then the first message must be `hello` with the nonce of a live session (maps connection -> thread). Any failure: close silently, log reason code.
- Helper behavior when app unreachable: `tools/list` still works (static catalog); calls return `isError` text "Open AppName and scan a disk first." (lets users reuse the helper with their own Claude Code later).

### 3.7 MCP tool catalog (IPCProtocol/Tools.swift owns the schemas)

Common: paths accepted as absolute or `~/...`; outputs use `~` for home; every result <= 24 KB of JSON text (well under the CLI's 25k token MCP cap), paginated with opaque `cursor`. No tool ever reads file contents. Read tools annotated `readOnlyHint: true`.

| Tool | Input schema | Output |
|---|---|---|
| `get_disk_overview` | `{}` | `{volume, capacity, used, free, purgeable, other_volumes, hidden, scanned_root, scan_age_s, fda:"granted|denied|unknown", snapshots_count}` |
| `get_largest_items` | `{path?:string, limit?:int 1..100 =20, min_bytes?:int, kind?:"file"|"directory"|"any"="any", scope?:"children"|"descendants"="descendants", cursor?:string}` | `{items:[{path, bytes, frees_bytes, kind, items, rule_id?, risk?}], next_cursor?}` |
| `list_children` | `{path:string, limit?:int 1..200 =50, sort?:"size"|"name"="size", cursor?:string}` | same item shape |
| `get_category_summary` | `{}` | `{categories:[{rule_id, title, risk, bytes, count, action:"trash"|"guide", command_hint?}]}` |
| `inspect_path` | `{path:string}` | `{path, bytes, frees_bytes, kind, items, modified, last_used?, bundle_id?, rule_id?, risk, explanation, protected:bool, protection_reason?, hard_links?, clone_shared_bytes?}` |
| `search_items` | `{under?:string, name_glob?:string, extension?:string, min_bytes?:int, older_than_days?:int, limit?:int 1..100 =30, cursor?:string}` (dates stat'ed lazily, max 2000 candidates) | item list |
| `get_cleanup_queue` | `{}` | `{items:[{path, bytes, risk, source, selected}], total_bytes}` |
| `propose_deletion` | `{items:[{path:string, reason:string}] (1..50), summary:string}` (`readOnlyHint:false, destructiveHint:false, idempotentHint:true`) | `{queued:[{path, bytes, risk}], rejected:[{path, code, message}], note:"Nothing was deleted. The user reviews and confirms in the app."}` |

`propose_deletion` handler: path must exist as a node in the current scan; SafetyPolicy; `dangerous` and `never` rejected with the reason (the model sees it); `review` and `safe` queued unselected with source `assistant(thread, reason)`; emits a `ProposalBatch` to AssistantModel (card in chat).

### 3.8 System prompt outline (`system-prompt.md`, rendered per session from the bundled template)

1. Role: disk space assistant inside AppName on macOS 26; answer in English.
2. Data access only through the `disk` tools; scan snapshot age `{{scanAge}}`; never assume file contents.
3. Only the user deletes. `propose_deletion` only queues; say so plainly. Deleted items go to the Trash by default.
4. Risk levels and what to do with each (condensed R3 B1/B2); never propose dangerous/never items; for tool-managed items (simulators, brew, npm, snapshots) give the command as guidance instead of proposing files.
5. Method: overview -> categories -> largest items -> inspect before proposing; prefer whole rule categories over many files; max 50 paths per proposal; quote sizes in GB.
6. Style: concise, bullet lists, no speculation, explain why each item is safe or worth reviewing.
7. Privacy: paths are user data; do not repeat full personal file names unless needed.

### 3.9 Failure modes

| Condition | Detection | UI |
|---|---|---|
| CLI not found | Locator fails | Setup card: install instructions + "Choose claude binary..." |
| Not logged in | `result.is_error` with auth error or `api_retry.error == "authentication_failed"` | "Open Terminal and run `claude` to sign in", Retry |
| MCP helper not connected | init `mcp_servers` disk status != connected, or `mcp_server_errors` | Error card with Details (stderr log) |
| Missing capability | `capabilities` lacks `interrupt_receipt_v1` | Warning; Stop disabled |
| Rate limit / overload | `api_retry` with status 429/529 | Inline "retrying (n/max)" |
| Max turns | `result.subtype == error_max_turns` | "Stopped after N steps." Continue button |
| Usage guard reached | per-thread cumulative tokens > guard, or plan limit error from CLI | Message ("usage limit reached, resets later" or "thread guard reached") + Continue / Settings |
| Process crash / exit != 0 | termination handler | Retry (respawn with `--resume`) |
| No scan yet | ToolHandler | Tools return guidance; chat shows "Scan a disk first" chip |
| Malformed line | parser | Logged, skipped |

### 3.10 Cost and token hygiene

`--system-prompt-file` + `--setting-sources ""` + `--tools ""` + `--strict-mcp-config` + `--disable-slash-commands` (about 2.2k input tokens per call vs 33.7k, R3 A3); default model `sonnet`; `--max-turns 12`; compact tool JSON with `~` paths and pagination; scan data never pasted into prompts; usage footer shows tokens per turn from `result.usage` and cost labelled "estimated (subscription usage is not billed per call)"; per-thread cumulative cap enforced app-side as well (CLI budget semantics in long-lived mode unverified, risk R4).

### 3.11 Privacy consent

First use: sheet explaining that file and folder names, paths and sizes from the scan are sent to Anthropic through the user's Claude account; contents are never read; assistant is off until accepted; can be disabled in Settings.

---

## 4. Work breakdown

### 4.1 Phases and dependencies

```
Phase 0  WS0 scaffolding (alone, must merge first)
Phase 1  parallel: WS1 WS2 WS3 WS4 WS5 WS6 WS7a WS7b WS8 WS10a
Phase 2  WS9 integration (may start in phase 1 against stubs; finishes after WS1..WS6 merge)
Phase 3  WS10b E2E + perf + live smoke; fix loop (bugs routed back to owning WS)
Phase 4  release hygiene (README screenshots, install, tag v0.1.0)
```
Each builder works on branch `ws/<n>-<slug>` (own git worktree), touches only owned paths, rebases on `main`, orchestrator merges in order WS0 -> {WS1, WS3, WS6, WS7a, WS10a} -> {WS2, WS4, WS5} -> {WS7b, WS8} -> WS9 -> WS10b.

### 4.2 Workstreams

**WS0 Scaffolding** (owner paths: everything at root, `Config/`, `Package.swift`, `project.yml`, stubs)
- `git init`, `.gitignore` (build/, DerivedData, `*.xcodeproj`, `.DS_Store`, `Config/Signing.local.xcconfig`, `.claude/`, `*.log`), MIT `LICENSE` (holder: Alex Luncan, 2026), README skeleton, `AGENTS.md` (rules below), this plan.
- `Config/*.xcconfig`, entitlements, `project.yml` (app, helper `tool` with explicit bundle id embedded to `Contents/Helpers`, UI tests with generated Info.plist, scheme with test action), `Packages/Kit/Package.swift` with every target and dependency of 2.3, resources (`rules.json` placeholder, xcstrings), `defaultLocalization: "en"`.
- Contract stubs for every public API in 4.3 (compiling, returning empty or fake data, `// TODO(WSn)` markers), AppCore stores backed by `PreviewData` so UI builders can run the app.
- App shell: `NavigationSplitView`-free single window with Start -> Explore routing, placeholder views carrying the AX ids from 2.10, menu commands stubbed.
- `Makefile` targets of section 6, `scripts/lint.sh`, `scripts/install.sh`.
- AGENTS.md rules: no em or en dashes in anything a person reads; every user-facing string in a String Catalog; never print or echo env var values or the nonce; small surgical diffs inside owned paths; no third-party deps without orchestrator approval; clean-room rule; tests never touch real user data (fixtures under `$TMPDIR/appname-fixtures/`); commit trailer as given in the dispatch.
- Accept: `make gen build test lint` green; app launches to placeholder Start; `codesign --verify --deep --strict` OK; helper present in `Contents/Helpers` with hardened runtime; `swift test --package-path Packages/Kit` runs (empty) suites for every test target.

**WS1 ScanKit core** (`ScanKit/Core`, `Volume`, `Accounting`, `scanbench`, `ScanKitTests/Core*`)
- Scanner (2.4), arena `ScanTree` + mutations, hard links, clones, firmlinks, mount points, packages, restricted, progress, cancel, watchdog; `VolumeCatalog`; `SpaceSummary`; `scanbench` exe (`--json`, `--workers`, `--no-dedupe-clones`, reports nodes, seconds, peak `phys_footprint`, bytes/node, total).
- Accept: all fixture tests in 5.1 pass; scanner totals equal the TestSupport oracle exactly on fixtures; `MemoryLayout<Node>.stride <= 32`; 2M synthetic nodes <= 64 B/node; cancel < 200 ms; `scanbench ~` meets 5.4; `scanbench /` (gated) shows no `/System/Volumes/Data/Users` duplicate and `scanned + hidden + otherVolumes` within 0.5% of `used`.

**WS2 ScanKit live + query** (`ScanKit/Live`, `ScanKit/Query`, tests)
- `TreeRefresher` (FSEvents, 2.4), query API: `largest`, `children(paged)`, `search`, `node(atPath:)`, `ItemSummary` builder with `freesAbout` estimate hook. Built against `TreeReading` using TestSupport's in-memory tree until WS1 lands.
- Accept: create/delete/rename in a fixture is reflected in tree within 5 s of quiet; MustScanSubDirs triggers subtree rescan; paging stable under mutation (cursor = generation + offset, stale cursor -> error); queries on 1M-node tree < 50 ms.

**WS3 RulesKit** (`RulesKit/**`, `rules.json`, tests)
- Rule model + JSON loader + validator, compiled path trie matcher, `SafetyPolicy` (2.5), `RuleEngine.classify`, `categories(in:)`, detectors (dev artifacts, old installers), `BlockReason` messages.
- Accept: table tests for every R3 B1 row and every 2.5 path (both `/System/Volumes/Data` and case variants); rules.json validation (unique ids, title/explanation non-empty, no dashes); nested matches never double counted; classify < 5 us per path.

**WS4 CleanupKit** (`CleanupKit/**`, tests)
- `CleanupQueue` (dedupe, totals, reclaimable estimate), `CleanupExecutor` (2.7), `TrashProviding` (`SystemTrash`, `FixtureTrash`), `RecentlyTrashed`, `DeletionReport`.
- Accept: tests in 5.1 pass using only fixture dirs; changed-since-scan, locked (`uchg`), symlink-only-removes-link, outside-allowedRoot refusal, partial failure all covered; one real-Trash test cleans up its own trashed file via `resultingItemURL`.

**WS5 AIBridge** (`AIBridge/**`, `assistant-system-prompt.md`, tests)
- `ClaudeLocator`, `ClaudeCommandBuilder` (exact args 3.3), `ClaudeSession` (spawn, stdin writer, line reader, interrupt, close, termination), `StreamJSONParser` (3.5), `ThreadStore`, `MCPConfigWriter`, `SystemPromptRenderer`, `IPCServer` with peer verification (3.6) and `AssistantToolHandler` protocol.
- Accept: every line of every `Packages/Kit/Tests/Fixtures/cli-samples/*.jsonl` parses; per-file event counts match a golden table; byte-split feeding gives identical output; command builder golden test; IPC rejects wrong nonce, unsigned client, and a signed binary with wrong identifier; session test with fake-claude passes.

**WS6 MCP helper + tool catalog** (`IPCProtocol/Tools.swift`, `MCPServerKit/**`, `mcp-helper/`, `Helpers/MCPHelper/`, tests)
- Tool definitions and Codable arg/result structs (3.7), JSON-RPC loop (`initialize` echoing client protocolVersion, `notifications/initialized`, `tools/list`, `tools/call`, `ping`, errors -32700/-32600/-32601/-32602), socket client with hello + reconnect once, stderr diagnostics only.
- Accept: golden JSON-RPC transcripts; `tools/list` equals catalog; works with app absent (error text); real `claude` handshake reports `status: connected` (gated live test); helper cold start < 50 ms.

**WS7a VizKit** (`VizKit/**`, tests)
- `TreemapLayout` (pure squarified algorithm behind a `MapLayout` protocol: input tree slice via a small protocol, output tiles with rects/depth/ids, smaller-items groups), `SpaceMapView` (`Canvas`, hover, click, drill/zoom animations, AX children), `MapPalette` protocol + neutral placeholder palette.
- Accept: layout unit tests (tile areas proportional to size within 1%, rects tile the parent with no overlap, aspect ratios near 1 for squarified, min-area grouping, deterministic ids); hit test correctness on 1k random points; layout of 5k tiles < 8 ms; 60 fps hover on 5k tiles (Instruments note in PR); every visible tile has AX label "name, size".

**WS7b App UI** (`App/Screens/*` except Assistant, `App/Components`, `App/Commands`, `App/Theme`, string keys)
- All screens of 2.10 except Assistant, wired to AppCore store APIs (fake data until WS9), Quick Look (`QLPreviewPanel`), Reveal, Copy Path, Open in Terminal, Dock progress, notifications, quit guards, menus and shortcuts, FDA onboarding.
- Accept: every AX id in 2.10 present; app fully navigable by keyboard; no text truncation at default window size; no hard-coded colors outside `App/Theme`.

**WS8 Assistant UI** (`App/Screens/Assistant/**`, its string keys)
- Panel, consent sheet, availability/setup cards, thread list, streaming message list (markdown), tool chips, proposal cards, Stop, usage footer, Settings > Assistant section view (as a component WS7b embeds).
- Accept: renders all `AssistantModel` states from PreviewData; streaming text at 60 fps for 10k-char replies; AX ids present.

**WS9 Integration** (`AppCore/**`)
- Real `AppModel`, `ScanSessionModel` (scan lifecycle, navigation history, refresher, summaries, categories), `CleanupModel` (queue + executor + reports), `AssistantModel` (locator, sessions, threads, proposals), `ToolHandler` implementing all 3.7 tools, FDA probe, settings persistence (`UserDefaults`), test-mode launch arguments (5.3).
- Accept: end to end on a fixture: scan -> explore -> queue -> trash; assistant with fake-claude produces a proposal in the queue; all stores free of main-thread blocking > 16 ms during a `~` scan (os_signpost check).

**WS10a Test infrastructure** (`TestSupport/**`, `fake-claude/`)
- `FixtureBuilder` (5.1 cases), oracle walker (`lstat` + inode dedupe), in-memory `TreeReading` fake, sample loaders, `fake-claude` (reads `--mcp-config`, spawns helper, runs a scripted MCP exchange, emits stream-json modelled on the samples, honours interrupt control requests).
- Accept: used by WS1/WS2/WS4/WS5 tests; fake-claude script for "propose two fixture paths" works against the real helper.

**WS10b E2E, performance, live smoke** (`UITests/**`, perf scripts)
- Scenarios in 5.3, perf in 5.4, live smoke in 5.2.
- Accept: all E2E green twice in a row; perf thresholds met; post-run guard proves no file outside fixture roots was touched.

### 4.3 Contracts frozen by WS0 (signatures; additive changes allowed by owner, breaking changes via orchestrator)

```swift
// ScanKit
public typealias NodeID = UInt32
public struct NodeFlags: OptionSet, Sendable { /* directory package symlink hardLink hardLinkSecondary cloned restricted mountPoint firmlinkSkipped missing */ }
public struct ScanOptions: Sendable { var root: URL; var workers: Int?; var sizeMode: SizeMode?; var countClonesOnce = true; var excludedPaths: [String] = [] }
public enum ScanEvent: Sendable { case progress(ScanProgress), finished(ScanTree), failed(ScanError) }
public final class Scanner: Sendable { public init(_ o: ScanOptions); public func start() -> AsyncStream<ScanEvent>; public func cancel() }
public protocol TreeReading: AnyObject, Sendable {
  var root: NodeID { get }; var generation: UInt64 { get }
  func name(_: NodeID) -> String; func path(_: NodeID) -> String; func size(_: NodeID) -> UInt64
  func flags(_: NodeID) -> NodeFlags; func parent(_: NodeID) -> NodeID?; func children(_: NodeID) -> [NodeID]
  func descendantCount(_: NodeID) -> UInt32; func node(atPath: String) -> NodeID?
  func reclaimableBytes(_: NodeID, ifAlsoRemoving: Set<NodeID>) -> UInt64; func identity(_: NodeID) -> FileIdentity? }
public final class ScanTree: TreeReading { public func removeSubtree(_: NodeID); public func replaceChildren(of: NodeID, with: ScanTree) }
public struct VolumeInfo: Identifiable, Sendable, Hashable { /* url name kind fsType capacity available availableImportant isReadOnly isEncrypted isRemovable isNetwork isSSD supportsClones */ }
public enum VolumeCatalog { public static func current() -> [VolumeInfo]; public static func updates() -> AsyncStream<[VolumeInfo]> }
public struct SpaceSummary: Sendable { capacity used free purgeable otherVolumes scanned hidden; public static func compute(_: VolumeInfo, scanned: UInt64) -> SpaceSummary }
public struct ItemSummary: Sendable, Codable { nodeID path name bytes freesAbout kind items }   // freesAbout = reclaimable estimate
public final class TreeRefresher { public init(tree: ScanTree, root: URL); public func start(); public func stop(); public var events: AsyncStream<RefreshEvent> }
// RulesKit
public enum Risk: String, Codable, Comparable, Sendable { case safe, review, dangerous, never }
public struct Classification: Sendable { ruleID: String?; risk: Risk; categoryID: String?; explanation: String?; block: BlockReason? }
public enum BlockReason: String, Codable, Sendable { /* systemPath protectedRoot userData cloudSynced backup readOnlyVolume notInScan changedSinceScan specialItem scanRoot */ ; var message: String }
public struct SafetyPolicy: Sendable { public init(home: String); public func check(path: String, isDirectory: Bool, volume: VolumeInfo?) -> Classification }
public final class RuleEngine: Sendable { public init(home: String, rules: [Rule] = .bundled); public func classify(path: String) -> Classification; public func categories(in: any TreeReading) -> [CategoryResult] }
// CleanupKit
public struct QueueItem: Identifiable, Codable, Sendable { id path nodeID identity bytes freesAbout risk ruleID source isSelected }
public enum QueueSource: Codable, Sendable { case user, category(String), assistant(thread: UUID, reason: String) }
public enum DeletionMode: Sendable { case trash, permanent }
public protocol TrashProviding: Sendable { func trash(_ url: URL) throws -> URL? }
public actor CleanupExecutor { public init(policy: SafetyPolicy, trash: any TrashProviding, allowedRoot: URL?); public func run(_ items: [QueueItem], mode: DeletionMode) -> AsyncStream<DeletionEvent> }
// IPCProtocol
public enum JSONValue: Codable, Sendable, Hashable
public struct IPCRequest: Codable, Sendable { id: Int; method: String; params: JSONValue }
public struct IPCResponse: Codable, Sendable { id: Int; result: JSONValue?; error: IPCError? }
public struct ToolCallResult: Codable, Sendable { text: String; isError: Bool }
public struct ToolDefinition: Sendable { name description inputSchema: JSONValue annotations: JSONValue }
public enum ToolCatalog { public static let all: [ToolDefinition] }
// AIBridge
public protocol AssistantToolHandler: Sendable { func handle(name: String, arguments: JSONValue, thread: UUID) async -> ToolCallResult }
public enum ClaudeLocator { public static func locate(override: URL?) async throws -> ClaudeInstallation }
public struct StreamJSONParser { public mutating func feed(_ bytes: Data) -> [StreamEvent] }
public final class ClaudeSession: Sendable { public init(config: AssistantConfig, thread: UUID, resume: Bool); public func start() throws; public func send(_ text: String) throws; public func interrupt(); public func close(); public var events: AsyncStream<StreamEvent> }
public final class IPCServer: Sendable { public init(directory: URL, handler: any AssistantToolHandler); public func start() throws; public func register(nonce: String, thread: UUID); public func stop(); public var socketPath: String }
// AppCore (MainActor, @Observable)
AppModel { volumes, sessions: [ScanSessionModel], cleanup: CleanupModel, assistant: AssistantModel, fda: FDAStatus, settings }
ScanSessionModel { state, tree, summary, categories, current: NodeID, back/forward stacks; startScan(), cancel(), rescan(_:), navigate(to:), goUp() }
CleanupModel { queue, add(_:source:) -> AddResult, remove, run(mode:), lastReport, recentlyTrashed }
AssistantModel { availability, threads, active, items: [ChatItem], usage; send(_:), stop(), newThread(), select(_:) }
```

### 4.4 Conflict avoidance

- Single-writer files: `Package.swift`, `project.yml`, `Config/*`, `Makefile`: orchestrator only after WS0.
- `Localizable.xcstrings` is a hot spot: WS7b and WS8 each add keys in their own catalog files (`App/Resources/UI.xcstrings`, `App/Resources/Assistant.xcstrings`, tables referenced explicitly via `String(localized:table:)`); packages keep their own `Resources/*.xcstrings`.
- Tests live beside their module; shared fixtures only in TestSupport (WS10a).
- Contract change request = short note to orchestrator with the diff; owner applies after approval.

---

## 5. Testing strategy

All tests create data only under `$TMPDIR/appname-fixtures/<uuid>/` and delete it in teardown. Nothing ever targets real user files. Executor in test mode refuses paths outside `allowedRoot`.

### 5.1 Unit tests (`swift test --package-path Packages/Kit`, Swift Testing)

| Area | Cases |
|---|---|
| Scanner fixtures | nested dirs; files of exact sizes (oracle `st_blocks*512`); 10k files in one dir; 300-level deep path; hard links (same dir, different dirs, deleted primary promotes secondary); APFS clones (`copyfile COPYFILE_CLONE_FORCE`) counted once and shown as shared; symlink to outside dir not followed; symlink loop; sparse 1 GB file (allocated small); `.app`/`.bundle` packages; `chmod 000` dir -> restricted; empty dirs; NFD/emoji/newline names; disk image mount point leaf (`hdiutil attach -nobrowse`, gated `APPNAME_TEST_HDIUTIL=1`) |
| Scanner behavior | oracle equality; progress monotonic ending at 1.0; cancel < 200 ms; worker count 1 vs 32 identical trees; firmlinks file parser |
| Tree | removeSubtree updates ancestors; replaceChildren; generation bumps; reclaimable estimate with partial hard-link/clone sets; stride/footprint |
| Accounting | `SpaceSummary.compute` table tests (purgeable 0, important = 0, otherVolumes, clamp) |
| Refresh | create/delete/rename/move-out in fixture; MustScanSubDirs simulated |
| Rules | every B1 path -> rule+risk; every 2.5 path blocked; Data-prefix and case variants; symlink parent escape; nested match no double count; detectors; rules.json validation |
| Cleanup | dedupe parent/child; totals; trash (fake) and permanent; changed-since-scan; locked; symlink; allowedRoot; partial failure report; real Trash round trip (self-cleaning) |
| Stream parser | all samples; golden counts per file (e.g. `05-interrupt`: 1 controlResponse, result subtype `error_during_execution`; `02-mcp-partial`: 2 toolUseStart incl. `mcp__daisy__propose_deletion`, 2 toolResult); byte-split invariance; unknown types |
| Command builder / locator | golden argv; override; known paths in a temp HOME; shell fallback mocked |
| MCP helper | JSON-RPC golden transcripts; error codes; app-absent text |
| IPC | nonce mismatch, unsigned peer, wrong identifier rejected; valid helper accepted |
| VizKit | layout invariants, grouping, hit tests, AX labels |
| Strings | lint: no hard-coded UI strings outside catalogs; no U+2013/U+2014 in strings, rules, docs |

### 5.2 Integration tests

| Test | Gate | Pass criteria |
|---|---|---|
| Helper <-> app socket | always | spawned `mcp-helper` binary + in-process `IPCServer`; MCP `tools/call` reaches handler; result returned; peer check uses cdhash mode |
| fake-claude chain | always | `ClaudeSession(fake-claude)` -> helper -> IPC -> ToolHandler on fixture tree -> 2 queued, 1 rejected (protected fixture path) |
| Live claude smoke | `APPNAME_LIVE_CLAUDE=1` | real CLI with fixture home containing fake `Library/Developer/Xcode/DerivedData` and `Library/Keychains`; prompt "find safe things to clean"; init shows disk connected; >= 1 `propose_deletion` within fixture; Keychains never queued; `result.subtype == success`; estimated cost < 0.10 USD; nothing executed |
| Real root scan | `APPNAME_TEST_REAL_ROOT=1` | read-only scan of `/`: no duplicate firmlinked subtrees; accounting identity within 0.5% |

### 5.3 UI / E2E (XCUITest, verified working headless)

Launch arguments: `-AppNameUITestMode YES -AppNameFixtureRoot <dir> -AppNameFakeClaude <path>`. Test mode: skips onboarding, Start lists only the fixture root, `FixtureTrash`, executor `allowedRoot` = fixture, RuleEngine home = `<fixture>/home`, assistant uses fake-claude.

| ID | Scenario | Assert |
|---|---|---|
| E1 | Launch | Start shows fixture source row |
| E2 | Scan fixture | Explore root size label equals oracle (formatted) |
| E3 | Navigate | list row drill-in, map tile click, breadcrumb, Cmd+[ / Cmd+] |
| E4 | Quick Look + Reveal | QL panel appears on Space; Reveal invokes test hook |
| E5 | Trash flow | queue 2 items -> Move to Trash -> files in `.test-trash`, tree and totals updated, report shown |
| E6 | Permanent flow | countdown visible; Stop aborts (files intact); rerun completes (files gone) |
| E7 | Protected item | Add to Cleanup disabled with reason for `<fixture>/home/Library/Keychains` |
| E8 | Reclaim tab | categories with risk badges; "Add safe items" queues only safe |
| E9 | Live refresh | test writes a 5 MB file into fixture; size updates within 5 s |
| E10 | Assistant | consent accepted; send message; streamed text appears; proposal card; items in queue unselected |
| E11 | Assistant unavailable | fake path missing -> setup card |
| E13 | Quit guard | non-empty queue -> confirmation on Cmd+Q |
| Guard | every test | teardown asserts fixture-external sentinel files (created in a sibling temp dir) unchanged |

Optional manual pass: inspect the AX tree with Accessibility Inspector to confirm every control and map tile is exposed.

### 5.4 Performance

| Metric | Threshold (this Mac, 460 GB SSD, home about 296 GB) |
|---|---|
| `scanbench ~` warm | <= 45 s wall |
| `scanbench ~` first run after reboot | <= 90 s |
| Peak `phys_footprint` | <= 100 MB + 64 B x nodes |
| Totals vs `du -skx ~` (run with `--no-dedupe-clones`) | within 1% |
| UI during scan | no main-thread hang > 250 ms (os_signpost / hang reporter) |
| Explore drill-in on 1M-node folder | < 100 ms to first frame |
| Worker sweep | 8/16/32/48 recorded; default set to the fastest within 5% |

---

## 6. Build, sign, install, repo hygiene

```make
gen:      xcodegen generate
build:    xcodebuild -project AppName.xcodeproj -scheme AppName -configuration Release -derivedDataPath build build
debug:    xcodebuild -project AppName.xcodeproj -scheme AppName -configuration Debug -derivedDataPath build build
test:     swift test --package-path Packages/Kit
uitest:   xcodebuild -project AppName.xcodeproj -scheme AppName -derivedDataPath build test
lint:     scripts/lint.sh
verify:   codesign --verify --deep --strict --verbose=2 build/Build/Products/Release/AppName.app
          codesign -dv --verbose=2 build/Build/Products/Release/AppName.app 2>&1 | grep -E "TeamIdentifier|flags=.*runtime"
          codesign -dv build/Build/Products/Release/AppName.app/Contents/Helpers/appname-mcp 2>&1 | grep -E "Identifier|runtime"
install:  scripts/install.sh   # osascript quit app if running, wait for exit, ditto build/.../AppName.app /Applications/AppName.app, codesign --verify again
bench:    swift run -c release --package-path Packages/Kit scanbench ~ --json
ci:       gen lint test build verify uitest
```
- Gatekeeper: Apple Development builds run on this Mac only; `spctl` rejection is expected and not a failure. Public binaries later need Developer ID + notarization (`notarytool`); until then README says build from source.
- Repo: MIT `LICENSE`; README (what it is, screenshots later, build steps incl. `brew install xcodegen`, signing via `Signing.local.xcconfig`, FDA explanation, AI assistant privacy note, clean-room statement and that it is not affiliated with DaisyDisk); `.gitignore` (2.2 + WS0); `scripts/lint.sh` also greps for secrets (`sk-ant-`, `BEGIN .*PRIVATE KEY`, `ANTHROPIC_API_KEY=`) and env dumping patterns; no team-specific values committed except in the `.example` file; CI on GitHub deferred (hosted runners may lack Xcode 27), `make ci` is the gate.

---

## 7. Risks and open questions

### Risks

| ID | Risk | Mitigation |
|---|---|---|
| R1 | Extended clone attrs slow down `getattrlistbulk` | Perf test with and without; per-volume toggle |
| R2 | Swift 6 strict concurrency friction with raw buffers/threads | Engine internals `@unchecked Sendable` behind small audited types; tests under TSan |
| R3 | CLI protocol drift (`--max-turns` hidden, event shapes) | Capability detection, tolerant parser, live smoke test before releases |
| R4 | No reliable CLI signal for subscription vs API-credit login | Show org name + apiKeySource; app-side token guard per thread |
| R5 | SwiftUI `Canvas` perf with many tiles | min-area grouping caps tile count; layout cached per generation |
| R6 | FDA probe path behavior on macOS 26 | WS9 verifies; fallback probe; manual refresh button |
| R7 | Socket path length, stale socket files | `$TMPDIR` fallback; unlink stale on start |
| R8 | Trash unsupported on some network/external volumes | Detect error, offer permanent with explicit confirm |
| R9 | Firmlink skip approach misses edge cases | Gated real-root test + accounting identity check |

### Decisions for Alex (recommendation in bold)

1. App name: **Lightwell**, bundle id `com.alexluncan.lightwell` (decided).
2. Privileged helper: **defer to v2** (security; FDA covers almost all reclaimable space).
3. Assistant privacy: **opt-in consent, names/paths/sizes only, no contents**. Acceptable?
4. Default model and caps: **`sonnet`, 12 turns per message, 300k-token guard per thread**; billing follows the CLI login (subscription or credits), API keys blocked by default.
5. Deletion: **Trash default; permanent behind countdown; never clear `uchg`**.
6. Tool-managed cleanups (`simctl`, `brew`, `npm`): **guidance + Copy in v1, no execution**.
7. Minimum macOS: **26.0 only**.
8. Languages: **English only** (decided by user).
9. Clone accounting default: **count clones once (on)**, with a toggle.
10. GitHub repo name/owner and when to publish: **after Phase 3 green; build-from-source until Developer ID**.
