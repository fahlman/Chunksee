# MCWorld — Repository Instructions

Read with the shared `AGENTS.md`.

## Project

MCWorld is a Mac app for viewing Minecraft: Java Edition worlds. Ryan approved it on 2026-10-09.

- **First scope:** open a world and show a top-down view of it.
- **Later:** overlays for strongholds, villages and other structures. These aren't approved for
  work yet.
- **Dependency direction:** **MCWorld app → MCWorldKit**. MCWorldKit is the open-source engine
  that reads world files (fahlman/MCWorldKit). This app owns presentation only. World-format
  rules belong in MCWorldKit and are never re-implemented here.

## Approved decisions (Ryan, 2026-10-09)

- **Kind:** Mac app, developed as an Xcode project with a tracked `.xcodeproj`, SwiftUI
  interface.
- **Names:**
  - Product, repository, project and app target: `MCWorld`.
  - Unit test target: `MCWorldTests`.
  - Bundle identifier: `com.fahlsing.MCWorld`.
- **Distribution:** local builds only. No release or distribution process is approved.
- **Signing owner:** Automatic signing with team `PUT2KYMV2W`, the same team as Euchre.
- **Sandbox:** App Sandbox and hardened runtime are on.
- **Entitlements:**
  - read-only access to files the user selects
  - app-scoped security-scoped bookmarks
  - outgoing network connections (`network.client`), used only to look up player names from Mojang
    when the user turns that on. Ryan approved this on 2026-10-10 (fahlman/MCWorld#11), off by
    default.
- **Data locations:**
  - The app reads only the world or saves folder the user picks with an Open panel.
  - Worlds are native read-only folder documents. macOS owns opening, Open Recent, and window
    restoration; each document retains access while its session reads the world.
  - It never writes to a world folder.
  - For player names, it reads `usercache.json` files under a Minecraft folder the user chooses in
    Settings (kept as a read-only bookmark). With online lookup on, it sends the UUIDs of players it
    can't name locally to `sessionserver.mojang.com` and keeps the returned names in its
    preferences.
  - Rendered tiles are kept in the app's Caches folder (about 1 GB at most).
- **Dependency:** MCWorldKit (`https://github.com/fahlman/MCWorldKit.git`), pinned "up to next
  minor" from `0.18.0`, resolved to `0.18.1` (`376966aec6e30325480fb4664f65b6cddda6f745`).
  - MCWorldKit releases are annotated semver tags, and each tag needs Ryan's approval (see
    MCWorldKit's `REPO_AGENTS.md`).
  - `Package.resolved` is tracked, so every build resolves the same MCWorldKit commit.
  - Release order: tag MCWorldKit first, then bump the pin here.

## Modules

All of the app's code is presentation; world-format rules live in MCWorldKit.

| File | Owns |
|---|---|
| `MCWorldApp.swift`, `WorldDocument.swift` | A URL-based read-only `DocumentGroup` for ordinary world folders; native opening, recents and restoration, opening metadata, document lifetime and moves |
| `AppModel.swift` | App-wide player names and saved searches |
| `WorldSession.swift` | One open world: its dimensions, map and overlays, and cancellation and draining of world reads before relinquishing document access |
| `MapModel.swift` | Full and preview tile caches and the per-region render scheduler for one dimension; rendering for regions that leave the view is cancelled |
| `MapViewport.swift` | Conversions between view points and world blocks, plus pan and zoom |
| `RegionTileRenderer.swift` | Rendering a region (512×512 blocks) into a top-down image, off the main actor |
| `BlockColors.swift` | Block ID → map color |
| `Structures.swift` | Structure groups (names, icons, colors, default visibility) and the background structure scan |
| `Places.swift` | Point-of-interest groups, the background scan, and portal link status (grouping and linking rules from MCWorldKit's `PointOfInterest` and `NetherPortal`) |
| `WorldSearch.swift` | The world index (each dimension's containers, signs, structures, places, creatures and biomes) and answering searches against it |
| `SearchModel.swift` | Background indexing and queries, current immutable result snapshots, and shared saved searches |
| `PlayerNames.swift` | Names from local caches and, while permission remains on, Mojang; source lifetimes and cancellation |
| `RegionReader.swift` | Shared per-region passes, cancellation and draining when a world closes |
| `PlayerRecords.swift` | Statistics and advancements, and the current inspector request |
| `WorldCommands.swift` | Map and navigation menus routed to the focused document; SwiftUI supplies sidebar and inspector commands |
| `SettingsView.swift` | Settings: the Minecraft folder and online name lookup |
| `PlayerMarkers.swift` | Player names, outdated and Bukkit rules, and which markers each dimension shows (data from MCWorldKit's `PlayerInfo`) |
| `TileCache.swift` | Rendered tiles on disk in the app's Caches folder, keyed by region file size, modification date and renderer version |
| `ScrollWheelInput.swift` | A small AppKit view for arbitrary-view scroll deltas, which SwiftUI on macOS 27 does not expose; native hit testing scopes input to the map and its window |
| `ContentView.swift`, `MapView.swift` | SwiftUI views |

`SearchModel.results(for:)` reads published results for the current or a saved query. It never
starts a synchronous scan. Query publication follows the index, players, names and saved-query
snapshot; callers that need completion await `waitForSearch()`.

## Build and test

Run from the repository root:

```sh
xcodebuild -project MCWorld.xcodeproj -scheme MCWorld -destination 'platform=macOS' build
xcodebuild -project MCWorld.xcodeproj -scheme MCWorld -destination 'platform=macOS' test
```

- **Scheme:** `MCWorld` is shared and tracked. It builds the app and runs `MCWorldTests`
  (Swift Testing).
- **Required checks:** `build` and `test` must both pass on the commit you publish, resolving
  MCWorldKit from its pinned tag. A local package override doesn't prove a change.
- **Launch smoke check:** build, then `open` the app from DerivedData. Confirm it keeps running
  and shows the native Open panel, then cancel it and quit. Check opening several folders, opening
  one again, clearing Open Recent while documents stay open, and quitting/relaunching with the
  system's window restoration preference. To check document file access, use a **Release** build.
  Xcode adds test-runner entitlements to Debug builds,
  including read-only access to `/`, so a Debug build can't show sandbox problems.
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
