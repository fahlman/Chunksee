# MCWorld

A Mac app for viewing Minecraft: Java Edition worlds. It's built on [MCWorldKit](https://github.com/fahlman/MCWorldKit), the open-source engine that reads world saves.

It shows a top-down view of a world and where its players were last. Later versions will add overlays for strongholds, villages and other structures.

## Using MCWorld

1. Choose **File ▸ Open World…** and select a world's folder inside your Minecraft `saves`
   folder.
2. Pick a dimension in the sidebar.
3. To move around the map, drag, scroll with two fingers on a trackpad, or use the arrow keys.
4. To zoom, pinch, hold **⌘** while scrolling, use a mouse scroll wheel, or press **⌘=**, **⌘−** and **⌘0**.
5. Players appear on the map at their last saved position, with their last death (✕) and respawn
   point (bed). Choose a player in the sidebar to jump to them, or hide markers with the people
   button in the toolbar. To show names, choose your Minecraft folder in **Settings**, so MCWorld
   can read the names Minecraft remembers. You can also turn on looking up other players' names
   from Mojang there; it's off until you do. Faded markers belong to players who haven't joined since the world was upgraded.

MCWorld only reads your world; it never changes it. It reopens the last world when it launches.
Rendered map tiles are kept in MCWorld's cache folder, so reopening a world is nearly instant; any
part of the world that has changed since is drawn again.

## Building

Requires Xcode 27 and macOS 27. Open `MCWorld.xcodeproj` and run the **MCWorld** scheme, or:

```sh
xcodebuild -project MCWorld.xcodeproj -scheme MCWorld -destination 'platform=macOS' build
```
