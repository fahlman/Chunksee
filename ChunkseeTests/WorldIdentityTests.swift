import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct WorldIdentityTests {
    @Test func bookmarksFollowMovesAndAliasesButCopiesHaveTheirOwnIdentity() throws {
        let original = try TestWorld.make(chunks: [])
        let moved = original.appendingPathExtension("moved"), copy = original.appendingPathExtension("copy")
        let alias = original.appendingPathExtension("alias")
        defer { for url in [original, moved, copy, alias] { try? FileManager.default.removeItem(at: url) } }
        let defaults = TestDefaults.make(), folders = WorldFolders(defaults: defaults)
        let first = try folders.remember(original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        #expect(try folders.remember(alias).id == first.id)
        try FileManager.default.moveItem(at: original, to: moved)
        let reopened = WorldFolders(defaults: defaults)
        let found = try #require(reopened.world(containing: moved.appendingPathComponent("dimensions/minecraft/overworld")))
        #expect(found.id == first.id)
        #expect(found.url.path == moved.path)
        #expect(try reopened.remember(moved).id == first.id)
        try FileManager.default.copyItem(at: moved, to: copy)
        let copied = try reopened.remember(copy)
        #expect(copied.id != first.id)
        #expect(copied.url.path == copy.path)
        #expect(reopened.world(containing: moved.appendingPathComponent("dimensions"))?.id == first.id)
        #expect((defaults.array(forKey: "worldFolderBookmarks") ?? []).count == 2)
    }

    @Test func currentBookmarkKeepsSettingsAfterTheWorldWasRenamedWhileClosed() throws {
        let original = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        let moved = original.appendingPathExtension("renamed")
        defer { for url in [original, moved] { try? FileManager.default.removeItem(at: url) } }
        let originalFolder = try WorldFolders(defaults: defaults).remember(original)
        let saved = WorldSettings(folder: originalFolder, defaults: defaults)
        let place = SavedPlace(name: "Home", dimension: "minecraft:overworld", x: -12, z: 34)
        var choices = MapPresentation()
        choices.depth = MapDepth(y: 48, isSurface: false)
        choices.overlays.showsGrid = true
        saved.save(MapViewport(center: CGPoint(x: 123, y: -456), scale: 8), presentation: choices,
                   for: "minecraft:overworld", selected: "minecraft:overworld")
        saved.savePlaces([place])
        try FileManager.default.moveItem(at: original, to: moved)
        let folders = WorldFolders(defaults: defaults)
        let folder = try #require(folders.world(containing: moved.appendingPathComponent("dimensions/minecraft/overworld")))
        #expect(folder.id == originalFolder.id)
        let settings = WorldSettings(folder: folder, defaults: defaults)
        #expect(settings.viewport(for: "minecraft:overworld") == MapViewport(center: CGPoint(x: 123, y: -456), scale: 8))
        #expect(settings.mapPresentation(for: "minecraft:overworld").depth == MapDepth(y: 48, isSurface: false))
        #expect(settings.mapPresentation(for: "minecraft:overworld").overlays.showsGrid)
        #expect(settings.savedPlaces == [place])
        let reread = try #require(WorldFolders(defaults: defaults).world(containing: moved.appendingPathComponent("dimensions")))
        #expect(reread.id == folder.id && WorldSettings(folder: reread, defaults: defaults).savedPlaces == [place])
    }

    @Test func movedDimensionReadersAndClosingSiblingTabsKeepTheSameSettings() async throws {
        let original = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        let moved = original.appendingPathExtension("moved")
        defer { for url in [original, moved] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: original.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let old = try await WorldResources(snapshot: try await WorldSnapshot.read(original), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        var live = [old]
        defer { live.forEach { $0.close() } }
        let overworld = WorldSession(resources: old, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: old, dimensionID: "minecraft:the_nether")
        let view = MapViewport(center: CGPoint(x: 123, y: -456), scale: 8)
        overworld.map?.viewport = view
        overworld.map?.setDepth(MapDepth(y: 48, isSurface: false))
        overworld.visibility.showsGrid = true
        let place = try #require(old.savedPlaces.add(name: "Home", dimension: "minecraft:overworld", at: CGPoint(x: 1, y: 2)))
        overworld.close(); await overworld.waitUntilClosed()
        try FileManager.default.moveItem(at: original, to: moved)
        let model = AppModel(defaults: defaults, cacheRoot: nil)
        let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
        guard case .dimension(let first) = try await reader.readFolder(moved.appendingPathComponent("dimensions/minecraft/overworld")) else {
            Issue.record("Moved dimension was not read as a document"); return
        }
        let restored = try await first.makeSession(in: model)
        live.append(restored.resources)
        #expect(restored.resources !== old && restored.resources.settings.worldID == old.settings.worldID)
        #expect(restored.map?.viewport == view && restored.map?.depth == MapDepth(y: 48, isSurface: false))
        #expect(restored.visibility.showsGrid && restored.savedPlaces.all == [place])
        let netherView = MapViewport(center: CGPoint(x: -15, y: 30), scale: 2)
        nether.map?.viewport = netherView
        nether.visibility.creatures = []
        nether.close(); await nether.waitUntilClosed()
        restored.saveView()
        guard case .dimension(let second) = try await reader.readFolder(moved.appendingPathComponent("dimensions/minecraft/the_nether")) else {
            Issue.record("Moved sibling was not read as a document"); return
        }
        let restoredNether = try await second.makeSession(in: model)
        #expect(restoredNether.resources === restored.resources)
        #expect(restoredNether.map?.viewport == netherView && restoredNether.visibility.creatures.isEmpty)
        #expect(restored.savedPlaces.all == [place])
        for resources in live { resources.close(); await resources.waitUntilClosed() }
    }

    @Test func unresolvedBookmarksKeepTheirIdentityWhenAnotherWorldIsOpened() throws {
        let defaults = TestDefaults.make(), unavailableID = UUID(), unreadable = Data([0, 1, 2])
        defaults.set([["id": unavailableID.uuidString, "bookmark": unreadable]],
                     forKey: "worldFolderBookmarks")
        let folders = WorldFolders(defaults: defaults)
        #expect(folders.world(containing: URL(fileURLWithPath: "/Unavailable World/region")) == nil)
        let other = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: other) }
        let id = try folders.remember(other).id
        let stored = try #require(defaults.array(forKey: "worldFolderBookmarks") as? [[String: Any]])
        #expect(stored.count == 2 && stored.first?["id"] as? String == unavailableID.uuidString)
        #expect(stored.first?["bookmark"] as? Data == unreadable)
        #expect(try WorldFolders(defaults: defaults).remember(other).id == id)
    }

    @Test func bareBookmarkArraysAreNotImportedAndTheFolderCanBeOpenedAgain() throws {
        let root = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        defaults.set([bookmark], forKey: "worldFolderBookmarks")
        let folders = WorldFolders(defaults: defaults)
        #expect(folders.world(containing: root.appendingPathComponent("dimensions")) == nil)
        let opened = try folders.remember(root)
        #expect(WorldFolders(defaults: defaults).world(containing: root.appendingPathComponent("dimensions"))?.id == opened.id)
        let records = try #require(defaults.array(forKey: "worldFolderBookmarks") as? [[String: Any]])
        #expect(records.count == 1 && records[0]["id"] as? String == opened.id.uuidString)
    }
}
