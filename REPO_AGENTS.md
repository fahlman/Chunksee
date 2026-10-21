# Chunksee — Repository Instructions

Read with the shared `AGENTS.md`.

## Project

Chunksee is a Mac app for viewing Minecraft: Java Edition worlds. Ryan approved it on 2026-10-09.
It was called MCWorld until 2026-10-10, when it and its engine (MCWorldKit, now ChunkseeKit) were
renamed (fahlman/Chunksee#75); earlier issues, PRs and commits use the old names.

- **First scope:** open a world and show a top-down view of it.
- **Later:** overlays for strongholds, villages and other structures. These aren't approved for
  work yet.
- **Dependency direction:** **Chunksee app → ChunkseeKit and ChunkseeIndex**. ChunkseeKit is the
  open-source engine that reads world files (fahlman/ChunkseeKit); the same package's ChunkseeIndex
  product owns shared aggregation. This app owns presentation. World-format rules belong in
  ChunkseeKit and are never re-implemented here.

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
  - Saved places are annotations in the app's local preferences, keyed by the world bookmark's
    persistent identity, which survives folder moves. Navigation history and ruler endpoints
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
  minor" from `0.39.0`, resolved to `0.39.0` (`a4cad15318f860cc9ad62afdf521428b5141d201`).
  - ChunkseeKit releases are annotated semver tags, and each tag needs Ryan's approval (see
    ChunkseeKit's `REPO_AGENTS.md`).
  - `Package.resolved` is tracked, so every build resolves the same ChunkseeKit commit.
  - Release order: tag ChunkseeKit first, then bump the pin here.

## Modules

VisibilityCommand owns the shared Show/Hide label, binding and action. Compact eye buttons show
the current state; context-menu symbols show the action (crossed eye for Hide, open eye for Show).

All of the app's code is presentation; world-format rules live in ChunkseeKit.
ItemAppearance uses one filled tree for plant items across every item surface; BiomeGroup keeps
its leaf, following Ryan’s 2026-10-20 choice to distinguish those concepts. Shared symbols do not
need globally unique strings when their meaning is clear in context.

TradeText owns each complete villager offer for both the inspector and search results, including
the received item, both possible costs, enchantments and the saved sold-out status. Matching still
uses the separate searchable item names and identifiers, without presentation wording.
StructureGroup and PlaceGroup own the symbols shared by their sidebar rows and map markers.
Strongholds use a door rather than a visibility eye, Trial Chambers use stacked rooms rather
than the Slime Chunks grid. Other Places use the native more symbol for uncategorized block entities.
Find Player Names uses a settings gear because it opens Settings. Storage uses an archive box,
Unopened Loot a gift and Buried Treasure a shipping box, following Ryan's 2026-10-20 decision
to distinguish those categories. Time Spent uses a clock rather than the item flame. World Info
and the World rows use filled variants; native shapes without one keep their own symbol.
Ryan's requested Zoom magnifier remains.
ChunkseeIndex.StoredItemTotal owns storage quantities and outer-container counts, including nested
items. StoredItem projects its results into app display names and count/name order; it does not
repeat the aggregation. The app and isolated test host link both published products.

WorldDetails keeps game rules by saved ID and derives sorted display rows. Wandering-trader
status uses Kit’s GameRule lookup; readable or translated labels never decide whether a rule
disables spawning. Rows use saved IDs so equal readable names remain distinct.

`DimensionPresentation.NameStyle` owns world-aware dimension labels, derived from the live catalog
for native Text and the `dimensionName` string adapter used by window titles and other consumers.
It carries the locale and dimension IDs without retaining the document or introducing another catalog owner.
Colliding readable labels include their full IDs; unique labels stay
concise. This also disambiguates different paths within a namespace and unavailable locations.
`ReadableName` owns identifier-to-word formatting for structures and custom dimension labels as
well as items. Identifier syntax and default namespaces come from ChunkseeKit's `Identifier`;
the app only formats its path or retains an unfamiliar value as readable fallback text. Vanilla
structure/place groups and block-color lookup require the Minecraft namespace, leaving custom
IDs distinct. The RegionFacts cache and tile-renderer version 8 discard classifications and pixels
made before this adoption. Structures retain their variant word order; the three vanilla dimension labels
remain localized. Window titles and native tab labels use the same dimension name, with the world name as the
subtitle. Names do not replace identifiers or document URLs.

| File | Owns |
|---|---|
| `ChunkseeApp.swift`, `WorldDocument.swift`, `DocumentWindowTitle.swift` | A URL-based read-only `DocumentGroup` of dimension folders; opening a world folder as its dimensions, remembered world-folder access, opening metadata, document lifetime/moves, and native display names |
| `AppModel.swift` | App-wide player names/saved searches, pending initial metadata reads shared by world URL, and the resources of each world with open dimensions |
| `WorldResources.swift`, `PlayerSnapshot.swift`, `WorldIndexStore.swift` | One world's file access, readers, metadata, observable player roster and immutable publications, shared index, file watcher, startup cache maintenance, pending document-opening handles and jumps; the last session/opening drains reads and maintenance before relinquishing access |
| `WorldSession.swift` | Composes one dimension document’s feature models and owns document lifetime, view restoration and persistence |
| `DimensionPresentation.swift` | Live dimension labels, listing rules, index/biome/player/map/portal presentation and linked pets, computed from the existing owners |
| `MapModel.swift` | Full and preview tile caches and the per-region render scheduler for one dimension; rendering for regions that leave the view is cancelled |
| `MapLayers.swift`, `HeatMap.swift` | Each world dimension tab's remembered layer/player/grid controls and Time Spent visibility; HeatMapLayer owns the live Time Spent flag, with persistence through LayerVisibility |
| `MapViewport.swift` | Conversions between view points and world blocks, with one world-to-view transform for points, region tiles and area paths, plus pan and zoom; saved chunk/region coordinates use ChunkseeKit's position types. Hover, coordinate-copy and biome lookups use Kit's containing-chunk and local-column conversions |
| `Presentation.swift`, `GoToCoordinatesView.swift` | Coordinate values and their shared Foundation format style using ChunkseeKit’s checked block conversion, common CoordinateText digit styling, block-center geometry, and native coordinate entry; exact entity positions stay unshifted |
| `MarkerGeometry.swift`, `MarkerStyle.swift`, `MarkerLabels.swift` | Zoom-aware marker geometry shared by drawing/picking; body, glyph, border, dimming and label presentation shared by map/export and applicable sidebar symbols; deterministic label collision layout |
| `PointMarkers.swift` | Immutable Places/creature arrays and region buckets, built on index publication and shared by map drawing/export, hit testing and accessibility candidates |
| `MarkerGeometry.swift` | Marker body/symbol dimensions and pointer reach, with one common size at each zoom and selection-independent targets |
| `MapNavigation.swift`, `MapToolbar.swift`, `MapDepth.swift`, `MapZoom.swift` | Local navigation/history and native height/zoom popovers; MapModel owns viewport/depth |
| `DimensionRouting.swift` | Native opening callback, observable opening error, validated location focus and dispatch of cross-dimension app actions |
| `SelectionModel.swift` | One live selected identity, sidebar/map actions, inspector and overlay presentation, and scoped player-record reads |
| `MapAnnotations.swift` | One dimension’s saved-place draft/actions and ruler, with live access to the world’s shared SavedPlaces store |
| `SavedPlaces.swift`, `SavedPlaceViews.swift` | Local per-world annotations and native naming/sidebar controls |
| `WorldSettings.swift`, `WorldFolders.swift` | One versioned per-world presentation store keyed by bookmark identity; read-only world bookmarks and one-time legacy import |
| `MapRuler.swift`, `MapContextMenu.swift` | Block-distance measurement, shared SwiftUI saved-place/map commands, NSHostingMenu presentation and the narrow pasteboard boundary; every Copy Coordinates entry shares one X/Y/Z action |
| `RegionTileRenderer.swift` | Rendering a region (512×512 blocks) into a top-down image, off the main actor |
| `BlockColors.swift` | Block ID → map color |
| `Structures.swift` | Structure groups (names, icons, colors, default visibility) and the background structure scan |
| `Places.swift` | Point-of-interest groups, the background scan, and portal link status/return warnings (grouping, linking and round-trip rules from ChunkseeKit's `PointOfInterest` and `NetherPortal`) |
| `WorldSearch.swift`, `RegionIndex.swift` | Retained per-region index contributions, deriving complete dimension aggregates and answering searches against the world index |
| `SearchModel.swift`, `SavedQueryResults.swift` | Independent per-dimension search controls/snapshots, saved-query commands and the shared sidebar/map result projection; the world index owns shared pending/completed saved-query work |
| `PlayerNames.swift` | The Minecraft folder chosen in Settings and its access; names from local caches and, while permission remains on, Mojang; source lifetimes and cancellation |
| `RegionReader.swift`, `ScanCache.swift` | Coalesced Kit region reads, one versioned facts envelope per region, cancellation and draining when a world closes |
| `CacheKey.swift` | Current file size/date stamps and stable hashes shared by tile and scan cache keys; each cache owns its entry format/version |
| `BackgroundWork.swift`, `RefreshLoader.swift` | Scoped task registration, cancellation and draining, plus retained-value refresh coalescing |
| `PlayerRecords.swift` | Statistics and advancements, and inspector-scoped reads registered with the world |
| `WorldCommands.swift` | Map and navigation menus routed to the focused document; SwiftUI supplies sidebar and inspector commands |
| `ReadOnlyDocumentMenus.swift` | A small AppKit menu hook that removes editing actions while preserving native Open, Open Recent, Close and Close All; SwiftUI's save group includes Close and has no separate Rename/Move placements |
| `SettingsView.swift` | Settings: the Minecraft folder and online name lookup |
| `HelpView.swift` | On-demand native Help window with opening/navigation instructions and the User Guide link |
| `PlayerMarkers.swift` | Player names and personal/named phrases, outdated-location wording and coordinate validation shared by markers and inventory search, and which markers each dimension shows (data from ChunkseeKit's `PlayerInfo`) |
| `TileCache.swift` | Rendered tiles on disk in the app's Caches folder, keyed by region file size, modification date and renderer version |
| `ScrollWheelInput.swift` | A small AppKit view for arbitrary-view scroll deltas, which SwiftUI on macOS 27 does not expose; native hit testing scopes input to the map and its window |
| `MapContent.swift` | A map-content value projected directly from live feature models; its shared marker candidates, hit tests and accessibility locations |
| `MapScene.swift` | Biome areas and structure, Places, creature, search, player and saved-place items, sharing coordinates, drawing anchors, geometry/style, selection targets and accessibility between drawing/export and input; area shapes stay separate from point badges, and region buckets keep point drawing/pointer candidates local |
| `ContentView.swift`, `MapView.swift` | SwiftUI views |
| `Creatures.swift`, `PetDetails.swift`, `VillagerText.swift` | Native creature inspector, shared saved villager job/level labels and pet appearance/collar labels, using shared health/equipment rows; applicability and data interpretation come from ChunkseeKit |
| `PlayerDetails.swift`, `PlayerStatus.swift`, `Equipment.swift`, `Health.swift`, `CountedText.swift`, `LinkedPets.swift` | Native player inspector, shared creature/player health and equipment rows, native fractional heart/block unit wording and counted sidebar headings, saved effect duration presentation, and links to this world's pets by owner UUID; parsing/calculation belongs in ChunkseeKit |
| `SidebarItem.swift`, `SidebarDisclosure.swift` | Live sidebar-item types, each dimension view's expanded groups and revealing a map marker's ancestors |

`DocumentGroup` owns opening, recent documents, windows, tabs and restoration. A world folder
chosen in the Open panel or Open Recent is read as a world: the reader remembers it, and its window
opens the dimension folders with SwiftUI's `openDocument` and then closes itself. Navigate ▸
Dimension and cross-dimension jumps also use `openDocument`, which brings an already-open dimension
to the front; a jump runs once that dimension's view exists, and is dropped if it fails to open.
The opening action captures only `openDocument`, so a view never keeps its own document alive.
Native window and tab titles use `DimensionPresentation.dimensionName(_:)`, the same localized,
collision-safe name as the menus. URL-based DocumentGroup in macOS 27 retains folder titles
with navigationTitle at the document root, split-view root or map detail (verified in Release).
The small DocumentWindowTitle view sets only NSDocument.displayName through its existing
window controller; SwiftUI still owns the document, URL, window and native tabs. A view-scoped
observation reapplies the model’s display name if native restoration resets it; moving or closing
the view ends that observation. The adapter never edits a file URL or document contents.
The subtitle names the world; document URLs and native Open Recent remain tied to their folders.
Each dimension's map position is remembered in the world's `WorldSettings`.
WorldView owns the transient Go to Coordinates sheet flag. Navigate's command uses the focused
scene binding, while the sheet keeps its existing native controls and calls MapNavigation.
Other map commands remain disabled under the coordinate or saved-place sheets. WorldDocument's
existing per-session view identity resets this transient state on a native reread or move.
`MapNavigation` applies local focus, coordinate jumps, Fit World and Back/Forward through the
document's existing MapModel, which remains the only viewport/depth owner. All location jumps
keep the destination dimension's current zoom, including spawn, player locations, portal links
and in-game maps (Ryan, 2026-10-20, #293). Callers cannot override that rule. Explicit zoom controls,
Fit World and Back/Forward still change or restore viewports. It owns history but
has no tasks or separate closed flag; MapModel's existing lifetime guards late navigation.
Native reread/move restoration copies history, viewport and depth into the new model, including
from an already closed source, without sharing that source's map or history. Cross-dimension
location validation and player-focus availability belong to DimensionRouting, which dispatches
through the native opener. Local marker centering calls MapNavigation directly with X/Z and does
not invent a saved Y. DimensionRouting refers
weakly to its source document for identity and closed state, without a second lifetime flag.
LocationRow shares the native inspector button and location menu for creature/portal Location,
map Center, World Spawn and player locations. It calls DimensionRouting's common coordinate
validation and focus path, including real X/Z positions without a saved Y. Unknown destinations,
invalid coordinates and closed documents cannot jump. Player block positions retain block-center
navigation; World Spawn matches Go to Spawn's saved point. Clicking a location keeps the current
inspector and map depth, while the destination's zoom follows the shared keep-zoom rule.
WorldResources keeps the latest waiting app action per destination, shared across source documents;
a failed earlier opening cannot discard a newer action. A native opening can outlive its source,
but errors are presented only while that source remains open. Native commands and
the toolbar call the navigation model directly for local actions.
DimensionPresentation derives the world spawn once as a MapDestination: saved coordinates,
dimension and block anchoring. Initial placement, sidebar distances, Go to Spawn and the World
Spawn row all consume that destination. LocationRow passes it unchanged to routing; no control
reconstructs the spawn or chooses its block rule. MapDestination keeps the saved copy/menu values
separate from its map anchor; every jump keeps the destination’s zoom.
SelectionModel owns the selected identity, inspector visibility and retained in-game map overlay.
Sidebar actions, map clicks and linked-pet jumps call it directly; details still resolve against
current shared world data. It refers weakly to its document and adds no snapshot or closed flag.
The document closes and drains its player-record reads with its other feature models. Native
inspector bindings observe this model; marker drawing/highlights read its same derived selection.
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

`RegionReader` delegates the terrain/entity/POI traversal to Kit's `Dimension.scan`. It stores
one `RegionFacts` envelope per region, validating all three file fingerprints, scan options,
`RegionFacts.interpretationVersion` and `ScanCache.transformVersion`. Old per-part entries are
ignored and removed after a successful replacement. Scans request the app's notable block IDs;
the complete envelope uses Foundation JSON under LZFSE compression (transform version 2),
including nonfinite saved numbers. Binary-plist decoding was the dominant measured cache-read
cost in the first migration; the storage codec does not change the facts or their ownership.
Nether biome sampling explicitly uses Y64, with surface sampling elsewhere. Kit owns biome usage,
section counts/heights, formats and inhabited time; RegionIndex only groups those facts for views.
Kit 0.39.0 supplies actual-column surface sampling when a heightmap is absent, including
valid default-namespace air names. Empty middle columns do not invent a biome area from a
neighbor or unused palette entry. RegionFacts interpretation version 6 rejects earlier surface
and empty-item facts through the existing cache validation; transform version 2 is unchanged.
This adoption does not change renderer colors, roof handling, Nether sample Y or the held cave list.
Concurrent requests share cache decoding/scanning. File-open errors and cancellation do not write
cache entries, and a save during a scan prevents persisting that snapshot. Failed refreshes retain
previous index and heat contributions; successful empty reads and deleted files remove them.

`MapDepth` is the map-owned selected Y and Surface/cutaway mode. A native SwiftUI toolbar button
shows Surface or the current Y and opens a standard popover. Its segmented mode picker, labeled
slider, bordered number field and stepper share that owner; height controls are disabled on Surface.
The native Done button and Escape shortcut dismiss the popover with SwiftUI’s dismiss action.
Standard controls determine their sizing, with no fixed frames. WorldSettings stores depth per
dimension alongside the viewport, including moves.
Native View-menu commands open the same popover (Shift-Command-Y) and toggle Surface
(Option-Command-Y), so default macOS keyboard navigation can reach the feature. A focused scene
binding exposes the view-owned popover flag; MapDepth still owns the mode and height. The Cutaway
number field receives SwiftUI focus on opening or switching from Surface.
Selecting a known-height item updates MapDepth through SelectionModel. Cutaway renders at that
height; Surface keeps its mode and pixels while remembering the height for the next switch.
Pointer and accessibility actions carry the clicked marker's Y, including death/respawn markers
whose player's current position differs. Unknown heights leave the current Y alone. Selection
changes Y once, without following later live movement; linked pets affect the destination tab.
Slider dragging holds an unfinished height in the view and commits it only when released
(Ryan, 2026-10-19, #84/#248). The map, cache and remembered view keep their committed depth
during the drag. Exact-number entry and non-drag slider changes apply immediately; leaving the
popover discards an unfinished drag. WorldDetails reads dimension types through Kit 0.33.0 in the
existing off-main metadata pass. DimensionPresentation supplies the current dimension’s verified
build range to the slider; logical height and ceiling metadata do not define the slider or renderer.
Numeric entry and its stepper accept any Int, without extending the slider’s limits. The slider
thumb clamps to those limits until the user chooses a new value; its accessibility value describes
that thumb. The number field handles SwiftUI's exit command directly so Escape dismisses the
popover even before an edit is submitted; the native Done button supplies dismissal elsewhere.
Missing/unreadable/unresolved types show “Height range unavailable” in place of the
slider while retaining numeric entry. Newly discovered dimensions adopt their fresh type metadata;
existing documents’ metadata and remembered heights are not replaced by that catalog extension.
A depth change cancels rendering, hover and coordinate reads and clears all corresponding pixels
and named columns. Canceled tasks stay tracked until drain; job IDs/cancellation reject old output.
The renderer returns immutable pending cache writes with its tiles. MapModel starts writes only
for accepted render jobs, publishes pixels without waiting for compression/I/O, tracks low-priority
writes and cancels/drains them on close before cache-root cleanup. No renderer-owned detached
cache writer survives that drain.
MapModel registers render jobs, accepted cache writes, hover reads and coordinate copies in four
scopes of the world's BackgroundWork owner. Separate scopes preserve depth-change cancellation
without canceling an already accepted cache write. Their combined drain includes work added
while another map task finishes, and never waits for a sibling tab. Per-region render IDs, hover
generations and active handles still own replacement and selective cancellation; canceled tasks
stay in the common registry until they return. World close rejects late pixels and copy results.
Cutaway scans from at/below Y with no roof skipping. Surface keeps its existing Nether behavior.
Export uses the same current map. Tile renderer version 6 keys cutaways by Y and retains Surface
plus the latest cutaway per region, rather than every slider intermediate. Slider limits come from
the saved dimension type, including custom definitions, without changing terrain or roof behavior.

The app observes SwiftUI's focused scene session to prioritize that world's front dimension and
remember its selection immediately. Native tab/window focus does not change a session's dimension;
inactive viewport saves preserve the front dimension, and closed sessions cannot reactivate it.
SwiftUI ScenePhase has no Quit event. The existing NSApplicationDelegate hook exposes the early
termination query so focus changes while AppKit closes tabs cannot overwrite the last front tab.
Before returning the normal immediate reply, the app's existing termination hook asks AppModel
to save every live dimension's current viewport/depth through WorldResources. This flushes the
one-second viewport debounce without waiting for document deinitialization or changing the
front dimension. No world files are written; native termination and restoration remain AppKit's. No tab/window focus bridge is used.

The read-only `DocumentGroup` uses SwiftUI's `.defaultLaunchBehavior(.suppressed)`. With no
documents to restore, the app stays running without an automatic Open panel or a new document.
File ▸ Open and Open Recent still use the native flow.
Help ▸ Chunksee Help opens a separate SwiftUI window only when requested, with opening and
navigation instructions and a User Guide link. It owns no document-opening or sample-world flow.
The bundled sample remains on #92 until Ryan provides his world.

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

Viewport-to-region and grid conversions check finite values and integer bounds before forming
ranges. Invalid persisted centers or zooms are ignored; an invalid live viewport cannot replace
a previously valid saved view. Grid iteration checks its step arithmetic as well as its endpoints.
The toolbar percentage opens a native SwiftUI zoom popover with a logarithmic slider, localized
number entry, existing presets, −/+ buttons, Actual Size and Fit World. The titlebar has only the
percentage control; menu/keyboard zoom commands remain available. Manual controls use 6.25% through
3,200%; Fit World can remain smaller. Opening or dismissing the popover leaves a fitted scale
unchanged. Slider changes apply continuously; Return or leaving the number field commits a valid
edit, while invalid/out-of-range text returns to the current percentage. Escape discards an
unsubmitted edit. MapModel's existing viewport remains the only zoom owner, separately per tab;
the popover keeps only an unfinished text edit and its presentation state.
Region/chunk index keys, tiles and scan results use Kit's RegionPosition and ChunkPosition
directly. Kit owns chunk-to-region/local coordinates and checked chunk/region origins; app scans,
hover reads, biome geometry and block-search pins use those properties. The previous x/z cache-key
encoding is unchanged. Unrepresentable chunk origins do not become map areas or search pins.
Region drawing/fitting also uses Kit's checked block origins. Continuous view geometry uses one
block-size constant, tested against Kit; the tile renderer's pixel size is independent of it.
The renderer owns its one-pixel-per-block canvas size; view rectangles remain CGFloat geometry.
Batched column scans use Kit's ChunkSection.blockIndex for each Y plane, sharing block layout
with the reader. The app retains palette batching, material colors and roof/water presentation.

MapContent resolves the pointer once for selection, ruler clicks and context commands. Copy, Save
Place and Measure use the same marker location, or the checked containing block when no marker is hit.
LocationMenu supplies those same three commands for the Structures, Places, Creatures and Biomes
sidebar rows. MapLayerMarker supplies the saved Y to both the row menu and map scene; unknown heights
use the map's terrain read. Group visibility and saved-place Rename/Remove menus remain separate.
Pointer and accessibility activation share the measuring-versus-selecting action; a measurement never
moves the viewport or changes selection. Outside measuring mode, accessibility retains its centering action.
A saved-place pin and sidebar row share one SwiftUI menu for Rename, Copy, Measure and Remove.
Saved places and other map locations use one measurement command. MapAnnotations.canMeasure owns
its availability and the action's guard: an open document with that dimension's map.
NSHostingMenu presents the SwiftUI commands; no manual NSMenuItem targets or
selectors are kept. The existing NSView captures context-click points because SwiftUI contextMenu
does not supply that point. Held menus disable/guard commands when their document closes.

`SearchModel.results(for:)` reads published results for the current or a saved query. It never
starts a synchronous scan. Each query retains its previous snapshot until its replacement is
ready. Each world's `WorldIndexStore.savedQueries` shares identical pending/completed saved-query
work across dimension documents, keyed by index revision, the shared player-snapshot identity and
player-name presentation. `WorldResources` publishes one immutable `PlayerSnapshot` per completed
player read; current and later documents share that instance. Checking query sources never compares
player NBT. A newly published read invalidates saved results even if its data happens to be equal;
names can invalidate independently. Typed unsaved queries remain per document. Removing a saved query retires its cached
work; an active typed waiter can still finish. Closing one document releases its wait without
cancelling a sibling's saved query. Closing the world cancels and drains shared passes, including
retired work still finishing after cancellation. Callers that need snapshots await `waitForSearch()`.
SearchModel registers its typed/saved-query waiter tasks in its own BackgroundWork scope. Active
queries retain their identity and handle for selective cancellation; canceled replacements stay
in the common registry until they finish. Local close releases saved-query waiter leases and
closes only that search's scope. World close refuses further queries, rejects late results and
clears completed active handles without leaving `isSearching` stuck. The scope supplies the
drain, replacing the separate task table; source generations and result retention remain local.

WorldIndexStore registers index passes in a BackgroundWork scope supplied by its world. A local
index close cancels/drains only its passes; world-owner close rejects late publication and queued
work. The index still owns merged region-change requests, dimension priority and publication as
each dimension finishes. Its current-task handle serves `waitForIndex`; the scope retains and
drains every pass, replacing the separate task dictionary. Search models forward the explicit
owner when they construct their own index. SavedQueryResults registers its passes in a separate
scope of the same owner. Its query entries keep only handles needed for individual retirement;
the scope retains canceled retired passes until they return and supplies the complete drain.
Explicit cache/index close releases waiter continuations immediately, while world-owner close
also refuses new reads and rejects late results. Saved-query caching, source identity and each
document's waiter lease remain owned by SavedQueryResults.

`PlayerNames` owns local reads and online batches across documents. Its app-wide BackgroundWork
instance has independent local-cache and online-lookup scopes; a world's close cannot cancel
names used by another world. Source changes cancel only their scope, and model deinitialization
cancels both. Canceled folder reads retain their file access until completion. There is no
separate online task dictionary. Overlapping local reloads share one pending handle; later
reloads still reread the source. Closing one caller does not cancel
globally useful work; choosing/forgetting a folder or revoking online permission and Clear Names
still cancel/invalidate their sources. The view request follows folder, online permission and the
known player UUID set, including players without reliable coordinates, so new players trigger lookup
without reloading for every position change. Online remains off by default and permission-gated.

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
empty space. MapScene creates their shared items from those candidates, deferring formatted names
until a caption or accessibility label needs them. Picking queries the pointer's reach rather than
building every item in the viewport. Its priority keeps portals ahead of creatures independently
of drawing order; accessibility retains structures, Places, creatures, biome areas, search, players, saved places.
Structure items share badge coordinates/targets with their area outline and portal-room decoration.
Area culling keeps visible outlines even when their badge is offscreen; only the badge is a pointer
target or accessibility child. Point items carry no area-decoration storage.
Biome scene items share their projected area frame between drawing/export and accessibility.
Their shapes still draw when the representative chunk is offscreen; accessibility retains its
20-point representative-location margin. World-space fill/outline paths are transformed only
when drawn, and pointer-only scenes skip biome items entirely. Biomes have no invisible badge
target. Their original paint order below the grid, border and marker bodies stays unchanged.
Player refreshes reopen the world's metadata through ChunkseeKit, including the embedded
single-player record when `level.dat` changes. An unreadable save retains the last good players;
a successful empty read clears them. Opening metadata for the world details stays read-on-open.

Drawing, picking and accessibility share MarkerGeometry's badge radius at the scene's zoom.
Every point badge has an 18-point body at overview zoom, then grows with a block up to 32 points
(Ryan, 2026-10-20, #164). Marker kind and selection never change the body size or glyph box.
MarkerStyle kinds supply only SF Symbols and colors. Every body is a circle, with one glyph box,
border, selection highlight, dimmed opacity and caption font/layout. Captions appear from 200% or
while selected for every kind; name/position/action data and collision priority remain in MapScene.
Portal warning badges remain status information, and portal selection uses the common highlight.
Symbols, caption offsets and portal decorations follow the body; picking adds the same six-point
tolerance beyond it. Labels, structure outlines and portal status decorations do not
enlarge the body target. Selection uses the existing highlight rather than a larger body; nearby
hit candidates cover the shared reach. Point picking also respects the drawing margin, so its larger tolerance cannot
select a badge culled from the scene. Player drawing, picking and VoiceOver visibility/centering share an anchor:
exact for the live entity, block-centered for death and respawn. Labels and coordinate copying
retain the saved coordinates. Structure and biome outlines keep their world bounds. Canvas
accessibility children use the same badge-body frames and actual map positions in a SwiftUI ZStack; biome children use their area bounds.
Panning, zoom and block-centered anchors therefore move their native accessibility frames
along with the drawing, while the existing actions and visibility rules stay the same.
MarkerStyle defines the common circle, border, selection highlight, dimming and caption
layout/threshold. Only colors and SF Symbols vary by kind; the per-frame glyph
cache keys the actual symbol and tint. Structure outlines/portal rooms, marker
ordering, bounds culling and portal decorations belong to MapScene. Hidden captions do not format names or resolve text; semantic caption
font/layout is reused, and translucent caption fills are made only when shown. Outdated
players and claimed places use one 0.6 dimming value, also used in the player sidebar. The player
inspector and sidebar share the player's marker symbol. Beds and respawn markers share the filled
bed symbol from PlaceGroup. Saved places retain the map pin; Other Places use the native more
symbol, and Other Structures use a dashed square for a generic area. The portal inspector uses its
group's symbol while retaining its singular title. Per-layer visibility remains with MapContent.
Eligible marker captions share one collision layout in Canvas and export: selected items first,
then players, then named pets, then other markers, with stable identity breaking ties. Lower-priority
labels that overlap an accepted label's two-point margin are omitted. Marker bodies, hit targets
and VoiceOver names remain available independently of caption collisions. Labels draw after the marker
bodies; the ruler keeps its existing topmost position. Caption text is measured once for layout
and drawing, and a spatial lookup limits comparisons to nearby accepted labels.

Unopened Loot reuses Places, its per-dimension hidden-by-default toggle, search, point buckets,
selection, accessibility and coordinate copying. Sealed containers come from RegionFacts through
ItemContainer.isSealedLoot and lootTable; the app names the saved table without predicting items
or inferring surrounding structures. Chest minecarts retain their saved UUID through Kit 0.34.0,
so colocated carts stay distinct and selection survives movement; only missing/unreadable IDs use
the existing kind/position fallback policy. Block containers use their fixed block coordinates.
Opened containers disappear from the group on the existing region refresh. Kit interpretation
version 3 rereads cached containers for UUIDs; the app adds no second cache or file reader.

InspectorHeading supplies the selected item's icon, headline and accessibility heading for
creature, player, portal, in-game map, World Info and Storage panels. World Info and Storage
share their symbol with the sidebar. The native Form/Table bodies keep their own layouts.
ItemAppearance.mapSymbol supplies the same filled map glyph for inventory navigation items,
the in-game-map inspector and map share preview. BiomeGroup owns the filled leaf used by its
sidebar groups and the biome search kind; callers do not keep separate copies of those symbols.

Health, Absorption, Hunger and Experience use SavedStatusRow for aligned digits and saved-value
help. Creature health, including carried pets, appears under Status like player health; unavailable
health does not create an empty creature Status section. HealthPresentation owns that availability.
HungerPresentation owns the game's food maximum and half-drumstick conversion; its gauge
and CountedText label consume that same value and maximum, preserving the saved value in text.
CountedText applies native grammar agreement to the maximum, like the hearts label.

The creature inspector shows saved current/maximum health in hearts and applicable pet order,
appearance, collar and equipment from ChunkseeKit. Missing data stays absent. The selected
creature is resolved from the current shared index, so an open inspector follows saved changes.
VillagerText uses Kit's computed `Villager.isUnemployed` for job-label availability. The app
owns readable labels, but does not interpret saved `minecraft:none` or malformed professions;
nitwits and valid custom professions remain distinct.
Player equipment rows use Kit's `PlayerInfo.equippedItems`, including the selected main hand;
the app keeps only presentation slot filtering, ordering and labels. The player inventory grids
use Kit's `inventorySlots(in:)` for hotbar,
storage and ender chest; saved slot numbers, empty slots and duplicate handling stay in Kit.
The app owns only the grid and selected-hotbar styling. Players and creatures share
the native equipment section and health row. Health uses up to two
fractional digits in hearts, with a gauge when current and maximum are known and text for the
available values otherwise. Equipment keeps kind, custom name and count; slot order is shared,
empty stacks are omitted, and material tint applies to symbols while text uses semantic colors.
CountedText is the shared Foundation FormatStyle for fractional heart/block units, used directly by
SwiftUI Text and by string consumers. Its locale modifier follows the native formatting contract;
rounding and grammatical agreement remain owned by that one style.
ItemAppearance.LabelStyle supplies native equipment Text and the name adapter used by trades and
tooltips. Its existing item/count helpers own kind, custom name, book title/author and optional one;
the style passes its locale through those helpers. Durability wording is shared too.
Format parsing and applicability stay in Kit.
The RegionFacts cache rereads earlier entries with Kit 0.29's versioned pet health, equipped modifiers,
shared UUID interpretation and cleaned display text. Earlier corrections remain: stable creature UUIDs,
preserved legacy item wear, structure heights, cave-biome membership, checked entity-container
positions and missing villager-level defaults. A marker uses its saved
entity UUID across movement and shared positions, with the older position fallback only when
no UUID exists. The player inspector's pet links match saved owner UUIDs in this world's shared
index and open/select in the destination dimension document. No owner is inferred from a name.
Each activation requests SwiftUI ancestor expansion and scrolling, including a repeated link
or a jump received before the destination view appears; disclosure stays owned by that view.
Player health shows the actual saved maximum when available; active effects show saved duration,
not a live countdown. PlayerEffectText.NameStyle owns effect names and vanilla exceptions,
independent of enchantment names; both share level numeral presentation. Visible effect rows and
their accessibility representation use that native style, and the string adapter forwards to it.
Saved effect durations use native localized clocks
and explicit localized units for accessibility, rounding partial seconds up in both readouts.
`GameDuration` owns saved tick conversion and the configured native Duration.UnitsFormatStyle.
Views format validated durations directly through SwiftUI Text; string consumers use that same style.
World Age and Time Played
show completed seconds/minutes/hours rather than dropping every duration below an hour; effects
keep rounding partial seconds up. Time Spent legend labels use those same native units. The
trader estimate keeps its within-a-minute threshold and completed-minute approximation, using
the same formatter restricted to minutes. The world's day-cycle clock remains a separate concept.
Equipment includes the selected main hand, durability and named enchantments.
TradeText.EnchantmentStyle owns the enchantment name/level phrase for native Text and the string
adapter used by trades and tooltips. Its verified single-level exceptions remain distinct from
effect rules; both use the same LevelText numerals.
Empty or unavailable optional sections/values stay absent.

WorldResources owns one observable PlayerRoster for all dimension searches and inspectors. Each
accepted read publishes one immutable PlayerSnapshot there; searches observe that snapshot
instead of receiving pushed assignments in every tab. SearchSources still compares snapshot
identity, so query edits never traverse saved player NBT. Shared saved queries continue to reuse
only matching publications, and closed searches do not restart when the roster changes.

StatisticRow supplies shared names and native values to the player inspector and All Statistics.
The table's raw category/statistic IDs keep row identity independent of equal readable names;
raw saved numbers remain the numeric sort values. The summary's stable Time Played row uses Kit's
playTime value, including its legacy fallback, rather than choosing a saved field itself.
Kit supplies scaled units, while the app uses native elapsed time,
metric distance and the shared heart wording. Unknown units retain their raw numbers. The inspector
keeps its primary counts and 100-meter travel cutoff; the complete table retains every saved row.

PlayerRecordsModel keeps the selected player's request identity and rejects replaced results.
Its reads register in a BackgroundWork scope: cancellation and draining affect only that inspector,
including older canceled reads, while world close still cancels and drains every scope. Closing
or dropping a scope refuses future work and cancels its pending reads. A caller's cancellation
continues to cancel only its own player-record read; selection replacement is not a coalesced
Time Spent refresh. The model no longer keeps a second task registry or close loop.

Tile-cache renderer version 7 refreshes surfaces affected by Kit 0.29's heightmap correction.
When a packed heightmap has an ambiguous width, the renderer's existing block scan finds the
surface; it does not infer a dimension's build height from its occupied sections.

Selecting a player works like selecting a pet (Ryan, 2026-10-16, fahlman/Chunksee#157): their row,
marker or VoiceOver location shows their details in the inspector and highlights their position,
replacing an in-game map overlay; a marker without details or an empty click closes them. Players
without a mappable position keep selectable rows for their details. Any player marker drawn in this
dimension shows its player, including a death or respawn point of somebody listed in another
dimension or with no current position; it selects a row only when this dimension lists them.

WorldSettings owns one versioned preference record per world for views, cutaway depths, front
dimension, layer controls and saved places. WorldFolders associates a persistent UUID with each
read-only bookmark in its existing registry; the opening reader resolves it off-main and passes
the identity to WorldSettings. The resolved bookmark URL retains security scope; canonical paths
are only comparisons, never replacements for that access URL. Native folder moves keep that UUID;
separately opened copies get their own, and unresolved bookmarks retain their identity. No identifier is written into a world.
Opening settings imports the former path-keyed worldSettings/mapView/mapLayers/savedPlaces once,
using the current path and the bookmark's original path even after a rename while closed. Legacy
move collisions keep source view choices and destination annotation names, as before. Thereafter
no settings relocation is needed. WorldResources shares this owner; SavedPlaces and each dimension's
LayerVisibility retain their live state. Annotation JSON is encoded only for annotation edits or
legacy move merging, never for viewport/layer saves. Live file readers still follow the native
document's new URL. Direct world/session opening conveniences exist only in TestWorld; production
always obtains identity through its document reader. App-wide preferences stay separate.

Layer controls are remembered separately for each world's dimension tab (Ryan, 2026-10-17,
fahlman/Chunksee#170): structures, places, creatures, biomes, hidden players, saved places, grid and Time Spent.
Saved Places defaults to shown for new and older settings. Hiding its pins keeps the sidebar
list and annotations; creating or visiting one reveals them in its dimension, while renaming leaves
visibility unchanged. MapAnnotations owns editor commits and their shared reveal path. MapContent applies
the flag once for drawing, picking, accessibility and export.
Existing app-wide preferences seed a new scope once; later tab changes never write the old keys
or another dimension's entry. Native world moves migrate every dimension's saved controls.
HeatMapLayer remains the live owner of Time Spent visibility and restores/persists its flag
through that dimension scope; there is no second editable flag in LayerVisibility.
It holds that document's fixed reader through a RefreshLoader. The loader owns its current value,
pending pass and reread flag; no mutable dimension selector or per-dimension store is kept inside
the layer. Hidden invalidation waits until shown, while an already running read may finish.
RefreshLoader coalesces saves during a pass, retains the previous value and rejects results after
its own or its world's close. Canceling a waiter does not cancel the shared read. WorldResources
owns BackgroundWork, which retains registered tasks until completion and drains work added during
a wait. A tab closes only its own loader; world close cancels and drains all registered work before
releasing file access. Index, search, map, player-record and refresh readers now use the same
owner with their own cancellation scopes, as described above. Source and request identities
remain with the models that validate their results. Startup cache maintenance also
registers with BackgroundWork, keeping its off-main I/O boundary and cancellation checks. The
world's common drain includes a maintenance write already underway before cache cleanup or
file-access release; there is no separate maintenance-task handle.

WorldResources uses that common drain for detached tabs too; it keeps no retiring-view task
table or cleanup tasks. Each WorldSession retains its own closing join because a native document
reread or move must await that session before replacing it. DocumentGroup still owns document
closure, and the world releases folder access only after its readers and registered work finish.

WorldResources registers live refreshes in a scope of the same BackgroundWork owner. The scope
tracks overlapping player reads and supplies the refresh-only drain; world close cancels and
drains them through the common registry. The two-second scheduling window, changed-region
aggregation and newest-player-read publication guard remain owned by WorldResources. It no longer
keeps another refresh-task dictionary, cancel-all loop or drain loop.
The continuous-save regression controls the existing delay through `waitBeforeRefresh`, then
awaits the refresh scope; production still sleeps for `refreshDelay`. Its fixture disables real
filesystem notifications so the test alone supplies the events being checked.

Time Spent, Slime Chunks, Grid, marker-group headers, players, Saved Places and saved-search headings share
MapVisibilityRow, including spacing, combined accessibility and row-scoped context menus.
Saved Places is a counted disclosure group under the plain Places section, at the same depth as
the other marker groups. WorldView composes native sections; LayerGroups owns marker grouping and
rows. SidebarDisclosure reveals Saved Places and its Places ancestor for map-origin selection.
Its eye buttons and context menus share one SwiftUI VisibilityCommand,
all using Show on Map/Hide on Map. SwiftUI's accessibilityActions exposes that same command as a
named action; the visual eye is excluded from the combined label so a disclosure heading's
primary action only expands or collapses it. The same binding supplies each eye row's localized
Shown on Map/Hidden on Map accessibility value. Existing model bindings own the settings; the
command only toggles its binding.
Saved-search headings add Search for This and Remove in a separate native menu section.
Those group commands belong to the heading, rather than its result rows. Row navigation help says Center the
map, distinct from the visibility action.
Layer-marker, player and search-result coordinate captions include their saved Y through the
shared Coordinates formatter and CoordinateText. Missing heights stay absent; map centers,
biome areas and saved-place annotations do not acquire an invented or terrain-derived Y.
LocationLabel supplies one native Label layout for those marker/player/search rows, saved places,
in-game maps and Linked Pets: icon, up to two lines of name, then a single secondary caption.
Coordinates and optional kind/dimension/scale context stay with the existing presentation owners;
context precedes coordinates. Maps retain their thumbnail, with the shared map symbol as a fallback.
Selection, visibility, menus and navigation remain outside this stateless label.

SelectionModel owns one selected item identity. The selected row, map/pin highlight and inspector
content are derived from current indexed data; portals and creatures do not retain stale detail
snapshots. A selected search result retains its search-row identity while its typed source identifies
the marker or player whose current details are shown. A player inventory or ender-chest result
remains selectable without a mappable location. The native inspector visibility and an in-game map
retained under nondetail markers are separate presentation state. Sidebar, pointer, VoiceOver and linked-pet input share that
selection transition. Selecting an item without details closes previous pet/player/portal details
(Ryan, 2026-10-17, fahlman/Chunksee#167). Empty/stale map input clears transient row/pin selection
while retaining the overlay and World Info, Storage or the overlay's own row. Map clicks and
VoiceOver marker actions select the corresponding native sidebar row. Only user
input through the List selection binding calls `choose` and requests sidebar focus. A simultaneous
sidebar tap also requests its existing focus, including when the already-selected row leaves the
binding unchanged; it does not select, navigate or replace native row/control actions. Pointer
selection keeps map focus and its viewport; VoiceOver retains its existing centering action.
The view requests ancestor expansion and scrolling with SwiftUI. It scrolls when native disclosure
animation finishes, so expanding rows above the viewport cannot undo the reveal by preserving the
old visible rows. Completion is ignored after document closure or a change of selection. Row
identity stays with ForEach; no per-row identity wrapper or timed retry is added. Selection and
disclosure use one action shared with the behavioral tests. Search pins
select an existing result row (the active query first, then a shown saved query). SearchModel owns
the 200-row limit and deduplicated pins for the sidebar, map and click resolver, using the document’s
common dimension-listing predicate. Views and commands save queries through that same model.
Choosing a saved-query result reveals that query through SavedSearches, like choosing a hidden layer row.
Every drawn search pin has a reachable row. Save Search enablement
uses the same trimmed-query rule in the sidebar and Navigate menu.

LocationRow owns the generic Location label (Last Location for a player’s saved location), following
Ryan’s 2026-10-20 choice. World Spawn, Last Death, Respawn Point and a map’s Center keep their specific roles.

LocationMenu supplies the same Copy Coordinates, Save Place and Measure Distance commands for
map markers, generic layer/player/search/map rows, linked pets and inspector positions. Each caller
supplies the saved position, dimension and optional height. LocationRow keeps native LabeledContent
layout and one menu for its label and value. Its value disables LabeledContent's automatic text
selection, whose native text menu otherwise intercepts right-clicks; Copy Coordinates remains the
shared command and produces Minecraft's space-separated XYZ. Other form values retain text selection.
Player-location buttons attach that same menu to the button, outside its navigation-disabled state,
so a saved location can still be copied or saved when its dimension is unavailable.
CopyCoordinatesCommand uses the
session's map only when its dimension matches; a saved height can be copied without a map, while
unknown heights in other dimensions disable Copy rather than read unrelated terrain. Saved-place
menus share that copy command. Measurement remains scoped to the current dimension through
MapAnnotations. Opening a menu or copying/saving a location does not navigate; existing ruler
and jump behavior is unchanged.
Committing a new place enables Saved Places in its destination through WorldResources, which updates
open documents' LayerVisibility or remembers the layer for a later opening. It never opens or activates
that dimension; choosing a saved place still performs the native cross-dimension jump.

MapAnnotations owns each dimension’s draft sheet and ruler. Native document rereads restore the
measurement without reviving a draft. It refers weakly to the document for existing navigation,
selection and cross-dimension routing; SavedPlaces owns live annotations and WorldSettings persists them.
Views bind to the model directly, and the document keeps no forwarding copy of annotation state.
MapContent constructs its value directly from the document’s live models for drawing and export.
It keeps no document reference or separate cache; SwiftUI observation follows those same models.
DimensionPresentation supplies the shared labels and listings directly from WorldResources,
SearchModel and LayerVisibility. It holds only a weak document reference, with no copied snapshot,
observation storage, task or lifetime flag; observation reaches the existing data owners. Linked
pets use the same projection, while MapImage owns the export entry point. WorldSession retains
composition, native document lifetime and view restoration/persistence, not presentation forwarding.
Tests call WorldResources directly for live-refresh control.

DimensionRouting owns location availability and the distinction between missing coordinates,
an unavailable dimension and a closed world. Navigation, saved-place and in-game-map validation
share that result. Location labels use the common dimming style and availability help; player
and search rows keep their existing details selection when they cannot navigate. Ender Chest
search explains that it has no single location. Inspector location buttons share the same reason
without disabling their surrounding copy/save context commands.

SidebarDisclosure owns expansion for every top-level sidebar section. Native Section bindings
all start open, keep each dimension view's choices, and let marker/action selection reopen only
the selected row's ancestors. Active search pins reveal Search Results; saved-only pins reveal
the Saved Searches section and that query's group. Nested group disclosure and content visibility
remain separate from section expansion.

Finder cannot distinguish an unmodified world folder from another `public.folder` by its
contents. `LSHandlerRank = None` keeps Chunksee out of Open With while retaining native opening
through File > Open and Open Recent. Opening folders from within the app and native window
restoration are required; Finder and Dock opening are not required. The old app-owned
recent/open-world preferences are removed; users reopen each old world once to establish
native history and restoration state.

Cave membership filters the library's actually used biome IDs. Unused palette names never
create cave areas/hover membership; all actually used areas and the full per-dimension vanilla
biome catalog remain. The app owns the cave category list and neighboring-chunk area grouping.


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
  (Swift Testing) in `ChunkseeTestHost`, a separate target with the fixed bundle ID
  `com.fahlsing.Chunksee.Tests`. The host compiles the same app sources but starts an empty
  settings scene instead of creating the real app's stores or restoring documents. Tests import
  that host module. The test action defaults to Release, matching Ryan's configuration preference;
  the host and test targets enable testability in Release so Command-U and plain `xcodebuild test`
  work without a command-line override. The ordinary app target is not built for testing and
  does not enable testability in Release.
- `ChunkseeApp` alone supplies `.standard` and `TileCache.root`; all store/cache consumers require
  explicit arguments. Tests use `TestDefaults.make()` inside `.isolatedStores` suites. The trait
  removes every suite's persistent domain and `.plist` after the async test returns, including
  failures, and fails if the host's standard domain changed. Every test suite carries this trait.
  Each suite uses an absolute preference domain inside a disposable temporary directory, so
  cfprefsd cannot recreate empty files in Preferences after host exit. Teardown removes the
  domain and its whole directory. Cache tests pass temporary roots or `nil`.
- The isolated `ChunkseeTestHost` links `ChunkseeKitTestSupport` alongside `ChunkseeKit` and
  `ChunkseeIndex` from the published pin. The test bundle uses them through its existing host, keeping a single library
  instance. Linking test support separately to the bundle makes Xcode 27.1 promote the shared
  Kit target to a dynamic library, whose build graph cannot resolve its CZlib target.
  `TestWorld` keeps
  app scenarios and session-opening conveniences, while shared `Fixtures` owns packing, section
  and chunk construction, region writing and compressed NBT files. App fixtures explicitly use
  26.3, yPos 0 and zero region timestamps; their status key follows the shared modern builder.
  Tests for both uppercase and lowercase status remain. The production app depends only on
  `ChunkseeKit` and `ChunkseeIndex`; shared fixture code is confined to the isolated test host.
  Player fixtures keep their original NBT inputs for file writes through Fixtures.writeGzippedNBT;
  neither the app nor its tests read raw save data back from PlayerInfo.
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

The sidebar's width modifiers belong to the `NavigationSplitView` column root (the
`ScrollViewReader`), not its nested `List`. The column opens at 220 points and its SwiftUI
frame/native split item both enforce a 180-point minimum. Native resizing remains in charge.

Time Spent uses `RegionFacts.inhabitedTimes`, including legacy `Level` chunks whose terrain
cannot be rendered. Region-file URLs use `Dimension.regionURL` for terrain, entities and POI;
spawn navigation uses the library's paired saved position and dimension.

The Slime Chunks toggle is initially off and remembered per dimension. It is available only for
the Overworld when `WorldDetails` has a seed read by ChunkseeKit. The View menu and sidebar share
SlimeChunkLayer's visibility and availability; the row and command stay visible but disabled when
unavailable. `SlimeChunkLayer` builds a small
32×32 mask per saved region using `World.isSlimeChunk`, off the main actor, reusing masks across
panning, zoom, toggles and export. New regions add work; entity saves and terrain edits do not
change the seed rule. Mask generation registers with the world's BackgroundWork owner. The layer
retains its single active handle for hide/close cancellation and local draining; hiding and then
showing resumes missing masks after the canceled pass finishes. World close cancels/drains the
registered task and prevents late publication or a following pass. Closing one layer leaves its
siblings running. The center's chunk status is
in the map's accessibility value; pointer hover shows the same checked rule in the readout.

Player listing uses DimensionPresentation's one dimension-listing fallback, shared with saved places and
search results. Map content and map-click validation consume the same drawn-player marker
collection, including hidden-player filtering. PlayerPresentation supplies the valid saved
locations to both the map and inspector; invalid coordinates are excluded consistently,
while readable locations in unavailable dimensions remain inspectable with navigation disabled.
Personal phrases and absent-owner names stay with PlayerPresentation, preserving their wording.
Player files use the same vanilla location rules regardless of unrelated extra fields; the app
checks coordinate availability and presentation. Unknown numeric dimensions remain unavailable.
Vanilla legacy dimensions and datapack dimensions still work; World Info retains its Modded line.
RegionFacts are adopted by the shared region reader. PlayerSnapshot reads Kit's shoulder pets
once per accepted player publication. WorldIndexStore derives their combined creature index once
per player/index snapshot, shared by all dimension searches, sidebars, maps and pet links. A carried
bird's saved owner stays distinct from its carrier; only the carrier's validated saved location
is used. A carried UUID replaces any stale region copy, and missing/unavailable locations never
fall back to the bird's mounting position. The player's On Shoulders section retains its details
even when it cannot be mapped. DimensionPresentation omits that player's own carried pets from
Linked Pets, so each appears once in the inspector. Owned pets carried by someone else retain
their links, and a pet that lands returns to Linked Pets on the shared index refresh.
These are derived app publications, with no new file reader or
disk cache; ordinary player and region refreshes replace them.

ItemIcon and ItemLabel share item symbol, material color and known-enchantment styling across
equipment, trades, inventory slots and Storage. ItemAppearance remains the owner of names,
symbols, colors and detail text. Inventory keeps its slot grid/count badges and Storage its
sortable table (Ryan, 2026-10-20, #298). A trade's icon represents the received item; its complete
wording still comes from TradeText.offer. Storage aggregates by kind, so it does not invent a
stack's custom name or enchantment. Native labels and slot accessibility retain the item details.
EquipmentSection omits empty equipment for both players and pets, matching the other optional
inspector sections. The pet-only “Equipment: None” row is removed; Kit's equipment applicability
stays unchanged. Inventory grids retain empty slots because those represent storage positions.

Creature.displayName owns custom-name, villager-job and kind fallback naming for located
markers, shoulder pets and ordinary/filtered creature search rows. Generic layer filters and
plain named-creature search share one hit constructor; filtered searches retain their one
matching helper. The creature caption supplies the kind, or the group when the name already is the kind.
CreatureDetailSections owns their shared applicable health, owner,
appearance, equipment and trade details. The inspector and On Shoulders disclosure supply only
their headings and location presentation; a carried pet never displays its old mounting position.
