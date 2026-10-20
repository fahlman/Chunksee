import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SavedPlacesTests {
    @Test func placesPersistPerWorldAndRenamingAndRemovalAreRemembered() throws {

        let defaults = TestDefaults.make()

        let first = UUID(), second = UUID()
        let places = SavedPlaces(settings: WorldSettings(id: first, defaults: defaults))
        let place = try #require(places.add(name: "  Home  ", dimension: "minecraft:overworld", at: CGPoint(x: -0.1, y: 71.9)))
        #expect(place.name == "Home" && place.position == CGPoint(x: -1, y: 71))
        #expect(SavedPlaces(settings: WorldSettings(id: first, defaults: defaults)).all == [place])
        #expect(SavedPlaces(settings: WorldSettings(id: second, defaults: defaults)).all.isEmpty)
        places.rename(place.id, to: "Iron Farm")
        #expect(SavedPlaces(settings: WorldSettings(id: first, defaults: defaults)).all.first?.name == "Iron Farm")
        places.rename(place.id, to: "\n ")
        #expect(places.all.first?.name == "Iron Farm")
        places.remove(place.id)
        #expect(SavedPlaces(settings: WorldSettings(id: first, defaults: defaults)).all.isEmpty)
        #expect(places.add(name: " ", dimension: "minecraft:overworld", at: .zero) == nil)
        #expect(places.add(name: "Invalid", dimension: "minecraft:overworld", at: CGPoint(x: CGFloat.infinity, y: 0)) == nil)
    }

}
