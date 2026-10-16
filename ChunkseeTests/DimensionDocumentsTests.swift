import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct DimensionDocumentsTests {
    private func makeResources() async throws -> (URL, WorldResources) {
        let url = try TestWorld.make(chunks: [])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM1/region"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        return (url, resources)
    }

    /// Installs an opening action like a document view's, and returns the documents it's asked to open.
    private func recordOpens(of session: WorldSession) -> AsyncStream<URL>.Iterator {
        let (requests, continuation) = AsyncStream.makeStream(of: URL.self)
        session.openDocument = { continuation.yield($0) }
        return requests.makeAsyncIterator()
    }

    @Test func dimensionsKeepIndependentViewsHistoriesRulersAndSearches() async throws {
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

    @Test func crossDimensionActionsUseTheDestinationDocumentAndItsHistory() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let sourceView = MapViewport(center: CGPoint(x: 100, y: 200), scale: 0.5)
        let targetView = MapViewport(center: CGPoint(x: 12, y: 24), scale: 4)
        overworld.map?.viewport = sourceView
        nether.map?.viewport = targetView
        var opened = recordOpens(of: overworld)
        let netherDocument = resources.documentURL(for: "minecraft:the_nether")
        let place = try #require(overworld.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: CGPoint(x: 9, y: -7)))
        overworld.visit(place)
        let jumpOpened = await opened.next(isolation: #isolation)
        #expect(jumpOpened == netherDocument)
        #expect(overworld.selectedDimensionID == "minecraft:overworld" && overworld.map?.viewport == sourceView)
        #expect(!overworld.navigation.canGoBack)
        #expect(nether.map?.viewport == MapViewport(center: place.position, scale: 4))
        nether.goBack()
        #expect(nether.map?.viewport == targetView)
        overworld.openDimension("minecraft:the_nether")
        let menuOpened = await opened.next(isolation: #isolation)
        #expect(menuOpened == netherDocument && nether.map?.viewport == targetView)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func eachDimensionListsOnlyWhatIsInIt() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let base = try #require(nether.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: .zero))
        #expect(nether.listedPlaces.map(\.id) == [base.id] && overworld.listedPlaces.isEmpty)
        let viewport = nether.map?.viewport
        nether.mapClicked(.row(.savedPlace(base.id)))
        #expect(nether.sidebarSelection == .savedPlace(base.id) && nether.map?.viewport == viewport)
        overworld.mapClicked(.row(.savedPlace(base.id)))
        #expect(overworld.sidebarSelection == nil && nether.sidebarSelection == .savedPlace(base.id))
        #expect(nether.lists("minecraft:the_nether") && !nether.lists("minecraft:overworld"))
        // Something with no dimension in this world is listed once, with the Overworld.
        #expect(overworld.lists(nil) && !nether.lists(nil))
        #expect(overworld.lists("laurenland:world") && !nether.lists("laurenland:world"))
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func closingTheLastDimensionDrainsTheSharedIndex() async throws {
        let (url, resources) = try await makeResources()
        defer { try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        overworld.close()
        #expect(!resources.isClosed)
        end.close()
        await end.waitUntilClosed()
        #expect(end.isClosed && resources.isClosed)
    }

    @Test func aJumpWaitsForItsDimensionDocumentToOpen() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        var opened = recordOpens(of: overworld)
        let place = try #require(overworld.savedPlaces.add(name: "End City", dimension: "minecraft:the_end", at: CGPoint(x: 900, y: -400)))
        overworld.visit(place)
        let endOpened = await opened.next(isolation: #isolation)
        #expect(endOpened == resources.documentURL(for: "minecraft:the_end"))
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        #expect(end.map?.viewport.center == place.position)
        // A later document for the same dimension doesn't replay the jump.
        end.map?.viewport.center = .zero
        end.close()
        let reopened = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        #expect(reopened.map?.viewport.center == .zero && !reopened.navigation.canGoBack)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func aJumpWhoseDimensionFailsToOpenIsDropped() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        overworld.openDocument = { _ in throw CocoaError(.fileReadNoPermission) }
        let place = try #require(overworld.savedPlaces.add(name: "End City", dimension: "minecraft:the_end", at: CGPoint(x: 900, y: -400)))
        overworld.visit(place)
        for await failure in Observations({ overworld.openFailure }) where failure != nil { break }
        // Opening the End normally later keeps its own view, without the failed jump.
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        #expect(end.map?.viewport.center != place.position && !end.navigation.canGoBack)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func aDimensionViewWithItsOpeningActionIsReleased() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        var nether: WorldSession? = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        weak let released = nether
        _ = recordOpens(of: try #require(nether))
        nether?.openDimension("minecraft:overworld")
        nether?.close()
        await nether?.waitUntilClosed()
        nether = nil
        #expect(released == nil)
    }

    @Test func theOlderLayoutsOverworldIsItsRegionFolder() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.removeItem(at: url.appendingPathComponent("dimensions"))
        for folder in ["region", "DIM-1/region"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let suite = "ChunkseeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folders = WorldFolders(defaults: defaults)
        folders.remember(url)
        let documents = try World(contentsOf: url).dimensions().map { $0.documentURL(inWorldAt: url) }
        #expect(documents.map(\.lastPathComponent).sorted() == ["DIM-1", "region"])
        let overworld = try await DimensionSnapshot.read(url.appendingPathComponent("region"), folders: folders)
        #expect(overworld.dimensionID == "minecraft:overworld")
        overworld.world.access.release()
    }

    @Test func aDimensionDocumentReadsItsWorldThroughTheRememberedFolder() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let suite = "ChunkseeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folders = WorldFolders(defaults: defaults)
        let nether = url.appendingPathComponent("DIM-1")
        await #expect(throws: WorldOpenError.needsWorldFolder) { try await DimensionSnapshot.read(nether, folders: folders) }
        folders.remember(url)
        folders.remember(url) // remembering again keeps one bookmark
        #expect((defaults.array(forKey: "worldFolderBookmarks") ?? []).count == 1)
        let snapshot = try await DimensionSnapshot.read(nether, folders: folders)
        #expect(snapshot.dimensionID == "minecraft:the_nether" && snapshot.world.world.level.name == "Test")
        let overworld = try await DimensionSnapshot.read(url.appendingPathComponent("dimensions/minecraft/overworld"), folders: folders)
        #expect(overworld.dimensionID == "minecraft:overworld")
        await #expect(throws: WorldOpenError.notADimension) {
            try await DimensionSnapshot.read(url.appendingPathComponent("dimensions"), folders: folders)
        }

        // Dimensions of one open world share its resources until the last one closes.
        let model = AppModel(defaults: defaults)
        let first = model.resources(for: snapshot.world)
        #expect(model.resources(for: overworld.world) === first)
        let view = WorldSession(resources: first, dimensionID: snapshot.dimensionID)
        view.close()
        await view.waitUntilClosed()
        let again = try await DimensionSnapshot.read(nether, folders: folders)
        let second = model.resources(for: again.world)
        #expect(second !== first)
        second.close()
        await second.waitUntilClosed()
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

    @Test func savesDuringPlayDoNotPostponeTheRefresh() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        resources.refreshDelay = .milliseconds(200)
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let file = url.appendingPathComponent("DIM-1/region/r.0.0.mca")
        try Data(count: 8192).write(to: file)
        // The game keeps saving more often than the delay, as it does while a player explores. The
        // sleep paces those saves; the loop ends as soon as the map shows the new region.
        let start = ContinuousClock.now
        while nether.map?.availableRegions.isEmpty == true, ContinuousClock.now - start < .seconds(2) {
            resources.worldChanged([file])
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(nether.map?.availableRegions == [RegionCoordinate(x: 0, z: 0)])
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func closingWhileIndexingEndsTheWaitAndDropsTheQueuedPass() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let gate = AsyncReadGate<RegionData>()
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       readRegion: { _, _ in await gate.read("region") })
        await gate.waitForRequest("region")
        let waiter = Task { await resources.index.waitForIndex() }
        resources.index.rebuild(firstDimension: nil)   // queued behind the running pass
        resources.close()
        await gate.finish("region", with: RegionData())
        await waiter.value                              // ends instead of waiting forever
        await resources.waitUntilClosed()
        #expect(await gate.requested == ["region"])     // the queued pass never ran
    }

    @Test func anOlderPlayerReadCannotOverwriteANewerOne() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        resources.refreshDelay = .zero
        let gate = AsyncReadGate<[PlayerInfo]>()
        let reads = ReadCounter()
        resources.readPlayers = { _ in await gate.read("read\(await reads.next())") }
        let uuid = UUID()
        func player(atX x: Double) -> PlayerInfo {
            PlayerInfo(uuid: uuid, nbt: .compound(["DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
                                                    "Pos": .list([.double(x), .double(64), .double(0)])]))
        }
        let file = resources.world.playerDataDirectory.appendingPathComponent(uuid.uuidString.lowercased() + ".dat")
        resources.worldChanged([file])
        await gate.waitForRequest("read0")              // the first refresh is reading the older file
        resources.worldChanged([file])
        await gate.waitForRequest("read1")              // a second refresh reads the newer one
        await gate.finish("read1", with: [player(atX: 200)])
        await gate.finish("read0", with: [player(atX: 100)])
        await resources.waitForRefresh()
        #expect(resources.players.first?.position?.x == 200)
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

/// Numbers calls in the order they arrive.
private actor ReadCounter {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
}
