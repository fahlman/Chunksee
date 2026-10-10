# MCWorld

A Mac app for viewing Minecraft: Java Edition worlds. It's built on [MCWorldKit](https://github.com/fahlman/MCWorldKit), the open-source engine that reads world saves.

It shows a top-down view of a world, the structures and places found in it, and where its players were last.

## Using MCWorld

1. Choose **File ▸ Open World…** and select a world's folder inside your Minecraft `saves`
   folder.
2. Pick a dimension in the sidebar.
3. To move around the map, drag, scroll with two fingers on a trackpad, or use the arrow keys.
4. To zoom, pinch, hold **⌘** while scrolling, use a mouse scroll wheel, or press **⌘=**, **⌘−** and **⌘0**.
5. Structures found in explored areas (villages, strongholds with their End portal rooms, ancient
   cities, fortresses and more) appear on the map; choose which kinds in the **Structures** menu in
   the toolbar. Mineshafts and Nether fossils start hidden because there are so many.
6. Places from the world's point-of-interest data appear too: Nether portals and village bells by
   default, and beds, villager workstations, bee nests and more from the **Places** menu. Beds and
   workstations a villager has claimed are dimmed.
7. Click a Nether portal to see where it leads: the matching portal in the other dimension (with a
   button to jump there), a warning if the link is one-way, or a warning that going through would
   make the game build a new portal. Portals that don't link both ways carry a small badge.
8. Find items with the search field in the toolbar (**⌘F**): type an item ("diamond", "golden apple")
   or a custom name to list every chest, barrel, shulker box, minecart and player inventory holding it,
   most items first. Choose a result to jump there; results in the current dimension show as yellow pins.
   Start with `structure:`, `place:`, `creature:`, `pet:`, `villager:` or `biome:` to search one kind
   ("biome:pale garden"). Click ⊕ beside Search Results to keep a search in the sidebar's Saved Searches,
   where its eye button keeps its pins on the map.
9. Players appear on the map at their last saved position, with their last death (✕) and respawn
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
