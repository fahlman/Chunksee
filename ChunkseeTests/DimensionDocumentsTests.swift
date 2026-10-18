import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct DimensionDocumentsTests {
    private func makeResources(defaults suppliedDefaults: UserDefaults? = nil) async throws -> (URL, WorldResources) {
        let url = try TestWorld.make(chunks: [])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM1/region"), withIntermediateDirectories: true)
        let defaults = suppliedDefaults ?? UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
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

    @Test(arguments: ["menu", "location", "saved place"])
    func aDimensionDoesNotChangeWithoutTheNativeOpener(_ action: String) async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let source = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let map = try #require(source.map), visibility = source.visibility
        let original = MapViewport(center: CGPoint(x: 123, y: -456), scale: 4)
        map.viewport = original
        source.ruler.isEnabled = true
        source.ruler.mark(.zero)
        source.ruler.mark(CGPoint(x: 3, y: 4))
        let place = try #require(source.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: CGPoint(x: 9, y: -7)))
        switch action {
        case "menu": source.openDimension(place.dimension)
        case "location": source.focus(on: .init(dimension: place.dimension, x: 9, y: 64, z: -7))
        default: source.visit(place)
        }
        #expect(source.selectedDimensionID == "minecraft:overworld")
        #expect(source.map === map && source.map?.viewport == original)
        #expect(source.visibility === visibility && source.ruler.distance == 5)
        #expect(!source.navigation.canGoBack && resources.activeDimensionID == "minecraft:overworld")
        // A later normal opening must not replay an action that could not invoke its opener.
        let target = WorldSession(resources: resources, dimensionID: place.dimension)
        #expect(target.map?.viewport.center != place.position && !target.navigation.canGoBack)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func restoringAnotherDimensionKeepsTheTargetDocumentIdentity() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let source = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        source.map?.viewport = MapViewport(center: CGPoint(x: 123, y: -456), scale: 4)
        source.goToCoordinates(CGPoint(x: 500, y: 600))
        source.ruler.isEnabled = true
        source.ruler.mark(.zero)
        source.ruler.mark(CGPoint(x: 3, y: 4))
        let target = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let map = try #require(target.map), original = map.viewport
        target.restoreView(from: source)
        #expect(target.selectedDimensionID == "minecraft:the_nether")
        #expect(target.map === map && target.map?.viewport == original)
        #expect(!target.navigation.canGoBack && !target.navigation.canGoForward)
        #expect(target.ruler.start == nil && target.ruler.end == nil)
        resources.close()
        await resources.waitUntilClosed()
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
        overworld.ruler.isEnabled = true
        overworld.ruler.mark(.zero)
        overworld.ruler.mark(CGPoint(x: 3, y: 4))
        var opened = recordOpens(of: overworld)
        let netherDocument = resources.documentURL(for: "minecraft:the_nether")
        let place = try #require(overworld.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: CGPoint(x: 9, y: -7)))
        overworld.visit(place)
        let jumpOpened = await opened.next(isolation: #isolation)
        #expect(jumpOpened == netherDocument)
        #expect(overworld.selectedDimensionID == "minecraft:overworld" && overworld.map?.viewport == sourceView)
        #expect(!overworld.navigation.canGoBack && overworld.ruler.distance == 5 && nether.ruler.start == nil)
        #expect(nether.map?.viewport == MapViewport(center: place.position, scale: 4))
        nether.goBack()
        #expect(nether.map?.viewport == targetView && !nether.navigation.canGoBack)
        nether.goForward()
        #expect(nether.map?.viewport.center == place.position && !nether.navigation.canGoForward)
        nether.goBack()
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

    @Test func openingAnUnrecognizedFolderAsksForAWorldInsteadOfDiagnosingADimension() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let reader = WorldDocument.Reader(folders: WorldFolders(defaults: defaults))
        for path in ["minecraft/vanilla/release/saves", "unrelated"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["minecraft", "unrelated"] {
            await #expect(throws: WorldOpenError.notAWorld) { try await reader.readFolder(url.appendingPathComponent(path)) }
        }
        #expect(defaults.array(forKey: "worldFolderBookmarks")?.isEmpty ?? true)
    }

    @Test func aCorruptWorldIsNotRetriedAsADimension() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a level file".utf8).write(to: url.appendingPathComponent("level.dat"))
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let reader = WorldDocument.Reader(folders: WorldFolders(defaults: defaults))
        await #expect(throws: WorldOpenError.unreadable) { try await reader.readFolder(url) }
        #expect(defaults.array(forKey: "worldFolderBookmarks") == nil)
    }

    @Test func theFolderReaderRemembersAWorldAndReadsItsDimensionDocuments() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let folders = WorldFolders(defaults: UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!)
        let reader = WorldDocument.Reader(folders: folders)
        let expected = try World(contentsOf: url).dimensions().map { $0.documentURL(inWorldAt: url) }
        guard case .world(let documents) = try await reader.readFolder(url) else {
            Issue.record("A world folder should open its dimensions")
            return
        }
        #expect(documents == expected && !documents.isEmpty)
        for document in documents {
            guard case .dimension(let snapshot) = try await reader.readFolder(document) else {
                Issue.record("A remembered dimension should read through its world")
                continue
            }
            #expect(snapshot.world.world.level.name == "Test" && snapshot.documentURL == document)
            snapshot.world.access.release()
        }
        await #expect(throws: WorldOpenError.notADimension) {
            try await reader.readFolder(url.appendingPathComponent("dimensions"))
        }
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

    @Test func focusedDocumentsSetPriorityAndInactiveSavesKeepTheFrontDimension() async throws {
        let (url, resources) = try await makeResources()
        defer { try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        overworld.map?.viewport = MapViewport(center: CGPoint(x: 120, y: 240), scale: 2)
        nether.map?.viewport = MapViewport(center: CGPoint(x: 15, y: 30), scale: 4)
        nether.becameActive()
        #expect(resources.activeDimensionID == "minecraft:the_nether")
        #expect(resources.views.lastDimension == "minecraft:the_nether")
        overworld.becameActive(isTerminating: true)
        #expect(resources.activeDimensionID == "minecraft:the_nether")
        #expect(resources.views.lastDimension == "minecraft:the_nether")
        overworld.saveView()
        #expect(resources.views.lastDimension == "minecraft:the_nether")
        #expect(resources.views.viewport(for: "minecraft:overworld") == overworld.map?.viewport)
        overworld.close()
        await overworld.waitUntilClosed()
        overworld.becameActive() // a late focus update for a closed document is ignored
        #expect(resources.activeDimensionID == "minecraft:the_nether")
        end.becameActive()
        #expect(resources.views.lastDimension == "minecraft:the_end")
        nether.saveView()
        resources.close()
        await resources.waitUntilClosed()
        nether.becameActive()
        #expect(resources.views.lastDimension == "minecraft:the_end")
        let reopened = WorldResources(snapshot: try await WorldSnapshot.read(url), names: resources.names,
                                      savedSearches: resources.savedSearches, defaults: resources.defaults, cacheRoot: nil)
        #expect(reopened.defaultDimensionID == "minecraft:the_end")
        #expect(reopened.activeDimensionID == "minecraft:the_end")
        reopened.close()
        await reopened.waitUntilClosed()
    }

    @Test func focusKeepsEachWorldsRememberedSelectionIndependent() async throws {
        let (a, first) = try await makeResources()
        let (b, second) = try await makeResources(defaults: first.defaults)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let one = WorldSession(resources: first, dimensionID: "minecraft:the_nether")
        let two = WorldSession(resources: second, dimensionID: "minecraft:the_end")
        one.becameActive()
        two.becameActive()
        #expect(first.views.lastDimension == "minecraft:the_nether")
        #expect(second.views.lastDimension == "minecraft:the_end")
        #expect(first.activeDimensionID == "minecraft:the_nether" && second.activeDimensionID == "minecraft:the_end")
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed()
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
