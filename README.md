# Chunksee

A Mac app for viewing Minecraft: Java Edition worlds. It's built on [ChunkseeKit](https://github.com/fahlman/ChunkseeKit), the open-source engine that reads world saves.

It shows a top-down view of a world, the structures and places found in it, and where its players were last.

## Using Chunksee

1. Choose **File ▸ Open…** and select a world's folder inside your Minecraft `saves`
   folder.
2. Pick a dimension in the sidebar.
3. To move around the map, drag, scroll with two fingers on a trackpad, or use the arrow keys.
4. To zoom, pinch, hold **⌘** while scrolling, use a mouse scroll wheel, or press **⌘+**, **⌘−** and **⌘0**.
   Zoom In and Zoom Out work with or without **Shift**, like Preview.
5. Structures found in explored areas (villages, strongholds with their End portal rooms, ancient
   cities, fortresses and more) appear on the map; choose which kinds in **Structures** in the
   sidebar. Mineshafts and Nether fossils start hidden because there are so many.
6. Places from the world's point-of-interest data appear too: Nether portals and village bells by
   default, and beds, villager workstations, bee nests and more from **Places** in the sidebar. Beds and
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
   button in the toolbar. To show names, choose your Minecraft folder in **Settings**, so Chunksee
   can read the names Minecraft remembers. You can also turn on looking up other players' names
   from Mojang there; it's off until you do. Faded markers belong to players who haven't joined since the world was upgraded.

Chunksee only reads your world; it never changes it. Each world opens as a native Mac document in
its own window. **File ▸ Open Recent** and window restoration follow your macOS settings, including
your preference for reopening windows after quitting. You can select several world folders in
the Open panel; opening a world again brings its existing window forward. Clearing Open Recent
leaves your open worlds available.

Chunksee stays out of Finder’s **Open With** list because macOS identifies these world folders
as ordinary folders. **File** offers opening and closing commands; viewing a world has no save,
rename or move commands. When updating from the previous window system, reopen your worlds once
with **File ▸ Open…**; macOS will remember them from then on.

**View** includes zoom, World Info, Time Spent, sidebar and inspector commands. **Navigate** jumps
to the world spawn or another dimension and saves the current search. In player details,
**Locations** offers the last position, last death and respawn point. VoiceOver can also explore
the individual visible map locations and center the map on them.

Rendered map tiles are kept in Chunksee's cache folder, so reopening a world is nearly instant; any
part of the world that has changed since is drawn again.

## Building

Requires Xcode 27 and macOS 27. Open `Chunksee.xcodeproj` and run the **Chunksee** scheme, or:

```sh
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'platform=macOS' build
```
