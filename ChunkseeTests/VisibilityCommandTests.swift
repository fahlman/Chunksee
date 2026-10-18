import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Chunksee

@Suite(.serialized) struct VisibilityCommandTests {
    private func perform(_ binding: Binding<Bool>, title: String) throws {
        let menu = NSHostingMenu(rootView: VisibilityCommand(isShown: binding))
        menu.update()
        let item = try #require(menu.item(at: 0))
        #expect(menu.items.count == 1 && item.title == title && item.isEnabled)
        menu.performActionForItem(at: 0)
    }

    @Test func nativeVisibilityCommandsChangeOnlyTheirOwnDimensionGroupAndPersist() throws {
        let suite = "ChunkseeTests-\(UUID())", world = URL(fileURLWithPath: "/Visibility Commands")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LayerVisibility(world: world, dimension: "minecraft:overworld", defaults: defaults)
        let other = LayerVisibility(world: world, dimension: "minecraft:the_nether", defaults: defaults)
        func exercise<Group: Hashable>(_ group: Group, _ keyPath: ReferenceWritableKeyPath<LayerVisibility, Set<Group>>) throws {
            first[keyPath: keyPath] = [group]
            other[keyPath: keyPath] = [group]
            let binding = Binding { first[keyPath: keyPath].contains(group) } set: { shown in
                if shown { first[keyPath: keyPath].insert(group) } else { first[keyPath: keyPath].remove(group) }
            }
            try perform(binding, title: "Hide on Map")
            #expect(first[keyPath: keyPath].isEmpty && other[keyPath: keyPath] == [group])
            let restored = LayerVisibility(world: world, dimension: "minecraft:overworld", defaults: defaults)
            #expect(restored[keyPath: keyPath].isEmpty)
            try perform(binding, title: "Show on Map")
            #expect(first[keyPath: keyPath] == [group] && other[keyPath: keyPath] == [group])
        }
        try exercise(.mineshaft, \.structures)
        try exercise(.spawner, \.places)
        try exercise(.pet, \.creatures)
        try exercise(BiomeGroup(id: "minecraft:plains"), \.biomes)
        #expect(defaults.object(forKey: "shownStructureGroups") == nil)
    }

    @Test func playerCommandKeepsOtherPlayersAndDimensionSettings() throws {
        let suite = "ChunkseeTests-\(UUID())", world = URL(fileURLWithPath: "/Player Visibility Commands")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LayerVisibility(world: world, dimension: "minecraft:overworld", defaults: defaults)
        let other = LayerVisibility(world: world, dimension: "minecraft:the_nether", defaults: defaults)
        let player = UUID(), alreadyHidden = UUID()
        first.hiddenPlayers = [alreadyHidden]
        other.hiddenPlayers = []
        let binding = Binding { !first.hiddenPlayers.contains(player) } set: { shown in
            if shown { first.hiddenPlayers.remove(player) } else { first.hiddenPlayers.insert(player) }
        }
        try perform(binding, title: "Hide on Map")
        #expect(first.hiddenPlayers == [alreadyHidden, player] && other.hiddenPlayers.isEmpty)
        #expect(LayerVisibility(world: world, dimension: "minecraft:overworld", defaults: defaults).hiddenPlayers == [alreadyHidden, player])
        try perform(binding, title: "Show on Map")
        #expect(first.hiddenPlayers == [alreadyHidden] && other.hiddenPlayers.isEmpty)
    }

    @Test func savedQueryCommandUsesTheLiveBindingAndDoesNotRecreateARemovedQuery() throws {
        let suite = "ChunkseeTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
