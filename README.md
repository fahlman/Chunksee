# Chunksee

A Mac app for viewing Minecraft: Java Edition worlds. It's built on [ChunkseeKit](https://github.com/fahlman/ChunkseeKit), the open-source engine that reads world saves.

It shows a top-down view of a world, the structures and places found in it, and where its players were last.

## Using Chunksee

1. Choose a world from **File ▸ Open World**, which lists the worlds in the Minecraft folder you
   choose in Settings, or choose **File ▸ Open…** and select a world's folder inside a `saves`
   folder. Chunksee reads worlds saved by Minecraft 1.18 or later. For an older world it says
   so in place of the map; open it in Minecraft and choose **Edit ▸ Optimize World** to update it.
2. Each dimension opens as its own document: the Overworld, the Nether and the End. Each keeps its
   own map position, zoom, search, navigation history and measurement. They open as windows or
   tabs, following your tab preference in System Settings, and **Window ▸ Merge All Windows**
   gathers them into tabs. **Navigate ▸ Dimension** brings another dimension to the front or
   reopens one you closed, and macOS restores open dimensions when you reopen the app.
3. To move around the map, drag, scroll with two fingers on a trackpad, or use the arrow keys.
4. To zoom, pinch, hold **⌘** while scrolling, use a mouse scroll wheel, or press **⌘+**, **⌘−** and **⌘0**.
   Zoom In and Zoom Out work with or without **Shift**, like Preview. The current zoom percentage
   appears beside the toolbar's zoom controls; click it to choose a zoom level or **Fit World**,
   which fits all saved terrain in the current dimension into the window.
5. Structures found in explored areas (villages, strongholds with their End portal rooms, ancient
   cities, fortresses and more) appear on the map; choose which kinds in **Structures** in the
   sidebar. Mineshafts and Nether fossils start hidden because there are so many.
6. Places from the world's point-of-interest data appear too: Nether portals and village bells by
   default, and beds, villager workstations, bee nests and more from **Places** in the sidebar. Beds and
   workstations a villager has claimed are dimmed. **Monster Spawners** lists every spawner by the mob it
   spawns ("Zombie Spawner", "Empty Spawner"): one may be in a monster room, a mineshaft or a fortress, or
   placed by a player, so where it is tells you which.
7. Click a Nether portal to see in the inspector where it leads: the matching portal in the other dimension (with a
   button to jump there), a warning if the link is one-way, or a warning that going through would
   make the game build a new portal. Portals that don't link both ways carry a small badge.
8. Find items with the search field in the toolbar (**⌘F**): type an item ("diamond", "golden apple")
   or a custom name to list every chest, barrel, shulker box, minecart and player inventory holding it,
   most items first. Each dimension lists the results in it; choose one to jump there. They show as yellow pins.
   Start with `structure:`, `place:`, `creature:`, `pet:`, `villager:`, `trade:`, `biome:` or `block:` (diamonds, ancient debris, spawners…; the 1,000 richest chunks) to search one kind
   ("biome:pale garden"). Click ⊕ beside Search Results to keep a search in the sidebar's Saved Searches,
   where its eye button keeps its pins on the map.
9. Players appear on the map at their last saved position, with their last death (✕) and respawn
   point (bed). Each dimension's sidebar lists the players last seen there; choose one to jump to them, or hide markers with the people
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
to coordinates, the world spawn or another dimension and saves the current search. Choose
**Navigate ▸ Go to Coordinates…** (**⌘⇧G**) and enter X and Z to center the current dimension's
map there without changing zoom, or **Navigate ▸ Go to Spawn** (**⇧⌘H**) to return to the world spawn. In player details,
**Locations** offers the last position, last death and respawn point. VoiceOver can also explore
the individual visible map locations and center the map on them.

**Back** and **Forward** in the toolbar or **Navigate** menu (**⌘[** and **⌘]**) restore the
previous location and zoom within the current dimension. A jump to another dimension happens in
that dimension's own window. Panning and zooming adjust the current view; a new jump after going back
starts a new path.

Choose **Navigate ▸ Save Place…** (**⌘D**) to name the location at the map's center, or right-click
a map point and choose **Save Place…**. Your **Saved Places** appear in their dimension's sidebar and on the
map; click a sidebar place to visit it, and use its context menu to rename or remove it. They are
kept per world in Chunksee's preferences and remain available when the world is reopened or moved.

Right-click or Control-click any map point and choose **Copy Coordinates** to copy its X and Z.
With the map selected, **Edit ▸ Copy** (**⌘C**) copies an image of the map as shown; the toolbar's
Share button sends one.
To measure a distance, turn on the toolbar's ruler or **View ▸ Measure Distance** (**⇧⌘M**), then
click two map points. The line and distance remain attached to those blocks as you pan and zoom.
A third click starts a new measurement; **Clear** or **Escape** clears it, and another **Escape**
exits the tool. Each dimension keeps its own measurement.

With **Grid** enabled, individual block lines appear at **8× zoom (800%)** and above.
Chunk and region boundaries remain emphasized, with their coordinates along the map edges.

Rendered map tiles are kept in Chunksee's cache folder, so reopening a world is nearly instant; any
part of the world that has changed since is drawn again.

## Building

Requires Xcode 27 and macOS 27. Open `Chunksee.xcodeproj` and run the **Chunksee** scheme, or:

```sh
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'platform=macOS' -configuration Release build
```
