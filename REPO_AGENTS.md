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
    Minecraft folder chosen in Settings, for player names. Worlds open only through File ▸ Open
    and Open Recent: File ▸ Open World (fahlman/Chunksee#108) was removed on Ryan's decision of
    2026-10-16 (fahlman/Chunksee#155).
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
    Tile and scan directories share a SHA-256 key of the full dimension ID; punctuation and
    nested paths must not alias another dimension. Older lossy dimension directories are not
    read or migrated because their contents may belong to a different dimension. Dimensions
    rebuild cached data once; existing world-level pruning reclaims old directories.
- **Dependency:** ChunkseeKit (`https://github.com/fahlman/ChunkseeKit.git`), pinned "up to next
  minor" from `0.28.0`, resolved to `0.28.0` (`63508ececf6143fccd5e85a63a0ce51c008ed0e3`).
  - ChunkseeKit releases are annotated semver tags, and each tag needs Ryan's approval (see
    ChunkseeKit's `REPO_AGENTS.md`).
  - `Package.resolved` is tracked, so every build resolves the same ChunkseeKit commit.
  - Release order: tag ChunkseeKit first, then bump the pin here.

## Modules

All of the app's code is presentation; world-format rules live in ChunkseeKit.

`WorldSession.dimensionName` owns world-aware dimension labels for menus, prompts, accessibility
and location/detail rows. Colliding readable labels include their full IDs; unique labels stay
concise. This also disambiguates different paths within a namespace and unavailable locations.
`ReadableName` owns identifier-to-word formatting for structures and custom dimension labels as
well as items. Structures retain their variant word order; the three vanilla dimension labels
remain localized. Names do not replace identifiers or native document folder titles.

| File | Owns |
|---|---|
| `ChunkseeApp.swift`, `WorldDocument.swift` | A URL-based read-only `DocumentGroup` of dimension folders; opening a world folder as its dimensions, remembered world-folder access, opening metadata, document lifetime and moves |
| `AppModel.swift` | App-wide player names/saved searches, pending initial metadata reads shared by world URL, and the resources of each world with open dimensions |
| `WorldResources.swift`, `WorldIndexStore.swift` | One world's file access, readers, metadata, players, shared index, file watcher, startup cache maintenance, pending document-opening handles and jumps; the last session/opening drains reads and maintenance before relinquishing access |
| `WorldSession.swift` | One dimension document's map, search controls, history, ruler, selection and inspector; cross-dimension jumps open the destination dimension |
| `MapModel.swift` | Full and preview tile caches and the per-region render scheduler for one dimension; rendering for regions that leave the view is cancelled |
| `MapLayers.swift`, `HeatMap.swift` | Each world dimension tab's remembered layer/player/grid controls and Time Spent visibility; HeatMapLayer owns the live Time Spent flag, with persistence through LayerVisibility |
| `MapViewport.swift` | Conversions between view points and world blocks, plus pan and zoom |
| `Presentation.swift`, `GoToCoordinatesView.swift` | Coordinate labels using ChunkseeKit’s checked block conversion, block-center geometry, and native coordinate entry; exact entity positions stay unshifted |
| `MarkerGeometry.swift`, `MarkerStyle.swift` | Fixed marker geometry shared by drawing/picking; body, glyph, border, dimming and label presentation shared by map/export and applicable sidebar symbols |
| `PointMarkers.swift` | Immutable Places/creature arrays and region buckets, built on index publication and shared by map drawing/export, hit testing and accessibility candidates |
| `MarkerGeometry.swift` | Fixed marker body/symbol dimensions and the pointer reach derived from each body's radius, including selection sizes |
| `MapNavigation.swift`, `MapToolbar.swift`, `MapDepth.swift` | Per-document Back/Forward snapshots, native map controls and zoom presets |
| `SavedPlaces.swift`, `SavedPlaceViews.swift` | Local per-world annotations and native naming/sidebar controls |
| `MapRuler.swift`, `MapContextMenu.swift` | Block-distance measurement, shared SwiftUI saved-place/map commands, NSHostingMenu presentation and the narrow pasteboard boundary; every Copy Coordinates entry shares one X/Y/Z action |
| `RegionTileRenderer.swift` | Rendering a region (512×512 blocks) into a top-down image, off the main actor |
| `BlockColors.swift` | Block ID → map color |
| `Structures.swift` | Structure groups (names, icons, colors, default visibility) and the background structure scan |
| `Places.swift` | Point-of-interest groups, the background scan, and portal link status (grouping and linking rules from ChunkseeKit's `PointOfInterest` and `NetherPortal`) |
| `WorldSearch.swift`, `RegionIndex.swift` | Retained per-region index contributions, deriving complete dimension aggregates and answering searches against the world index |
| `SearchModel.swift` | Independent per-dimension queries against the shared world index, current immutable result snapshots, and shared saved searches |
| `PlayerNames.swift` | The Minecraft folder chosen in Settings and its access; names from local caches and, while permission remains on, Mojang; source lifetimes and cancellation |
| `RegionReader.swift` | Shared per-region passes, cancellation and draining when a world closes |
| `PlayerRecords.swift` | Statistics and advancements, and the current inspector request |
| `WorldCommands.swift` | Map and navigation menus routed to the focused document; SwiftUI supplies sidebar and inspector commands |
| `ReadOnlyDocumentMenus.swift` | A small AppKit menu hook that removes editing actions while preserving native Open, Open Recent, Close and Close All; SwiftUI's save group includes Close and has no separate Rename/Move placements |
| `SettingsView.swift` | Settings: the Minecraft folder and online name lookup |
| `PlayerMarkers.swift` | Player names and personal/named phrases, outdated and Bukkit rules shared by markers and inventory search, and which markers each dimension shows (data from ChunkseeKit's `PlayerInfo`) |
| `TileCache.swift` | Rendered tiles on disk in the app's Caches folder, keyed by region file size, modification date and renderer version |
| `ScrollWheelInput.swift` | A small AppKit view for arbitrary-view scroll deltas, which SwiftUI on macOS 27 does not expose; native hit testing scopes input to the map and its window |
| `ContentView.swift`, `MapView.swift` | SwiftUI views |
| `Creatures.swift`, `PetDetails.swift`, `VillagerText.swift` | Native creature inspector, shared saved villager job/level labels and pet appearance/collar labels, using shared health/equipment rows; applicability and data interpretation come from ChunkseeKit |
| `PlayerDetails.swift`, `PlayerStatus.swift`, `Equipment.swift`, `Health.swift`, `LinkedPets.swift` | Native player inspector, shared creature/player health and equipment rows, saved effect duration presentation, and links to this world's pets by owner UUID; parsing/calculation belongs in ChunkseeKit |
| `SidebarItem.swift`, `SidebarDisclosure.swift` | Live sidebar-item types, each dimension view's expanded groups and revealing a map marker's ancestors |

`DocumentGroup` owns opening, recent documents, windows, tabs and restoration. A world folder
chosen in the Open panel or Open Recent is read as a world: the reader remembers it, and its window
opens the dimension folders with SwiftUI's `openDocument` and then closes itself. Navigate ▸
Dimension and cross-dimension jumps also use `openDocument`, which brings an already-open dimension
to the front; a jump runs once that dimension's view exists, and is dropped if it fails to open.
The opening action captures only `openDocument`, so a view never keeps its own document alive.
macOS names each window and Open Recent item after its folder (`overworld`, `the_nether`,
`the_end`), so the window subtitle names the world. Each dimension's
map position is remembered in `RememberedViews`.
Each WorldSession has one fixed dimension, map and visibility scope. Cross-dimension actions
route only through the native document opener; an unavailable opener cannot replace the source
map. Back/Forward stores that document's viewports, and a native reread/move restores view,
ruler and history only when the dimension identity matches. No in-session dimension switching
or retired replacement maps are kept.

Initial dimension readers share AppModel's pending full-world metadata read, then the live
WorldResources. Every returned snapshot has its own WorldOpening handle; it attaches a session
before finishing that handle, or finishes on discard/deinit. Closing a tab cannot end access needed
by a pending sibling. The pending task holds an opening until its awaiters receive their own;
the last canceled requester cancels it, and generations protect a replacement read from old
completion. There is no separate completed metadata cache or timeout. Closing all sessions and
openings drains the world's work, and reopening rereads it. File access is never released through
a sibling's raw token. Metadata and resolved dimension-document paths are read off-main.
Existing-document rereads and native moves keep fresh coordinated reads. An unknown path in a
live catalog also goes through fresh validation. A fresh snapshot can add newly created dimensions
to the open world's catalog without replacing existing readers, maps or tab state. WorldIndexStore
owns the reader collection; WorldResources derives its dimensions/readers from it and retains the
resolved document-path lookup. Additions queue a complete pass behind an unfinished one, and last
world closure cancels/drains all readers. Discovery happens when a dimension is opened or freshly
validated; this does not add automatic directory discovery to the navigation menu or remove
already-open dimensions. DocumentGroup still owns document/window behavior.
The portal inspector only shows loading while the index has an actual pending reader for its
matching target dimension and no published portal result. Missing/unsupported/closed targets show
an unavailable message, without fabricating an empty list. Known-empty indexed targets retain
ChunkseeKit's normal prediction. The prediction footer appears only with an actual link result.

`MapDepth` is the map-owned selected Y and Surface/cutaway mode. Native SwiftUI toolbar controls
share it, and RememberedViews stores it per dimension alongside the viewport, including moves.
A depth change cancels rendering, hover and coordinate reads and clears all corresponding pixels
and named columns. Canceled tasks stay tracked until drain; job IDs/cancellation reject old output.
The renderer returns immutable pending cache writes with its tiles. MapModel starts writes only
for accepted render jobs, publishes pixels without waiting for compression/I/O, tracks low-priority
writes and cancels/drains them on close before cache-root cleanup. No renderer-owned detached
cache writer survives that drain.
Cutaway scans from at/below Y with no roof skipping. Surface keeps its existing Nether behavior.
Export uses the same current map. Tile renderer version 6 keys cutaways by Y and retains Surface
plus the latest cutaway per region, rather than every slider intermediate. Slider travel starts at
−64...319 and expands to include numeric entry; it does not constrain custom dimension generation.

The app observes SwiftUI's focused scene session to prioritize that world's front dimension and
remember its selection immediately. Native tab/window focus does not change a session's dimension;
inactive viewport saves preserve the front dimension, and closed sessions cannot reactivate it.
SwiftUI ScenePhase has no Quit event. The existing NSApplicationDelegate hook exposes the early
termination query so focus changes while AppKit closes tabs cannot overwrite the last front tab.
It returns the normal immediate reply for this app's read-only documents; native termination and
window restoration remain AppKit's. No tab/window focus bridge is used.

The read-only `DocumentGroup` uses SwiftUI's `.defaultLaunchBehavior(.suppressed)`. With no
documents to restore, the app stays running without an automatic Open panel or a new document.
File ▸ Open and Open Recent still use the native flow.

`ReadOnlyDocumentMenus` coalesces menu notifications into a queued main-thread pass. It never
changes item visibility inside AppKit's insertion/layout notifications, which invalidates native
menu backing indexes. The pass disables hidden key equivalents before hiding editing items.

Copy Coordinates writes three whole block coordinates separated by single spaces, in X Y Z order.
Marker hit testing supplies saved heights; terrain and two-dimensional saved places use the
renderer/hover reader's actual block height. `MapModel` owns, cancels and drains those background
reads before world access ends. A late result cannot replace a newer copy or another clipboard change.
Map accessibility locations expose the same Copy Coordinates action and saved heights. Coordinate
readouts use ChunkseeKit’s `BlockPosition` containing-block conversion, including negative fractions; unreadable saved positions
are unavailable for mapping. Player/creature positions remain exact, while death/respawn points,
saved places and coordinate-entry destinations use the center of their block for drawing and focus.

Map context commands resolve the pointer once through the selection hit test. Copy, Save Place and
Measure use the same clicked marker anchor, or the containing pointer block when no marker is hit.
A saved-place pin shares the sidebar's SwiftUI Rename, Copy and Remove commands, with Measure
available on the map. NSHostingMenu presents the SwiftUI commands; no manual NSMenuItem targets or
selectors are kept. The existing NSView captures context-click points because SwiftUI contextMenu
does not supply that point. Held menus disable/guard commands when their document closes.

`SearchModel.results(for:)` reads published results for the current or a saved query. It never
starts a synchronous scan. Each query retains its previous snapshot until its replacement is
ready. Unchanged saved queries reuse completed or pending work; index, player and name changes
invalidate it. Callers that need completion await `waitForSearch()`.

Live index refreshes replace only the notified terrain/entity/POI region contributions, retaining
the other regions and dimensions. Entity- and POI-only regions participate too. Storage, connected
biome areas, deposits and whole-portal grouping derive from the retained inputs. Queued changes
merge while a pass runs; broad requests dominate subsets. Initial/manual indexing covers the whole
world. Exact world, dimension or region-directory notifications reconcile full dimension contents
and terrain availability. Other files beneath a dimension, including saved data such as raids and
chunk tickets, do not invalidate region-derived results. Entity/POI file saves leave terrain images
and inhabited-time reads alone.
Places/creature point collections own their arrays and immutable region buckets. MapContent
shares them with per-tab group visibility; pan/hover does not rebuild buckets or filter the entire
arrays. Drawing, export, hit testing and accessibility request nearby candidates in original order,
then retain their exact bounds/zoom/distance checks. Fit World visits occupied buckets rather than
empty space. Structure areas and the smaller player/search/saved-place lists keep their existing paths.
Player refreshes reopen the world's metadata through ChunkseeKit, including the embedded
single-player record when `level.dat` changes. An unreadable save retains the last good players;
a successful empty read clears them. Opening metadata for the world details stays read-on-open.

Drawing and picking share MarkerGeometry's fixed badge radii, with six points of clicking
tolerance beyond the body. Labels, structure outlines and portal status decorations do not
enlarge the body target. Selected pets/search pins use their larger radius; nearby hit candidates
cover that reach. Player drawing, picking and VoiceOver visibility/centering share an anchor:
exact for the live entity, block-centered for death and respawn. Labels and coordinate copying
retain the saved coordinates. Marker zoom growth stays separate.
MarkerStyle defines the existing circle/rounded bodies, borders, glyph tints, opacity and caption
layout/thresholds. Body and caption drawing are shared across marker kinds; the per-frame glyph
cache keys the actual symbol and tint. Structure outlines/portal rooms, bounds culling and marker
ordering remain in MapView. Hidden captions do not format names or resolve text; semantic caption
fonts/layout are reused, and translucent caption fills are made only when shown. Existing outdated
map-player (0.55), sidebar-player (0.6) and claimed-place (0.65) dimming remain distinct. The player
and saved-place sidebar icons share their presentation owner, and the portal inspector uses its
group's symbol while retaining its singular title. No zoom-growth or visibility policy changes.

The creature inspector shows saved current/maximum health in hearts and applicable pet order,
appearance, collar and equipment from ChunkseeKit. Missing data stays absent. The selected
creature is resolved from the current shared index, so an open inspector follows saved changes.
Players and creatures share the native equipment section and health row. Health uses up to two
fractional digits in hearts, with a gauge when current and maximum are known and text for the
available values otherwise. Equipment keeps kind, custom name and count; slot order is shared,
empty stacks are omitted, and material tint applies to symbols while text uses semantic colors.
Rows and tooltips share the item/durability formatter. Format parsing and applicability stay in Kit.
Scan-cache version 13 rereads earlier entries for corrected pet maximums, stable creature UUIDs,
preserved legacy item wear, structure heights, cave-biome membership, checked entity-container
positions and missing villager-level defaults. A marker uses its saved
entity UUID across movement and shared positions, with the older position fallback only when
no UUID exists. The player inspector's pet links match saved owner UUIDs in this world's shared
index and open/select in the destination dimension document. No owner is inferred from a name.
Each activation requests SwiftUI ancestor expansion and scrolling, including a repeated link
or a jump received before the destination view appears; disclosure stays owned by that view.
Player health shows the actual saved maximum when available; active effects show saved duration,
not a live countdown. Equipment includes the selected main hand, durability and named enchantments.
Empty or unavailable optional sections/values stay absent.

Selecting a player works like selecting a pet (Ryan, 2026-10-16, fahlman/Chunksee#157): their row,
marker or VoiceOver location shows their details in the inspector and highlights their position,
replacing an in-game map overlay; a marker without details or an empty click closes them. Players
without a mappable position keep selectable rows for their details. Any player marker drawn in this
dimension shows its player, including a death or respawn point of somebody listed in another
dimension or with no current position; it selects a row only when this dimension lists them.

Layer controls are remembered separately for each world's dimension tab (Ryan, 2026-10-17,
fahlman/Chunksee#170): structures, places, creatures, biomes, hidden players, grid and Time Spent.
Existing app-wide preferences seed a new scope once; later tab changes never write the old keys
or another dimension's entry. Native world moves migrate every dimension's saved controls.
HeatMapLayer remains the live owner of Time Spent visibility and restores/persists its flag
through that dimension scope; there is no second editable flag in LayerVisibility.
It holds only that document's fixed region reader, heat images, pending task and reread flag;
there is no mutable dimension selector or per-dimension image/task store inside the layer.

The eye buttons and layer/player/saved-search context menus share one SwiftUI VisibilityCommand,
all using Show on Map/Hide on Map. SwiftUI exposes the button as a named accessibility action on
combined rows. Existing model bindings own the settings; the command only toggles its binding.
Saved-search menus also retain Search for This and Remove. Row navigation help says Center the
map, distinct from the visibility action.

WorldSession owns one selected item identity. The selected row, map/pin highlight and inspector
content are derived from current indexed data; portals and creatures do not retain stale detail
snapshots. The native inspector visibility and an in-game map retained under nondetail markers
are separate presentation state. Sidebar, pointer, VoiceOver and linked-pet input share that
selection transition. Selecting an item without details closes previous pet/player/portal details
(Ryan, 2026-10-17, fahlman/Chunksee#167). Empty/stale map input clears transient row/pin selection
while retaining the overlay and World Info, Storage or the overlay's own row. Map clicks and
VoiceOver marker actions select the corresponding native sidebar row. Only user
input through the List selection binding calls `choose` and requests sidebar focus. Pointer
selection keeps map focus and its viewport; VoiceOver retains its existing centering action.
The view requests ancestor expansion and scrolling with SwiftUI. Selection and disclosure use
one action shared with the behavioral tests. Search pins
select an existing result row (the active query first, then a shown saved query); one listed-hits function owns the 200-row limit and per-dimension policy for the sidebar, drawn
search pins and their resolver. Every drawn search pin has a reachable row. Save Search enablement
uses the same trimmed-query rule in the sidebar and Navigate menu.

Finder cannot distinguish an unmodified world folder from another `public.folder` by its
contents. `LSHandlerRank = None` keeps Chunksee out of Open With while retaining native opening
through File > Open and Open Recent. Opening folders from within the app and native window
restoration are required; Finder and Dock opening are not required. The old app-owned
recent/open-world preferences are removed; users reopen each old world once to establish
native history and restoration state.

Cave membership uses ChunkseeKit's paletteCounts() and only referenced entries; palettes without
cave candidates skip cell counting. Unused names never create cave areas/hover membership, while
all actually used areas and the full per-dimension vanilla-biome catalog remain. Scan-cache
version 12 invalidates earlier false membership; surface sampling and area grouping stay unchanged.

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

Rechecked on 2026-10-18 against [Apple's releases](https://developer.apple.com/news/releases/),
[its SDK table](https://developer.apple.com/xcode/system-requirements), and the
[Swift releases](https://www.swift.org/install/macos/), then compared with the installed tools
and the project's settings. Xcode 27.2 and Swift snapshots are previews, not the stable toolchain.

- **Compiler:** Xcode 27.1 (`27A9275`) and Apple Swift 6.4 (`swiftlang-6.4.0.34.1`).
- **Swift language mode:** 6 (`SWIFT_VERSION = 6.0`). The app and test targets also use:
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  - approachable concurrency
  - complete strict concurrency checking
- **SDK:** macOS 27.0 SDK.
- **Minimum macOS:** 27 (`MACOSX_DEPLOYMENT_TARGET = 27.0`). The app is Mac only, arm64.
