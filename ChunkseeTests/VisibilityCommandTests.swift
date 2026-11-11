import ChunkseeIndex
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized) struct VisibilityCommandTests {
    private func perform(_ binding: Binding<Bool>, title: String) throws {
        let menu = NSHostingMenu(rootView: VisibilityCommand(isShown: binding))
        menu.update()
        let item = try #require(menu.item(at: 0))
        #expect(menu.items.count == 1 && item.title == title && item.isEnabled)
        menu.performActionForItem(at: 0)
    }

    private func openWorld() async throws -> (URL, WorldResources) {
        let root = try TestWorld.make(chunks: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        return (root, resources)
    }

    @Test func nativeVisibilityCommandsChangeOnlyTheirOwnDimensionGroupAndPersist() async throws {
        let (root, resources) = try await openWorld()
        defer { resources.close(); try? FileManager.default.removeItem(at: root) }
        let first = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let other = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        func exercise<Group: Hashable>(_ group: Group, _ keyPath: WritableKeyPath<LayerVisibility, Set<Group>>) throws {
            first.visibility[keyPath: keyPath] = [group]
            other.visibility[keyPath: keyPath] = [group]
            let binding = Binding { first.visibility[keyPath: keyPath].contains(group) } set: { shown in
                if shown { first.visibility[keyPath: keyPath].insert(group) } else { first.visibility[keyPath: keyPath].remove(group) }
            }
            try perform(binding, title: "Hide on Map")
            #expect(first.visibility[keyPath: keyPath].isEmpty && other.visibility[keyPath: keyPath] == [group])
            let restored = resources.settings.mapPresentation(for: "minecraft:overworld").overlays
            #expect(restored[keyPath: keyPath].isEmpty)
            try perform(binding, title: "Show on Map")
            #expect(first.visibility[keyPath: keyPath] == [group] && other.visibility[keyPath: keyPath] == [group])
        }
        try exercise(.mineshaft, \.structures)
        try exercise(.spawner, \.places)
        try exercise(.pet, \.creatures)
        try exercise(BiomeGroup(id: "minecraft:plains"), \.biomes)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func playerCommandKeepsOtherPlayersAndDimensionSettings() async throws {
        let (root, resources) = try await openWorld()
        defer { resources.close(); try? FileManager.default.removeItem(at: root) }
        let first = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let other = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let player = UUID(), alreadyHidden = UUID()
        first.visibility.hiddenPlayers = [alreadyHidden]
        other.visibility.hiddenPlayers = []
        let binding = Binding { !first.visibility.hiddenPlayers.contains(player) } set: { shown in
            if shown { first.visibility.hiddenPlayers.remove(player) } else { first.visibility.hiddenPlayers.insert(player) }
        }
        try perform(binding, title: "Hide on Map")
        #expect(first.visibility.hiddenPlayers == [alreadyHidden, player] && other.visibility.hiddenPlayers.isEmpty)
        #expect(resources.settings.mapPresentation(for: "minecraft:overworld").overlays.hiddenPlayers == [alreadyHidden, player])
        try perform(binding, title: "Show on Map")
        #expect(first.visibility.hiddenPlayers == [alreadyHidden] && other.visibility.hiddenPlayers.isEmpty)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func savedQueryCommandUsesTheLiveBindingAndDoesNotRecreateARemovedQuery() throws {
        let defaults = TestDefaults.make()

        let searches = SavedSearches(defaults: defaults)
        searches.add("pet:"); searches.add("structure:")
        let saved = try #require(searches.all.first)
        let binding = Binding { searches.all.first { $0.id == saved.id }?.isShown ?? false }
            set: { searches.setShown(saved.id, $0) }
        try perform(binding, title: "Hide on Map")
        #expect(searches.all.map(\.isShown) == [false, true])
        #expect(SavedSearches(defaults: defaults).all.map(\.isShown) == [false, true])
        try perform(binding, title: "Show on Map")
        #expect(searches.all.map(\.isShown) == [true, true])
        searches.setShown(saved.id, false)
        try perform(binding, title: "Show on Map")
        #expect(searches.all.map(\.isShown) == [true, true])
        searches.remove(saved.id)
        try perform(binding, title: "Show on Map")
        #expect(searches.all.map(\.query) == ["structure:"] && searches.all.first?.isShown == true)
    }
}
