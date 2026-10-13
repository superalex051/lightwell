# AGENTS.md

Read this before you touch anything in this repository. It applies to every builder, human or agent.

Lightwell is a native macOS disk space analyzer and cleaner with a built-in assistant that drives the local `claude` CLI. Bundle id `com.alexluncan.lightwell`. The plan is `PLAN.md`; your dispatch brief lists the paths you own.

## Rules

1. No em dashes or en dashes (U+2014, U+2013) in anything a person reads: UI strings, docs, `rules.json`, comments in user-facing resources. Use a colon, a comma, parentheses or a plain hyphen instead.
2. Every user-facing string goes in a String Catalog (`.xcstrings`). App strings live in `App/Resources/*.xcstrings` (`Localizable`, `UI`, `Assistant`, `InfoPlist`); packages keep their own `Resources/*.xcstrings` and load them with `bundle: .module`. English only.
3. Never print, log or echo environment variable values or the MCP nonce (`LIGHTWELL_MCP_NONCE`). Not in code, tests, scripts, reports or commit messages.
4. Small surgical diffs inside your owned paths. `Packages/Kit/Package.swift`, `project.yml`, `Config/*` and `Makefile` are single-writer files: only the orchestrator edits them. Need a contract change (PLAN 4.3)? Make the smallest additive change and call it out in your report.
5. No third-party dependencies without orchestrator approval.
6. Clean-room rule: never copy DaisyDisk code, assets, palette, icons or wording; write original copy. Do not open `/Applications/DaisyDisk.app` or its helper. The design research behind the plan is private and not part of this repository.
7. Tests never touch real user data. Fixtures live only under `$TMPDIR/lightwell-fixtures/<uuid>/` (use `TestSupport.FixtureBuilder`) and are deleted in teardown. Never delete or move anything outside a fixture directory.
8. Every commit message ends with the trailer given in your dispatch.

## Build and test

```sh
brew install xcodegen          # once, if missing
make gen                       # generate Lightwell.xcodeproj (never committed)
make test                      # swift test for Packages/Kit (Swift Testing)
make build verify              # signed Release app + codesign checks
make uitest                    # XCUITest target
make lint                      # dashes, secrets, env dumping, string catalog keys
```

Build only inside your own checkout (`-derivedDataPath build`), keep compile jobs low (`-j 3`, `-jobs 3`) and delete `build/` and `Packages/Kit/.build/` when your task is done.

## Where things live

- `Packages/Kit`: one Swift package, many targets (ScanKit, RulesKit, CleanupKit, IPCProtocol, MCPServerKit, AIBridge, VizKit, AppCore, TestSupport, scanbench, mcp-helper, fake-claude). Tests in `Packages/Kit/Tests/<Target>Tests`.
- `App/`: SwiftUI app target (screens only, logic lives in AppCore). `Helpers/MCPHelper`: the embedded `lightwell-mcp` helper. `UITests/`: XCUITest.
- `Config/`: xcconfigs and entitlements. Personal signing goes in the gitignored `Config/Signing.local.xcconfig` (see the `.example`).
- Placeholders are marked `// TODO(WSn)` with the owning workstream.
- UI test launch arguments: `-LightwellUITestMode YES -LightwellFixtureRoot <dir> -LightwellFakeClaude <path>`.
