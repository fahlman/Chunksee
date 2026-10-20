import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SavedPlacesTests {
    @Test func committingANewPlaceRevealsItsDimensionButRenamingDoesNot() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                           savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { resources.close() }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let view = overworld.map?.viewport
        overworld.visibility.showsSavedPlaces = false
        nether.visibility.showsSavedPlaces = false
        let draft = SavedPlaceDraft(name: "", dimension: "minecraft:overworld", position: CGPoint(x: -8, y: 20))
        #expect(!overworld.annotations.commit(draft, name: "  "))
        #expect(!overworld.visibility.showsSavedPlaces && resources.savedPlaces.all.isEmpty)
        #expect(overworld.annotations.commit(draft, name: "Home"))
        let home = try #require(resources.savedPlaces.all.first)
        #expect(overworld.visibility.showsSavedPlaces && !nether.visibility.showsSavedPlaces)
        #expect(MapContent(session: overworld).savedPlaces == [home])
        #expect(overworld.map?.viewport == view && !overworld.navigation.canGoBack)
        overworld.visibility.showsSavedPlaces = false
        let edit = SavedPlaceDraft(existingID: home.id, name: home.name, dimension: home.dimension, position: home.position)
        #expect(overworld.annotations.commit(edit, name: "Renamed"))
        #expect(resources.savedPlaces.all.first?.name == "Renamed" && !overworld.visibility.showsSavedPlaces)
        let other = SavedPlaceDraft(name: "", dimension: "minecraft:the_nether", position: .zero)
        #expect(nether.annotations.commit(other, name: "Fortress"))
        #expect(nether.visibility.showsSavedPlaces && !overworld.visibility.showsSavedPlaces)
        #expect(MapContent(session: nether).savedPlaces.map(\.name) == ["Fortress"])
        let saved = resources.savedPlaces.all
        resources.close()
        await resources.waitUntilClosed()
        #expect(!overworld.annotations.commit(draft, name: "Too Late"))
        #expect(!overworld.visibility.showsSavedPlaces && resources.savedPlaces.all == saved)
    }

    @Test(arguments: [false, true])
    func savingInAnotherDimensionRevealsItsLayerWithoutNavigating(destinationIsOpen: Bool) async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                           savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { resources.close() }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        overworld.visibility.showsSavedPlaces = false
        nether.visibility.showsSavedPlaces = false
        nether.visibility.showsGrid = true
        let sourceView = MapViewport(center: CGPoint(x: 120, y: -80), scale: 0.25)
        let destinationView = MapViewport(center: CGPoint(x: 15, y: -10), scale: 8)
        overworld.map?.viewport = sourceView
        nether.map?.viewport = destinationView
        overworld.becameActive()
        if !destinationIsOpen {
            nether.close()
            await nether.waitUntilClosed()
        }
        // No native opener is needed to save a bookmark in another dimension.
        overworld.annotations.savePlace(at: CGPoint(x: -8, y: 20), in: "minecraft:the_nether")
        let draft = try #require(overworld.annotations.draft)
        #expect(overworld.annotations.commit(draft, name: "Death Point"))
        #expect(resources.activeDimensionID == "minecraft:overworld")
        #expect(overworld.selectedDimensionID == "minecraft:overworld" && overworld.map?.viewport == sourceView)
        #expect(!overworld.visibility.showsSavedPlaces && !overworld.navigation.canGoBack)
        #expect(resources.settings.layers(for: "minecraft:the_nether")?[.showsSavedPlaces] as? Bool == true)
        let destination = destinationIsOpen ? nether : WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(destination.visibility.showsSavedPlaces && destination.visibility.showsGrid)
        #expect(destination.map?.viewport == destinationView && !destination.navigation.canGoBack)
        #expect(destination.annotations.listedPlaces.map(\.name) == ["Death Point"])
        #expect(overworld.annotations.listedPlaces.isEmpty)
        resources.close()
        await resources.waitUntilClosed()
    }

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
