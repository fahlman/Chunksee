import CoreGraphics
import Foundation
import Testing
@testable import Chunksee

@Suite struct SavedPlacesTests {
    @Test func placesPersistPerWorldAndRenamingAndRemovalAreRemembered() throws {
        let suite = "ChunkseeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/Worlds/First"), second = URL(fileURLWithPath: "/Worlds/Second")
        let places = SavedPlaces(world: first, defaults: defaults)
        let place = try #require(places.add(name: "  Home  ", dimension: "minecraft:overworld", at: CGPoint(x: -0.1, y: 71.9)))
        #expect(place.name == "Home" && place.position == CGPoint(x: -1, y: 71))
        #expect(SavedPlaces(world: first, defaults: defaults).all == [place])
        #expect(SavedPlaces(world: second, defaults: defaults).all.isEmpty)
        places.rename(place.id, to: "Iron Farm")
        #expect(SavedPlaces(world: first, defaults: defaults).all.first?.name == "Iron Farm")
        places.rename(place.id, to: "\n ")
        #expect(places.all.first?.name == "Iron Farm")
        places.remove(place.id)
        #expect(SavedPlaces(world: first, defaults: defaults).all.isEmpty)
        #expect(places.add(name: " ", dimension: "minecraft:overworld", at: .zero) == nil)
        #expect(places.add(name: "Invalid", dimension: "minecraft:overworld", at: CGPoint(x: CGFloat.infinity, y: 0)) == nil)
    }

    @Test func aNativeDocumentMoveRetainsPlacesAndRemovesTheOldPreferenceKey() throws {
        let suite = "ChunkseeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldURL = URL(fileURLWithPath: "/Worlds/Old"), newURL = URL(fileURLWithPath: "/Worlds/New")
        let places = SavedPlaces(world: oldURL, defaults: defaults)
        let place = try #require(places.add(name: "Base", dimension: "minecraft:the_nether", at: CGPoint(x: 1, y: 2)))
        places.relocate(to: newURL)
        #expect(SavedPlaces(world: newURL, defaults: defaults).all == [place])
        #expect(SavedPlaces(world: oldURL, defaults: defaults).all.isEmpty)
    }
}
