import AppKit
import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct DimensionTabsTests {
    private func makeResources(documentOwnsLifetime: Bool = true) async throws -> (URL, WorldResources) {
        let url = try TestWorld.make(chunks: [])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM1/region"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       documentOwnsLifetime: documentOwnsLifetime)
        return (url, resources)
    }

    @Test func tabsKeepIndependentViewsHistoriesRulersAndSearches() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let original = MapViewport(center: CGPoint(x: 120, y: -80), scale: 0.25)
        overworld.map?.viewport = original
        nether.map?.viewport = MapViewport(center: CGPoint(x: 15, y: -10), scale: 8)
        overworld.goToCoordinates(CGPoint(x: 300, y: 400))
        overworld.ruler.isEnabled = true
        overworld.ruler.mark(.zero)
        overworld.ruler.mark(CGPoint(x: 3, y: 4))
        overworld.search.text = "diamond"
        nether.search.text = "ancient debris"
        #expect(overworld.search.indexStore === nether.search.indexStore)
        #expect(overworld.savedPlaces === nether.savedPlaces)
        #expect(overworld.search.text == "diamond" && nether.search.text == "ancient debris")
        #expect(!nether.navigation.canGoBack && nether.ruler.start == nil)
        #expect(nether.map?.viewport == MapViewport(center: CGPoint(x: 15, y: -10), scale: 8))
        overworld.goBack()
        #expect(overworld.map?.viewport == original && overworld.ruler.distance == 5)
        overworld.close()
        await overworld.waitUntilClosed()
        #expect(!resources.isClosed && !nether.isClosed)
        await nether.search.waitForIndex()
        #expect(nether.search.index.dimensions.count == 3)
        resources.close()
        await resources.waitUntilClosed()
        #expect(nether.isClosed)
    }

    @Test func crossDimensionActionsUseTheDestinationTabAndItsHistory() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let sourceView = MapViewport(center: CGPoint(x: 100, y: 200), scale: 0.5)
        let targetView = MapViewport(center: CGPoint(x: 12, y: 24), scale: 4)
        overworld.map?.viewport = sourceView
        nether.map?.viewport = targetView
        var selectedTab: String?
        overworld.openDimensionTab = { id, perform in selectedTab = id; perform(nether) }
        let place = try #require(overworld.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: CGPoint(x: 9, y: -7)))
        overworld.visit(place)
        #expect(selectedTab == "minecraft:the_nether")
        #expect(overworld.selectedDimensionID == "minecraft:overworld" && overworld.map?.viewport == sourceView)
        #expect(!overworld.navigation.canGoBack)
        #expect(nether.map?.viewport == MapViewport(center: place.position, scale: 4))
        nether.goBack()
        #expect(nether.map?.viewport == targetView)
        selectedTab = nil
        overworld.openDimension("minecraft:the_nether")
        #expect(selectedTab == "minecraft:the_nether" && nether.map?.viewport == targetView)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func closingTheLastStandaloneViewDrainsTheSharedIndex() async throws {
        let (url, resources) = try await makeResources(documentOwnsLifetime: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        overworld.close()
        #expect(!resources.isClosed)
        end.close()
        await end.waitUntilClosed()
        #expect(end.isClosed && resources.isClosed)
    }

    @Test func nativeDimensionWindowsBelongToOneDocument() async throws {
        let (url, resources) = try await makeResources()
        let document = WorldDocument(resources: resources)
        defer { document.close(); try? FileManager.default.removeItem(at: url) }
        document.makeWindowControllers()
        let controllers = document.windowControllers.compactMap { $0 as? DimensionWindowController }
        #expect(controllers.count == 3)
        #expect(controllers.allSatisfy { $0.document as? NSDocument === document })
        #expect(controllers.allSatisfy { $0.window?.restorationClass is NSDocumentController.Type })
        #expect(controllers.first?.window?.tabbedWindows?.count == 3)
        let closed = try #require(controllers.first)
        document.removeWindowController(closed)
        #expect(document.windowControllers.count == 2 && closed.session.isClosed)
        #expect(!resources.isClosed)
        #expect(controllers.dropFirst().allSatisfy { !$0.session.isClosed })
        document.close()
        await resources.waitUntilClosed()
        #expect(resources.isClosed && controllers.allSatisfy { $0.session.isClosed })
    }

    @Test func liveChangesRefreshTheMatchingDimensionViews() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        resources.refreshDelay = .zero
        let views = resources.dimensions.map { WorldSession(resources: resources, dimensionID: $0.id) }
        let nether = try #require(views.first { $0.selectedDimensionID == "minecraft:the_nether" })
        let end = try #require(views.first { $0.selectedDimensionID == "minecraft:the_end" })
        let overworld = try #require(views.first { $0.selectedDimensionID == "minecraft:overworld" })
        let netherFile = url.appendingPathComponent("DIM-1/region/r.0.0.mca")
        let endFile = url.appendingPathComponent("DIM1/region/r.1.-1.mca")
        try Data(count: 8192).write(to: netherFile)
        try Data(count: 8192).write(to: endFile)
        resources.worldChanged([netherFile, endFile])
        await resources.waitForRefresh()
        #expect(nether.map?.availableRegions == [RegionCoordinate(x: 0, z: 0)])
        #expect(end.map?.availableRegions == [RegionCoordinate(x: 1, z: -1)])
        #expect(overworld.map?.availableRegions.isEmpty == true)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func movingAWorldRetainsAllDimensionViews() {
        let suite = "ChunkseeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let views = RememberedViews(world: URL(fileURLWithPath: "/Worlds/Old"), defaults: defaults)
        let newURL = URL(fileURLWithPath: "/Worlds/Moved")
        let overworld = MapViewport(center: CGPoint(x: 120, y: -300), scale: 0.25)
        let nether = MapViewport(center: CGPoint(x: 15, y: -37), scale: 4)
        views.save(overworld, for: "minecraft:overworld", selected: "minecraft:overworld")
        views.save(nether, for: "minecraft:the_nether", selected: "minecraft:overworld")
        views.relocate(to: newURL)
        let moved = RememberedViews(world: newURL, defaults: defaults)
        #expect(moved.viewport(for: "minecraft:overworld") == overworld)
        #expect(moved.viewport(for: "minecraft:the_nether") == nether)
        #expect(moved.lastDimension == "minecraft:overworld")
        #expect(views.viewport(for: "minecraft:overworld") == nil)
    }
}
