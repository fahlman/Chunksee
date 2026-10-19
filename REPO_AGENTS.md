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
  minor" from `0.32.0`, resolved to `0.32.0` (`0c0c3a93617e86733bae3a4085e59353297de67b`).
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
| `WorldSession.swift` | Composes one dimension document’s map, navigation, routing, search and selection models; owns ruler and annotation actions until their separate extraction |
| `MapModel.swift` | Full and preview tile caches and the per-region render scheduler for one dimension; rendering for regions that leave the view is cancelled |
| `MapLayers.swift`, `HeatMap.swift` | Each world dimension tab's remembered layer/player/grid controls and Time Spent visibility; HeatMapLayer owns the live Time Spent flag, with persistence through LayerVisibility |
| `MapViewport.swift` | Conversions between view points and world blocks, plus pan and zoom; saved chunk/region coordinates use ChunkseeKit's position types |
| `Presentation.swift`, `GoToCoordinatesView.swift` | Coordinate labels using ChunkseeKit’s checked block conversion, block-center geometry, and native coordinate entry; exact entity positions stay unshifted |
| `MarkerGeometry.swift`, `MarkerStyle.swift`, `MarkerLabels.swift` | Fixed marker geometry shared by drawing/picking; body, glyph, border, dimming and label presentation shared by map/export and applicable sidebar symbols; deterministic label collision layout |
| `PointMarkers.swift` | Immutable Places/creature arrays and region buckets, built on index publication and shared by map drawing/export, hit testing and accessibility candidates |
| `MarkerGeometry.swift` | Fixed marker body/symbol dimensions and the pointer reach derived from each body's radius, including selection sizes |
| `MapNavigation.swift`, `MapToolbar.swift`, `MapDepth.swift` | Local navigation/history, native map controls and zoom presets; MapModel owns viewport/depth |
| `DimensionRouting.swift` | Native opening callback, observable opening error and dispatch of cross-dimension app actions |
| `SelectionModel.swift` | One live selected identity, sidebar/map actions, inspector and overlay presentation, and scoped player-record reads |
| `SavedPlaces.swift`, `SavedPlaceViews.swift` | Local per-world annotations and native naming/sidebar controls |
| `MapRuler.swift`, `MapContextMenu.swift` | Block-distance measurement, shared SwiftUI saved-place/map commands, NSHostingMenu presentation and the narrow pasteboard boundary; every Copy Coordinates entry shares one X/Y/Z action |
| `RegionTileRenderer.swift` | Rendering a region (512×512 blocks) into a top-down image, off the main actor |
| `BlockColors.swift` | Block ID → map color |
| `Structures.swift` | Structure groups (names, icons, colors, default visibility) and the background structure scan |
| `Places.swift` | Point-of-interest groups, the background scan, and portal link status (grouping and linking rules from ChunkseeKit's `PointOfInterest` and `NetherPortal`) |
| `WorldSearch.swift`, `RegionIndex.swift` | Retained per-region index contributions, deriving complete dimension aggregates and answering searches against the world index |
| `SearchModel.swift`, `SavedQueryResults.swift` | Independent per-dimension search controls/snapshots; the world index owns shared pending/completed saved-query work |
| `PlayerNames.swift` | The Minecraft folder chosen in Settings and its access; names from local caches and, while permission remains on, Mojang; source lifetimes and cancellation |
| `RegionReader.swift`, `ScanCache.swift` | Coalesced Kit region reads, one versioned facts envelope per region, cancellation and draining when a world closes |
| `BackgroundWork.swift`, `RefreshLoader.swift` | Scoped task registration, cancellation and draining, plus retained-value refresh coalescing |
| `PlayerRecords.swift` | Statistics and advancements, and inspector-scoped reads registered with the world |
| `WorldCommands.swift` | Map and navigation menus routed to the focused document; SwiftUI supplies sidebar and inspector commands |
| `ReadOnlyDocumentMenus.swift` | A small AppKit menu hook that removes editing actions while preserving native Open, Open Recent, Close and Close All; SwiftUI's save group includes Close and has no separate Rename/Move placements |
| `SettingsView.swift` | Settings: the Minecraft folder and online name lookup |
| `PlayerMarkers.swift` | Player names and personal/named phrases, outdated-location wording and coordinate validation shared by markers and inventory search, and which markers each dimension shows (data from ChunkseeKit's `PlayerInfo`) |
| `TileCache.swift` | Rendered tiles on disk in the app's Caches folder, keyed by region file size, modification date and renderer version |
| `ScrollWheelInput.swift` | A small AppKit view for arbitrary-view scroll deltas, which SwiftUI on macOS 27 does not expose; native hit testing scopes input to the map and its window |
| `ContentView.swift`, `MapView.swift` | SwiftUI views |
| `Creatures.swift`, `PetDetails.swift`, `VillagerText.swift` | Native creature inspector, shared saved villager job/level labels and pet appearance/collar labels, using shared health/equipment rows; applicability and data interpretation come from ChunkseeKit |
| `PlayerDetails.swift`, `PlayerStatus.swift`, `Equipment.swift`, `Health.swift`, `CountedText.swift`, `LinkedPets.swift` | Native player inspector, shared creature/player health and equipment rows, native fractional heart/block unit wording, saved effect duration presentation, and links to this world's pets by owner UUID; parsing/calculation belongs in ChunkseeKit |
| `SidebarItem.swift`, `SidebarDisclosure.swift` | Live sidebar-item types, each dimension view's expanded groups and revealing a map marker's ancestors |

`DocumentGroup` owns opening, recent documents, windows, tabs and restoration. A world folder
chosen in the Open panel or Open Recent is read as a world: the reader remembers it, and its window
opens the dimension folders with SwiftUI's `openDocument` and then closes itself. Navigate ▸
Dimension and cross-dimension jumps also use `openDocument`, which brings an already-open dimension
to the front; a jump runs once that dimension's view exists, and is dropped if it fails to open.
The opening action captures only `openDocument`, so a view never keeps its own document alive.
Native window and tab titles use `WorldSession.dimensionName(_:)`, the same localized,
collision-safe name as the menus. URL-based DocumentGroup in macOS 27 retains folder titles
with navigationTitle at the document root, split-view root or map detail (verified in Release).
The small DocumentWindowTitle view sets only NSDocument.displayName through its existing
window controller; SwiftUI still owns the document, URL, window and native tabs. A view-scoped
observation reapplies the model’s display name if native restoration resets it; moving or closing
the view ends that observation. The adapter never edits a file URL or document contents.
The subtitle names the world; document URLs and native Open Recent remain tied to their folders.
Each dimension's map position is remembered in `RememberedViews`.
`MapNavigation` applies local focus, coordinate jumps, Fit World and Back/Forward through the
document's existing MapModel, which remains the only viewport/depth owner. It owns history but
has no tasks or separate closed flag; MapModel's existing lifetime guards late navigation.
Native reread/move restoration copies history, viewport and depth into the new model, including
from an already closed source, without sharing that source's map or history. Cross-dimension
validation stays with the feature; DimensionRouting dispatches through the native opener. It refers
weakly to its source document for identity and closed state, without a second lifetime flag.
WorldResources keeps the latest waiting app action per destination, shared across source documents;
a failed earlier opening cannot discard a newer action. A native opening can outlive its source,
but errors are presented only while that source remains open. Native commands and
the toolbar call the navigation model directly for local actions.
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
Concurrent requests share cache decoding/scanning. File-open errors and cancellation do not write
cache entries, and a save during a scan prevents persisting that snapshot. Failed refreshes retain
previous index and heat contributions; successful empty reads and deleted files remove them.

`MapDepth` is the map-owned selected Y and Surface/cutaway mode. A native SwiftUI toolbar button
shows Surface or the current Y and opens a standard popover. Its segmented mode picker, labeled
slider, bordered number field and stepper share that owner; height controls are disabled on Surface.
Standard controls determine their sizing, with no fixed frames. RememberedViews stores depth per
dimension alongside the viewport, including moves.
Native View-menu commands open the same popover (Shift-Command-Y) and toggle Surface
(Option-Command-Y), so default macOS keyboard navigation can reach the feature. A focused scene
binding exposes the view-owned popover flag; MapDepth still owns the mode and height. The Cutaway
number field receives SwiftUI focus on opening or switching from Surface.
Slider dragging holds an unfinished height in the view and commits it only when released
(Ryan, 2026-10-19, #84/#248). The map, cache and remembered view keep their committed depth
during the drag. Exact-number entry and non-drag slider changes apply immediately; leaving the
popover discards an unfinished drag. Actual dimension-type bounds remain tracked in #248; the
displayed slider endpoints describe its travel, not verified world-generation limits.
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

Viewport-to-region and grid conversions check finite values and integer bounds before forming
ranges. Invalid persisted centers or zooms are ignored; an invalid live viewport cannot replace
a previously valid saved view. Grid iteration checks its step arithmetic as well as its endpoints.
Region/chunk index keys, tiles and scan results use Kit's RegionPosition and ChunkPosition
directly. Kit owns chunk-to-region/local coordinates and checked chunk/region origins; app scans,
hover reads, biome geometry and block-search pins use those properties. The previous x/z cache-key
encoding is unchanged. Unrepresentable chunk origins do not become map areas or search pins.
Region drawing/fitting also uses Kit's checked block origins. Continuous view geometry uses one
block-size constant, tested against Kit; the tile renderer's pixel size is independent of it.
The renderer owns its one-pixel-per-block canvas size; view rectangles remain CGFloat geometry.

Map context commands resolve the pointer once through the selection hit test. Copy, Save Place and
Measure use the same clicked marker anchor, or the containing pointer block when no marker is hit.
A saved-place pin shares the sidebar's SwiftUI Rename, Copy and Remove commands, with Measure
available on the map. NSHostingMenu presents the SwiftUI commands; no manual NSMenuItem targets or
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
empty space. Structure areas and the smaller player/search/saved-place lists keep their existing paths.
Player refreshes reopen the world's metadata through ChunkseeKit, including the embedded
single-player record when `level.dat` changes. An unreadable save retains the last good players;
a successful empty read clears them. Opening metadata for the world details stays read-on-open.

Drawing and picking share MarkerGeometry's fixed badge radii, with six points of clicking
tolerance beyond the body. Labels, structure outlines and portal status decorations do not
enlarge the body target. Selected pets/search pins use their larger radius; nearby hit candidates
cover that reach. Player drawing, picking and VoiceOver visibility/centering share an anchor:
exact for the live entity, block-centered for death and respawn. Labels and coordinate copying
retain the saved coordinates. Marker zoom growth stays separate. Canvas accessibility children use the same badge-body
frames and actual map positions in a SwiftUI ZStack; biome children use their area bounds.
Panning, zoom and block-centered anchors therefore move their native accessibility frames
along with the drawing, while the existing actions and visibility rules stay the same.
MarkerStyle defines the existing circle/rounded bodies, borders, glyph tints, opacity and caption
layout/thresholds. Body and caption drawing are shared across marker kinds; the per-frame glyph
cache keys the actual symbol and tint. Structure outlines/portal rooms, bounds culling and marker
ordering remain in MapView. Hidden captions do not format names or resolve text; semantic caption
fonts/layout are reused, and translucent caption fills are made only when shown. Existing outdated
map-player (0.55), sidebar-player (0.6) and claimed-place (0.65) dimming remain distinct. The player
and saved-place sidebar icons share their presentation owner, and the portal inspector uses its
group's symbol while retaining its singular title. No zoom-growth or visibility policy changes.
Eligible marker captions share one collision layout in Canvas and export: selected items first,
then players, then named pets, then other markers, with stable identity breaking ties. Lower-priority
labels that overlap an accepted label's two-point margin are omitted. Existing zoom thresholds,
marker bodies, hit targets and VoiceOver names remain available. Labels draw after the marker
bodies; the ruler keeps its existing topmost position. Caption text is measured once for layout
and drawing, and a spatial lookup limits comparisons to nearby accepted labels.

The creature inspector shows saved current/maximum health in hearts and applicable pet order,
appearance, collar and equipment from ChunkseeKit. Missing data stays absent. The selected
creature is resolved from the current shared index, so an open inspector follows saved changes.
Player equipment rows use Kit's `PlayerInfo.equippedItems`, including the selected main hand;
the app keeps only presentation slot filtering, ordering and labels. The player inventory grids
use Kit's `inventorySlots(in:)` for hotbar,
storage and ender chest; saved slot numbers, empty slots and duplicate handling stay in Kit.
The app owns only the grid and selected-hotbar styling. Players and creatures share
the native equipment section and health row. Health uses up to two
fractional digits in hearts, with a gauge when current and maximum are known and text for the
available values otherwise. Equipment keeps kind, custom name and count; slot order is shared,
empty stacks are omitted, and material tint applies to symbols while text uses semantic colors.
Rows and tooltips share the item/durability formatter. Format parsing and applicability stay in Kit.
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
not a live countdown. Effect names have their own vanilla exceptions, independent of enchantment
names; both share level numeral presentation. Saved effect durations use native localized clocks
and explicit localized units for accessibility, rounding partial seconds up in both readouts.
`GameDuration` owns saved tick conversion and localized elapsed units. World Age and Time Played
show completed seconds/minutes/hours rather than dropping every duration below an hour; effects
keep rounding partial seconds up. The world's day-cycle clock remains a separate concept.
Equipment includes the selected main hand, durability and named enchantments.
Empty or unavailable optional sections/values stay absent.

WorldResources owns one observable PlayerRoster for all dimension searches and inspectors. Each
accepted read publishes one immutable PlayerSnapshot there; searches observe that snapshot
instead of receiving pushed assignments in every tab. SearchSources still compares snapshot
identity, so query edits never traverse saved player NBT. Shared saved queries continue to reuse
only matching publications, and closed searches do not restart when the roster changes.

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

Layer controls are remembered separately for each world's dimension tab (Ryan, 2026-10-17,
fahlman/Chunksee#170): structures, places, creatures, biomes, hidden players, grid and Time Spent.
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
the Overworld when `WorldDetails` has a seed read by ChunkseeKit. `SlimeChunkLayer` builds a small
32×32 mask per saved region using `World.isSlimeChunk`, off the main actor, reusing masks across
panning, zoom, toggles and export. New regions add work; entity saves and terrain edits do not
change the seed rule. Mask generation registers with the world's BackgroundWork owner. The layer
retains its single active handle for hide/close cancellation and local draining; hiding and then
showing resumes missing masks after the canceled pass finishes. World close cancels/drains the
registered task and prevents late publication or a following pass. Closing one layer leaves its
siblings running. The center's chunk status is
in the map's accessibility value; pointer hover shows the same checked rule in the readout.

Player listing uses the session's one dimension-listing fallback, shared with saved places and
search results. Map content and map-click validation consume the same drawn-player marker
collection, including hidden-player filtering. PlayerPresentation supplies the valid saved
locations to both the map and inspector; invalid coordinates are excluded consistently,
while readable locations in unavailable dimensions remain inspectable with navigation disabled.
Personal phrases and absent-owner names stay with PlayerPresentation, preserving their wording.
Player files use the same vanilla location rules regardless of unrelated extra fields; the app
checks coordinate availability and presentation. Unknown numeric dimensions remain unavailable.
Vanilla legacy dimensions and datapack dimensions still work; World Info retains its Modded line.
RegionFacts are adopted by the shared region reader; shoulder-pet presentation remains
separate from publishing its library API.
