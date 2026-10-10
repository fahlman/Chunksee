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
- **Initial dependency:** MCWorldKit, pinned to an approved release version. **Pending
  bootstrap:** MCWorldKit has no approved release process or tag yet (see
  fahlman/MCWorldKit#1 and fahlman/MCWorldKit#2).

## Build and test

**Pending bootstrap.** The exact `xcodebuild` build and test commands, the shared scheme, and
the launch smoke check will be recorded when the Xcode project skeleton is created. They aren't
guessed here.

**Automated GitHub checks:** none, because Ryan's projects run no hosted macOS CI. This was
recorded on 2026-10-09.

## Toolchain and platforms

On 2026-10-09 these were verified as the newest non-beta releases on Apple's and Swift's release
pages, then compared with what this Mac uses.

- **Compiler:** Xcode 27.0 (`27A266a`) and Apple Swift 6.4 (`swiftlang-6.4.0.34.1`).
- **Swift language mode:** 6.
- **SDK:** macOS 27.0 SDK.
- **Minimum macOS:** 27. The app is Mac only.
