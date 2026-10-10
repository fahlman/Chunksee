# MCWorld

A Mac app for viewing Minecraft: Java Edition worlds. It's built on [MCWorldKit](https://github.com/fahlman/MCWorldKit), the open-source engine that reads world saves.

The first version shows a top-down view of a world. Later versions will add overlays for strongholds, villages and other structures.

## Using MCWorld

1. Choose **File ▸ Open World…** and select a world's folder inside your Minecraft `saves`
   folder.
2. Pick a dimension in the sidebar.
3. To move around the map, drag or use the arrow keys.
4. To zoom, pinch or use **⌘+**, **⌘−** and **⌘0**.

MCWorld only reads your world; it never changes it. It reopens the last world when it launches.

## Building

Requires Xcode 27 and macOS 27. Open `MCWorld.xcodeproj` and run the **MCWorld** scheme, or:

```sh
xcodebuild -project MCWorld.xcodeproj -scheme MCWorld -destination 'platform=macOS' build
```
