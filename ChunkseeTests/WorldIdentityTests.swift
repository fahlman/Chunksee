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
        #expect(found.url.path == moved.path && found.legacyPath == original.path)
        #expect(try reopened.remember(moved).id == first.id)
        try FileManager.default.copyItem(at: moved, to: copy)
        let copied = try reopened.remember(copy)
        #expect(copied.id != first.id)
        #expect(copied.url.path == copy.path)
        #expect(reopened.world(containing: moved.appendingPathComponent("dimensions"))?.id == first.id)
        #expect((defaults.array(forKey: "worldFolderBookmarks") ?? []).count == 2)
    }

    @Test func anOldBookmarkImportsSettingsAfterTheWorldWasRenamedWhileClosed() throws {
        let original = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        let moved = original.appendingPathExtension("renamed")
        defer { for url in [original, moved] { try? FileManager.default.removeItem(at: url) } }
        let bookmark = try original.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        defaults.set([bookmark], forKey: "worldFolderBookmarks")
        let place = SavedPlace(name: "Home", dimension: "minecraft:overworld", x: -12, z: 34)
        let payload = try JSONEncoder().encode([place])
        defaults.set(["version": 1, "views": ["minecraft:overworld": [123.0, -456.0, 8.0]],
                      "depths": ["minecraft:overworld": ["y": 48, "surface": 0]],
                      "layers": ["minecraft:overworld": ["showsGrid": true]], "places": payload],
                     forKey: "worldSettings." + original.path)
        try FileManager.default.moveItem(at: original, to: moved)
        let folders = WorldFolders(defaults: defaults)
        let folder = try #require(folders.world(containing: moved.appendingPathComponent("dimensions/minecraft/overworld")))
        #expect(folder.legacyPath == original.path)
        let settings = WorldSettings(folder: folder, defaults: defaults)
        #expect(settings.viewport(for: "minecraft:overworld") == MapViewport(center: CGPoint(x: 123, y: -456), scale: 8))
        #expect(settings.mapPresentation(for: "minecraft:overworld").depth == MapDepth(y: 48, isSurface: false))
        #expect(settings.mapPresentation(for: "minecraft:overworld").overlays.showsGrid)
        #expect(settings.savedPlaces == [place])
        #expect(defaults.object(forKey: "worldSettings." + original.path) == nil)
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
        defaults.set([["id": unavailableID.uuidString, "bookmark": unreadable, "legacyPath": "/Unavailable World"]],
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

    @Test func legacyMoveImportCombinesDimensionsAndPreservesDestinationAnnotationNames() throws {
        let defaults = TestDefaults.make(), id = UUID(), old = "/Old World", new = "/Moved World"
        let place = SavedPlace(name: "Old Name", dimension: "minecraft:overworld", x: 1, z: 2)
        var duplicate = place; duplicate.name = "Existing destination"
        let other = SavedPlace(name: "End Base", dimension: "minecraft:the_end", x: 100, z: 200)
        defaults.set(["views": ["minecraft:overworld": [1.0, 2.0, 4.0]],
                      "layers": ["minecraft:the_nether": ["showsGrid": true]], "places": try JSONEncoder().encode([place])],
                     forKey: "worldSettings." + old)
        defaults.set(["views": ["minecraft:the_end": [3.0, 4.0, 8.0]], "places": try JSONEncoder().encode([duplicate, other])],
                     forKey: "worldSettings." + new)
        let settings = WorldSettings(id: id, defaults: defaults, legacyPaths: [new, old])
        #expect(settings.viewport(for: "minecraft:overworld")?.scale == 4 && settings.viewport(for: "minecraft:the_end")?.scale == 8)
        #expect(settings.mapPresentation(for: "minecraft:the_nether").overlays.showsGrid)
        #expect(settings.savedPlaces == [duplicate, other])
        #expect(defaults.object(forKey: "worldSettings." + old) == nil && defaults.object(forKey: "worldSettings." + new) == nil)
    }
}
