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
- **Data locations:**
  - The app reads only the world or saves folder the user picks with an Open panel.
  - It remembers that folder as a read-only security-scoped bookmark in its own preferences.
  - It never writes to a world folder.
- **Dependency:** MCWorldKit (`https://github.com/fahlman/MCWorldKit.git`), pinned "up to next
  minor" from `0.1.0`.
  - MCWorldKit releases are annotated semver tags, and each tag needs Ryan's approval (see
    MCWorldKit's `REPO_AGENTS.md`).
  - `Package.resolved` is tracked, so every build resolves the same MCWorldKit commit.
  - Release order: tag MCWorldKit first, then bump the pin here.

## Modules

All of the app's code is presentation; world-format rules live in MCWorldKit.

| File | Owns |
|---|---|
| `MCWorldApp.swift` | The single `Window` scene and the File ▸ Open World… command |
| `AppModel.swift` | The open world, and remembering it between launches with a read-only bookmark |
| `WorldSession.swift` | One open world: security-scoped access, its dimensions, and the selected dimension's map |
| `MapModel.swift` | Tile cache and background rendering for one dimension, cancelled when tiles leave the view |
| `MapViewport.swift` | Conversions between view points and world blocks, plus pan and zoom |
| `RegionTileRenderer.swift` | Rendering a region (512×512 blocks) into a top-down image, off the main actor |
| `BlockColors.swift` | Block ID → map color |
| `ContentView.swift`, `MapView.swift` | SwiftUI views |

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
  and shows the "No World Open" window, then quit it. To check the sandboxed Open panel and
  bookmark path, use a **Release** build. Xcode adds test-runner entitlements to Debug builds,
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
