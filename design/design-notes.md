# Lightwell: design notes

Companion to `design/mockup.html` (open it directly in Safari or Chrome; deep links such as `mockup.html#B-explore-dark` pick direction, screen and theme; add `-still` to switch off motion, `-p55` to freeze the scan at 55%, `-sheet` to open the Trash confirmation).

All numbers in the mockup come from a real survey of the author's Mac (12 October 2026): 18.0 GB free of 460 GB, safe pass 45.1 GB, review 121.5 GB, keep 27.1 GB.

## 1. Names

Brief: short, ownable, pronounceable, evokes space, clarity or lightness, avoids the Disk and Clean cliches. Collision checks were web searches on 12 October 2026 (Mac apps, GitHub, Homebrew casks).

| Name | Rationale | Collision check |
| --- | --- | --- |
| **Lightwell** | An architectural shaft that brings daylight into the middle of a deep building. The app brings clarity to the deepest parts of your disk, and freeing space reads as "letting light in". | Low. Hullabalu's Lightwell (2017 storytelling app builder, team reportedly joined Twitter) appears dormant. No Mac utility, no notable GitHub repo, no cask. |
| **Atrium** | The open central room of a building: space you can breathe in. | Low to moderate. An Android (F-Droid) controller for self-hosted media servers. No Mac app found. |
| **Lacuna** | Latin for a gap or empty space; what the app creates. | Low. Only a small Python demo repo (foundryside-dev/lacuna). Slight "missing piece" connotation. |
| **Clearing** | An open space in a forest. Calm and literal. | No app found, but a common word: hard to search for and to own. |
| **Updraft** | Rising air: getting lighter. | Moderate. Updraft (getupdraft.com) is an app distribution service that added macOS in 2025, which is the same developer audience. |
| **Plumb** | Plumbing the depths; a plumb line measures depth. | Moderate. Lv-0/plumb is an MIT Swift menu bar window manager, plus a Plumb audio app and plan9port's Plumb.app. |
| **Headroom** | Perfect meaning (room left above the limit). | **Conflict.** Ryware/Headroom is a Mac disk tool (formerly DiskTree), and the `headroom` Homebrew cask is a Claude Code token tool. Ruled out. |
| **Ballast** | A balloon drops ballast to rise. | **Conflict.** jamsinclair/ballast is an MIT, open source Mac menu bar app with a Homebrew cask. Ruled out. |

Also checked and rejected: **Roomy** (an existing Mac developer cleanup tool for Xcode, Docker and node_modules: direct conflict), **Aloft** (Aloft Air Control drone app, Marriott Aloft hotels), **Glade** (GTK UI designer, SC Johnson air freshener brand).

**Top 3:** 1. Lightwell (used in the mockup), 2. Atrium, 3. Lacuna. A trademark search (USPTO, EUIPO class 9) is still needed before committing.

## 2. The three directions

All three share the same information architecture (Overview, Scan, Explore, Review queue, Assistant), the same safety model (risk badges Safe, Review, Keep, Locked; trash by default; undo; the AI proposes but never deletes), and the same data. They differ in personality, layout, typography and visualization. None uses a sunburst, a hue-by-angle palette, purple system space, a chart-left list-right split or a bottom drop strip.

### A. Daylight

> Calm, airy and native. Free space is drawn as light coming into the building, the map is a squarified treemap that reads like a floor plan, and Claude lives in a glass inspector you open when you want it.

For people who want the Mac to feel tidy again without learning a tool. Light-first.

**Palette**

| Token | Light | Dark |
| --- | --- | --- |
| Window | `#F7F5F0` | `#1B1A18` |
| Raised surface | `#FFFFFF` | `#25241F` |
| Ink / secondary / tertiary | `#1D1C19` / `#5E5B54` / `#8E8A82` | `#F2EFE8` / `#B3AEA4` / `#7E796F` |
| Primary action (ink button) | `#1D1C19` on `#F7F5F0` | `#F2EFE8` on `#1B1A18` |
| Free space "light" | `#F4C95D` | `#F2C14E` |
| Safe / Review / Keep | `#2F8A57` / `#C2621E` / `#6F7680` | `#5DBB84` / `#E58B4B` / `#9AA1AA` |
| Categories: Projects, Developer, Apps, App data, Media, Caches, Downloads, System, Other | `#A9C2EC #93CDB8 #EDBE94 #E9D592 #EDA9A6 #BEDB95 #97D3E2 #CFCAC0 #E3DFD7` | `#3F5F95 #2F6E5C #8A5A33 #7F6C2C #8A4A4A #55702F #2D6878 #4A4741 #34322E` |

**Type scale** (SF Pro Text for UI, SF Pro Rounded for figures): 11 labels / 13 body / 15 section / 22 to 24 screen titles and ladder figures / 54 hero figure. Rounded numerals give the big numbers a friendly, non-technical feel.

**Visualization: squarified treemap, two levels deep.** Area is size, which people compare more accurately than angles. A treemap fills the window's wide rectangle with no wasted corners, shows a folder and its children at once, and drills down by clicking. Parent frames take a 45% wash of their category colour and children use their own category colour, so "Library" shows its mix (App data, Developer, Caches) instead of one grey slab. Locked system data is hatched, never shown as free.

**Signature:** free space is a striped yellow "light" segment with a soft glow, and the overview's reclaim ladder states free space after each step (63 GB after Safe, 185 GB after Review).

### B. Core Sample

> Dense, exact, keyboard first. The disk is a core sample you read left to right, explored with an icicle chart, monospaced figures, rule IDs and a visible tool trace for people who want to see exactly what will run.

For developers (this user) who want to verify before they trust. Dark-first.

**Palette**

| Token | Dark | Light |
| --- | --- | --- |
| Window / panel / raised | `#121315` / `#17181B` / `#1B1C1F` | `#F2F1EE` / `#EAE9E5` / `#FFFFFF` |
| Ink / secondary / tertiary | `#E9E7E2` / `#A09D97` / `#6C6A66` | `#16171A` / `#5D5F64` / `#8D8F94` |
| Accent (signal orange, primary and destructive actions) | `#E8743B` | `#C9541C` |
| Safe / Review / Keep | `#7BC59A` / `#F0C24B` / `#8C929B` | `#2D8653` / `#9A6A0C` / `#6C727B` |
| Strata categories (same order as A) | `#C79A5B #6FAE8E #6E94C9 #B0807A #C9739B #9FB45A #5FB0B7 #5B5E63 #3E4146` | `#D6AE72 #86C0A2 #8EAEDB #C99A94 #DD94B5 #B6C978 #84C6CC #B7B9BD #D3D4D7` |

**Type scale** (SF Pro Text plus SF Mono for every number and path): 10.5 column heads (uppercase, tracked) / 11.5 paths / 12 body / 15 section / 19 to 22 meters / 32 "will free" figure. Monospaced figures keep columns aligned and make sizes scannable.

**Visualization: icicle (partition) chart, four levels.** Each row is a depth; width is size. Lengths along one axis are the most precise encoding, labels stay horizontal and readable, the top band doubles as a breadcrumb (click it to zoom out), and it maps directly onto a sortable table underneath. The overview uses the same idea at disk scale: one horizontal "core" bar with a GB axis.

**Signatures:** a path field instead of a title, ⌘1 to ⌘5 views, rule IDs (`dev.derived_data`), a method column (Trash, simctl, vendor uninstaller), a plan preview of exactly what will run, and a live MCP tool trace next to the chat.

### C. Companion

> Conversation first. Claude opens with a plain-language brief in a bookish serif voice, the disk is 460 countable one-gigabyte squares, and the assistant stays beside you on every screen.

For people who would rather be told than shown. Light-first, warm sage.

**Palette**

| Token | Light | Dark |
| --- | --- | --- |
| Window / raised | `#F1F2EC` / `#FBFBF7` | `#151916` / `#1E2420` |
| Ink / secondary / tertiary | `#1A231F` / `#55605A` / `#87908A` | `#E7ECE6` / `#A4AEA7` / `#6F7A73` |
| Accent (forest) | `#2D6A4F` on `#F4F7F2` | `#7CC39C` on `#0F1A14` |
| Safe / Review / Keep | `#2D7D52` / `#B8651B` / `#6E7570` | `#7CC39C` / `#E39A55` / `#97A09A` |
| Categories (same order) | `#4A78B5 #2F8A78 #D18D42 #B5654C #C35F7E #8DA64C #4FA1C4 #959A92 #C6CAC0` | `#6C9AD6 #4FB09C #E0A35E #CF7E64 #D97C99 #A8C066 #6BBAD9 #7A807A #4B524C` |

**Type scale:** New York (system serif) for Claude's voice and headings: 26 brief / 15.5 prose / 17 group heads; SF Pro for controls: 11 chips / 12.5 to 13 UI. The serif separates "Claude speaking" from "app chrome" at a glance. That is the one place a serif belongs in this product.

**Visualization: unit (waffle) chart.** Overview: 460 squares, one per gigabyte; 18 are empty outlines (free), and a switch highlights the 45 safe squares. Explore: small multiples, one block of squares per folder (biggest first), coloured by what is inside, with the unit rescaling (1 GB, 500 MB, 250 MB) as you drill down. Countable units are the most honest encoding for a non-technical reader ("each square is 1 GB"), and they make free space and reclaimable space literally visible.

## 3. Shared interaction decisions

* **Quick estimate before the scan.** The overview shows Safe, Review and Keep from 41 known paths in under a second; the full scan fills in the rest.
* **Scan screen** streams completed folders as they finish, counts files, folders, bytes and "safe found so far", and names the folder being read. B adds per-root progress; C fills the waffle in.
* **Review queue.** Safe items are pre-ticked, everything else needs a deliberate tick. Vendor items (Autodesk Fusion) and Keep items cannot be ticked and show the right action instead ("Uninstaller", "Open setting"). Simulator items route through simctl with an admin prompt.
* **Move to Trash** opens a sheet listing the items, warns that there is no Time Machine backup, and says Xcode and Spotify will be asked to quit. Afterwards a toast offers Undo, and free space updates everywhere.
* **AI proposals.** Tool calls show as chips ("Looked at ~/Library/Caches"). Proposals are cards with Add to queue / Not now; approved items appear in the queue tagged "Proposed by Claude". A refused proposal (Photos Library) appears as a quiet card: "Lightwell refused this path. Nothing was queued or deleted." The footer always says "Claude can look, not delete."
* **Mac Studio** appears as an offline network location so the app can verify projects exist there before you remove local copies.
* **Honest accounting.** 20.7 GB of system data that a normal scan cannot read is shown as locked and hatched, never as free.
* **Motion.** 160 to 300 ms ease-out transitions, scale(0.97) press feedback, screen cross-fade with a 4 px lift, no animation on keyboard navigation, and `prefers-reduced-motion` reduces everything to opacity fades.

## 4. SwiftUI mapping (macOS 26)

| Element | A Daylight | B Core Sample | C Companion |
| --- | --- | --- | --- |
| Window | `NavigationSplitView`, `.windowStyle(.automatic)`, `.toolbar` with grouped `ToolbarItemGroup` (Liquid Glass capsules are automatic in Tahoe) | Same, `.toolbarStyle(.unifiedCompact)`, path field via `ToolbarItem(placement: .principal)` | `HStack` of a custom glass rail and content; `.glassEffect(.regular, in: .rect(cornerRadius: 19))` on the rail, `GlassEffectContainer` for the segmented control |
| Sidebar | `List(selection:)` with `.listStyle(.sidebar)` (floating glass sidebar is the Tahoe default) | Same, `.keyboardShortcut("1", modifiers: .command)` per view | No sidebar; `Picker(.segmented)` in the toolbar |
| Map | `Canvas` drawing a squarified layout computed off the main thread; hit-testing via `onContinuousHover` + `SpatialTapGesture`; drill-down with `matchedGeometryEffect` | `Canvas` icicle, or Swift Charts `RectangleMark(xStart:xEnd:yStart:yEnd:)` | `LazyVGrid` of `RoundedRectangle`s for the 460 squares (or `Canvas` for speed); small multiples with a `Layout`-conforming flow layout |
| Lists / tables | `List` rows with `ProgressView(value:)` bars | `Table` with `TableColumn`s, `.monospacedDigit()`, `KeyPress` handling | `List` with serif `Text` notes |
| Charts | Overview capacity bar: Swift Charts `BarMark` stacked, one row | Core bar: `BarMark` stacked + `AxisMarks` every 50 GB | Waffle via grid; none needed |
| Fonts | `.font(.system(.largeTitle, design: .rounded))` for figures | `.font(.system(.body, design: .monospaced))` for numbers and paths | `.font(.system(.title, design: .serif))` (New York) for Claude |
| Materials | `.glassEffect()` on inspector and floating queue bar; `.background(.regularMaterial)` fallback | `.background(.thinMaterial)` for the summary panel | `.glassEffect(.regular.tint(.green.opacity(0.08)))` on the rail |
| Assistant | `.inspector(isPresented:)` with the chat view | Split `HStack`: chat + tool trace `List` | Rail grows with `withAnimation(.smooth)`; content collapses to a queue tray |
| Confirm | `.confirmationDialog` or `.sheet` with a destructive role button | Same, plus a `DisclosureGroup` showing the plan | Same |
| Undo | `UndoManager` registering `FileManager.trashItem` reversal; toast via overlay | Same | Same |

SF Symbols used: `internaldrive`, `externaldrive.connected.to.line.below` (network), `magnifyingglass`, `square.grid.2x2`, `tray.full`, `bubble.left`, `trash`, `arrow.uturn.backward`, `lock`, `checkmark.shield`, `eye`, `exclamationmark.triangle`, `sidebar.right`, `terminal`. Category colours become an asset catalog colour set per category with Any/Dark appearances; risk colours map to semantic names (`riskSafe`, `riskReview`, `riskKeep`).

## 5. Self-review (critique pass)

* **Hierarchy:** each overview leads with one figure (free space) and one decision (the Safe step). B is intentionally denser; its biggest figure is "Will free".
* **Safety visibility:** risk is always both colour and word (plus an icon), so it survives colour blindness; Keep and vendor items cannot be ticked.
* **Originality vs DaisyDisk:** no radial chart, no hue-by-angle, no purple, no bottom collector strip, different window structure in all three.
* **Known gaps:** the mockup has no empty or error states (Full Disk Access denied, scan failed, claude CLI not signed in); these need designing before build. Treemap labels at the deepest level and the C waffle for folders under ~1 GB need a minimum-size rule. Contrast of tertiary text on glass should be checked against WCAG AA in the real materials.
* **Recommendation:** ship A's structure and treemap as the default, borrow B's rule IDs, method column and tool trace as an "Advanced" disclosure, and C's serif brief as the first-run overview text.

## 6. Process notes

* Skills consulted: impeccable, design-taste-frontend, emil-design-eng, high-end-visual-design. Their guidance shaped the motion timings, the anti-slop rules (no gradient text, no side-stripe borders, no identical card grids) and the font choices. Apple system faces are used on purpose: they ship with every Mac and are what the SwiftUI app will render.
* The impeccable skill asked for a one-time cleanup script that edits skill files; it was not run because it changes local configuration outside this task.
* Screens were checked with headless Chrome in both modes and all directions; captures are kept out of the public repo because they show the maintainer's own folders. Open `design/mockup.html` in a browser to see every screen.

Sources for collision checks: [Ryware/Headroom](https://github.com/Ryware/Headroom/releases), [headroom cask](https://formulae.brew.sh/cask/headroom), [jamsinclair/ballast](https://github.com/jamsinclair/ballast), [Roomy on AlternativeTo](https://alternativeto.net/software/roomy/about), [Lightwell (TechCrunch 2017)](https://techcrunch.com/2017/04/24/hullabalu-lightwell/), [Atrium on F-Droid](https://f-droid.org/packages/app.atrium/), [lacuna repo listing](https://awesome.ecosyste.ms/projects/github.com%2Ffoundryside-dev%2Flacuna), [Updraft macOS distribution](https://getupdraft.com/blog/macos-app-distribution), [Lv-0/plumb](https://github.com/Lv-0/plumb/wiki), [Aloft Air Control](https://apps.apple.com/us/app/-/id1472965046).
