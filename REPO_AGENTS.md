# Chunksee — Repository Instructions

Read with the shared `AGENTS.md`.

## Project

Chunksee is a Mac app for viewing Minecraft: Java Edition worlds. Ryan approved it on 2026-10-09.
It was called MCWorld until 2026-10-10, when it and its engine (MCWorldKit, now ChunkseeKit) were
renamed (fahlman/Chunksee#75); earlier issues, PRs and commits use the old names.

- **First scope:** open a world and show a top-down view of it.
- **Later:** overlays for strongholds, villages and other structures. These aren't approved for
  work yet.
- **Dependency direction:** **Chunksee app → ChunkseeKit**. ChunkseeKit is the open-source engine
  that reads world files (fahlman/ChunkseeKit). This app owns presentation only. World-format
  rules belong in ChunkseeKit and are never re-implemented here.

## Approved decisions (Ryan, 2026-10-09)

- **Kind:** Mac app, developed as an Xcode project with a tracked `.xcodeproj`, SwiftUI
  interface.
- **Names:**
  - Product, repository, project and app target: `Chunksee`.
  - Unit test target: `ChunkseeTests`.
  - Bundle identifier: `com.fahlsing.Chunksee`.
- **Distribution:** local builds only. No release or distribution process is approved.
- **Signing owner:** Automatic signing with team `PUT2KYMV2W`, the same team as Euchre.
- **Sandbox:** App Sandbox and hardened runtime are on.
- **Entitlements:**
  - read-only access to files the user selects
  - app-scoped security-scoped bookmarks
  - outgoing network connections (`network.client`), used only to look up player names from Mojang
    when the user turns that on. Ryan approved this on 2026-10-10 (fahlman/Chunksee#11), off by
    default.
- **Data locations:**
  - The app reads only the world or saves folder the user picks with an Open panel, and the
    Minecraft folder chosen in Settings: File ▸ Open World lists the worlds in its installations'
    `saves` folders (Ryan, 2026-10-13, fahlman/Chunksee#108), found by ChunkseeKit's
    `World.saved(under:)`.
  - Each dimension folder is a native read-only folder document (Ryan, 2026-10-13); the world
    folder is not a document but contains one for each dimension, and opening it opens them. In
    the older layout, the Overworld's `region` folder stands for it. macOS owns opening, Open
    Recent, window tabs (by the user's tab preference) and restoration. Dimensions of one world
    share its resources, which close with the last of them.
  - Opening a world folder keeps an app-scoped, read-only bookmark to it, because the sandbox
    grants a reopened or restored dimension document only its own folder; the world's
    `level.dat`, players and other dimensions are read through that bookmark.
  - It never writes to a world folder.
  - Saved places are annotations in the app's local preferences, keyed by world URL; native
    document moves migrate them and remembered views. Navigation history and ruler endpoints
    belong to each dimension view, and are never stored in the world.
  - For player names, it reads `usercache.json` files under a Minecraft folder the user chooses in
    Settings (kept as a read-only bookmark). With online lookup on, it sends the UUIDs of players it
    can't name locally to `sessionserver.mojang.com` and keeps the returned names in its
    preferences.
  - Rendered tiles are kept in the app's Caches folder (about 1 GB at most).
- **Dependency:** ChunkseeKit (`https://github.com/fahlman/ChunkseeKit.git`), pinned "up to next
  minor" from `0.26.0`, resolved to `0.26.0` (`f887abb88991a0420e8a25b16e7203821692007c`).
  - ChunkseeKit releases are annotated semver tags, and each tag needs Ryan's approval (see
    ChunkseeKit's `REPO_AGENTS.md`).
  - `Package.resolved` is tracked, so every build resolves the same ChunkseeKit commit.
  - Release order: tag ChunkseeKit first, then bump the pin here.

## Modules

All of the app's code is presentation; world-format rules live in ChunkseeKit.

| File | Owns |
|---|---|
| `ChunkseeApp.swift`, `WorldDocument.swift` | A URL-based read-only `DocumentGroup` of dimension folders; opening a world folder as its dimensions, remembered world-folder access, opening metadata, document lifetime and moves |
| `AppModel.swift` | App-wide player names and saved searches, and the resources of each world with open dimensions |
| `WorldResources.swift`, `WorldIndexStore.swift` | One world's file access, readers, metadata, players, shared index, file watcher and jumps waiting for a dimension to open; closing its last dimension drains all reads before relinquishing access |
| `WorldSession.swift` | One dimension document's map, search controls, history, ruler, selection and inspector; cross-dimension jumps open the destination dimension |
| `MapModel.swift` | Full and preview tile caches and the per-region render scheduler for one dimension; rendering for regions that leave the view is cancelled |
| `MapViewport.swift` | Conversions between view points and world blocks, plus pan and zoom |
| `MapNavigation.swift`, `MapToolbar.swift` | Per-document Back/Forward snapshots, native map controls and zoom presets |
| `SavedPlaces.swift`, `SavedPlaceViews.swift` | Local per-world annotations and native naming/sidebar controls |
| `MapRuler.swift`, `MapContextMenu.swift` | Block-distance measurement and the narrow AppKit context-menu/pasteboard boundary |
| `RegionTileRenderer.swift` | Rendering a region (512×512 blocks) into a top-down image, off the main actor |
| `BlockColors.swift` | Block ID → map color |
| `Structures.swift` | Structure groups (names, icons, colors, default visibility) and the background structure scan |
| `Places.swift` | Point-of-interest groups, the background scan, and portal link status (grouping and linking rules from ChunkseeKit's `PointOfInterest` and `NetherPortal`) |
| `WorldSearch.swift` | The world index (each dimension's containers, signs, structures, places, creatures and biomes) and answering searches against it |
| `SearchModel.swift` | Independent per-dimension queries against the shared world index, current immutable result snapshots, and shared saved searches |
| `PlayerNames.swift` | The Minecraft folder chosen in Settings and its access, also read by `SavedWorlds`; names from local caches and, while permission remains on, Mojang; source lifetimes and cancellation |
| `RegionReader.swift` | Shared per-region passes, cancellation and draining when a world closes |
| `PlayerRecords.swift` | Statistics and advancements, and the current inspector request |
| `WorldCommands.swift` | Map and navigation menus routed to the focused document; SwiftUI supplies sidebar and inspector commands |
| `ReadOnlyDocumentMenus.swift` | A small AppKit menu hook that removes editing actions while preserving native Open, Open Recent, Close and Close All; SwiftUI's save group includes Close and has no separate Rename/Move placements |
| `SettingsView.swift` | Settings: the Minecraft folder and online name lookup |
| `SavedWorlds.swift` | The worlds in the Minecraft folder for File ▸ Open World, newest played first, reread when the folder changes or the app becomes active |
| `PlayerMarkers.swift` | Player names, outdated and Bukkit rules, and which markers each dimension shows (data from ChunkseeKit's `PlayerInfo`) |
| `TileCache.swift` | Rendered tiles on disk in the app's Caches folder, keyed by region file size, modification date and renderer version |
| `ScrollWheelInput.swift` | A small AppKit view for arbitrary-view scroll deltas, which SwiftUI on macOS 27 does not expose; native hit testing scopes input to the map and its window |
| `ContentView.swift`, `MapView.swift` | SwiftUI views |
| `Creatures.swift`, `PetDetails.swift` | Native creature inspector, pet appearance/collar labels and saved current/maximum health in hearts; applicability and data interpretation come from ChunkseeKit |
| `SidebarDisclosure.swift` | Each dimension view's expanded sidebar groups and revealing a map marker's ancestors |

`DocumentGroup` owns opening, recent documents, windows, tabs and restoration. A world folder
chosen in the Open panel or Open Recent is read as a world: the reader remembers it, and its window
opens the dimension folders with SwiftUI's `openDocument` and then closes itself. Navigate ▸
Dimension and cross-dimension jumps also use `openDocument`, which brings an already-open dimension
to the front; a jump runs once that dimension's view exists, and is dropped if it fails to open.
The opening action captures only `openDocument`, so a view never keeps its own document alive.
macOS names each window and Open Recent item after its folder (`overworld`, `the_nether`,
`the_end`), so the window subtitle names the world. Each dimension's
map position is remembered in `RememberedViews`.

The read-only `DocumentGroup` uses SwiftUI's `.defaultLaunchBehavior(.suppressed)`. With no
documents to restore, the app stays running without an automatic Open panel or a new document.
File ▸ Open and Open Recent still use the native flow.

`ReadOnlyDocumentMenus` coalesces menu notifications into a queued main-thread pass. It never
changes item visibility inside AppKit's insertion/layout notifications, which invalidates native
menu backing indexes. The pass disables hidden key equivalents before hiding editing items.

`SearchModel.results(for:)` reads published results for the current or a saved query. It never
starts a synchronous scan. Each query retains its previous snapshot until its replacement is
ready. Unchanged saved queries reuse completed or pending work; index, player and name changes
invalidate it. Callers that need completion await `waitForSearch()`.

The creature inspector shows saved current/maximum health in hearts and applicable pet order,
appearance, collar and equipment from ChunkseeKit. Missing data stays absent. The selected
creature is resolved from the current shared index, so an open inspector follows saved changes.
Scan-cache version 8 rereads entries made before the corrected pet maximums and durability
defaults, including current-health-only version 6. Creature identity still follows the existing marker-ID rules.

Map clicks and VoiceOver marker actions select the corresponding native sidebar row. Only user
input through the List selection binding calls `choose` and requests sidebar focus. Pointer
selection keeps map focus and its viewport; VoiceOver retains its existing centering action.
The view requests ancestor expansion and scrolling with SwiftUI. Selection and disclosure use
one action shared with the behavioral tests. Search pins
select an existing result row (the active query first, then a shown saved query); the 200-row limit
and per-dimension listing rules still apply.

Finder cannot distinguish an unmodified world folder from another `public.folder` by its
contents. `LSHandlerRank = None` keeps Chunksee out of Open With while retaining native opening
through File > Open and Open Recent. Opening folders from within the app and native window
restoration are required; Finder and Dock opening are not required. The old app-owned
recent/open-world preferences are removed; users reopen each old world once to establish
native history and restoration state.

## Build and test

Run from the repository root:

```sh
./script/build_and_run.sh --verify
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'platform=macOS' -configuration Release build
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'platform=macOS' -configuration Release test ENABLE_TESTABILITY=YES
```

Ryan requires Release for builds and launches unless he specifically requests Debug. The Codex
Run action uses `script/build_and_run.sh`, which defaults to Release and quits through AppKit
before rebuilding and opening the new bundle. `--debug` explicitly selects Debug.

- **Scheme:** `Chunksee` is shared and tracked. It builds the app and runs `ChunkseeTests`
  (Swift Testing).
- **Required checks:** `build` and `test` must both pass on the commit you publish, resolving
  ChunkseeKit from its pinned tag. A local package override doesn't prove a change.
- **Launch smoke check:** build, then `open` the app from DerivedData. Confirm it keeps running
  without an automatic Open panel or a new document when there is nothing to restore. Check that
  File ▸ Open shows its native panel, Cancel leaves the app running, and clicking its Dock icon
  with no documents open does not bring the panel back. Check opening several folders, opening
  one again, clearing Open Recent while documents stay open, and quitting/relaunching with the
  system's window restoration preference. To check document file access, use a **Release** build.
  Xcode adds test-runner entitlements to Debug builds,
  including read-only access to `/`, so a Debug build can't show sandbox problems.
- **Document menu smoke check:** with a world open, confirm native Open, Open Recent, Close and
  Close All remain and New, Save, Save As, Duplicate, Rename, Move and Revert are absent. Check
  Zoom In and Zoom Out with and without Shift and with another world or Settings focused.
- **Finder registration smoke check:** register a disposable Release app copy outside `/tmp`
  (Launch Services excludes temporary-directory apps from Open With). Confirm Chunksee isn't
  offered for plain folders or world folders.
  Unregister and remove only that test copy afterwards.
- **Automated GitHub checks:** none, because Ryan's projects run no hosted macOS CI. This was
  recorded on 2026-10-09.
- **Releases:** no release or distribution process is approved. Builds are local only.

## Toolchain and platforms

On 2026-10-09 these were verified as the newest non-beta releases on Apple's and Swift's release
pages, then compared with what this Mac uses.

- **Compiler:** Xcode 27.0 (`27A266a`) and Apple Swift 6.4 (`swiftlang-6.4.0.34.1`).
- **Swift language mode:** 6 (`SWIFT_VERSION = 6.0`). The app and test targets also use:
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  - approachable concurrency
  - complete strict concurrency checking
- **SDK:** macOS 27.0 SDK.
- **Minimum macOS:** 27 (`MACOSX_DEPLOYMENT_TARGET = 27.0`). The app is Mac only, arm64.
