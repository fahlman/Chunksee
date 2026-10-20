import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DimensionDocumentsTests {
    private func makeResources(defaults suppliedDefaults: UserDefaults? = nil) async throws -> (URL, WorldResources) {
        let url = try TestWorld.make(chunks: [])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM1/region"), withIntermediateDirectories: true)
        let defaults = suppliedDefaults ?? TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        return (url, resources)
    }

    /// Installs an opening action like a document view's, and returns the documents it's asked to open.
    private func recordOpens(of session: WorldSession) -> AsyncStream<URL>.Iterator {
        let (requests, continuation) = AsyncStream.makeStream(of: URL.self)
        session.routing.openDocument = { continuation.yield($0) }
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
        source.annotations.ruler.isEnabled = true
        source.annotations.ruler.mark(.zero)
        source.annotations.ruler.mark(CGPoint(x: 3, y: 4))
        let place = try #require(source.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: CGPoint(x: 9, y: -7)))
        switch action {
        case "menu": source.routing.openDimension(place.dimension)
        case "location": source.routing.focus(on: .init(dimension: place.dimension, x: 9, y: 64, z: -7))
        default: source.annotations.visit(place)
        }
        #expect(source.selectedDimensionID == "minecraft:overworld")
        #expect(source.map === map && source.map?.viewport == original)
        #expect(source.visibility === visibility && source.annotations.ruler.distance == 5)
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
        source.navigation.goToCoordinates(CGPoint(x: 500, y: 600))
        source.annotations.ruler.isEnabled = true
        source.annotations.ruler.mark(.zero)
        source.annotations.ruler.mark(CGPoint(x: 3, y: 4))
        let target = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let map = try #require(target.map), original = map.viewport
        target.restoreView(from: source)
        #expect(target.selectedDimensionID == "minecraft:the_nether")
        #expect(target.map === map && target.map?.viewport == original)
        #expect(!target.navigation.canGoBack && !target.navigation.canGoForward)
        #expect(target.annotations.ruler.start == nil && target.annotations.ruler.end == nil)
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
        overworld.navigation.goToCoordinates(CGPoint(x: 300, y: 400))
        overworld.annotations.ruler.isEnabled = true
        overworld.annotations.ruler.mark(.zero)
        overworld.annotations.ruler.mark(CGPoint(x: 3, y: 4))
        overworld.search.text = "diamond"
        nether.search.text = "ancient debris"
        #expect(overworld.search.indexStore === nether.search.indexStore)
        #expect(overworld.savedPlaces === nether.savedPlaces)
        #expect(overworld.search.text == "diamond" && nether.search.text == "ancient debris")
        #expect(!nether.navigation.canGoBack && nether.annotations.ruler.start == nil)
        #expect(nether.map?.viewport == MapViewport(center: CGPoint(x: 15, y: -10), scale: 8))
        overworld.navigation.goBack()
        #expect(overworld.map?.viewport == original && overworld.annotations.ruler.distance == 5)
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
        overworld.annotations.ruler.isEnabled = true
        overworld.annotations.ruler.mark(.zero)
        overworld.annotations.ruler.mark(CGPoint(x: 3, y: 4))
        var opened = recordOpens(of: overworld)
        let netherDocument = resources.documentURL(for: "minecraft:the_nether")
        let place = try #require(overworld.savedPlaces.add(name: "Nether Base", dimension: "minecraft:the_nether", at: CGPoint(x: 9, y: -7)))
        overworld.annotations.visit(place)
        let jumpOpened = await opened.next(isolation: #isolation)
        #expect(jumpOpened == netherDocument)
        #expect(overworld.selectedDimensionID == "minecraft:overworld" && overworld.map?.viewport == sourceView)
        #expect(!overworld.navigation.canGoBack && overworld.annotations.ruler.distance == 5 && nether.annotations.ruler.start == nil)
        #expect(nether.map?.viewport == MapViewport(center: place.mapPosition, scale: 4))
        nether.navigation.goBack()
        #expect(nether.map?.viewport == targetView && !nether.navigation.canGoBack)
        nether.navigation.goForward()
        #expect(nether.map?.viewport.center == place.mapPosition && !nether.navigation.canGoForward)
        nether.navigation.goBack()
        overworld.routing.openDimension("minecraft:the_nether")
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
        #expect(nether.annotations.listedPlaces.map(\.id) == [base.id] && overworld.annotations.listedPlaces.isEmpty)
        let viewport = nether.map?.viewport
        nether.selection.mapClicked(.row(.savedPlace(base.id)), y: nil)
        #expect(nether.selection.sidebarSelection == .savedPlace(base.id) && nether.map?.viewport == viewport)
        overworld.selection.mapClicked(.row(.savedPlace(base.id)), y: nil)
        #expect(overworld.selection.sidebarSelection == nil && nether.selection.sidebarSelection == .savedPlace(base.id))
        #expect(nether.presentation.lists("minecraft:the_nether") && !nether.presentation.lists("minecraft:overworld"))
        // Something with no dimension in this world is listed once, with the Overworld.
        #expect(overworld.presentation.lists(nil) && !nether.presentation.lists(nil))
        #expect(overworld.presentation.lists("laurenland:world") && !nether.presentation.lists("laurenland:world"))
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
        overworld.annotations.visit(place)
        let endOpened = await opened.next(isolation: #isolation)
        #expect(endOpened == resources.documentURL(for: "minecraft:the_end"))
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        #expect(end.map?.viewport.center == CGPoint(x: 900.5, y: -399.5))
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
        overworld.routing.openDocument = { _ in throw CocoaError(.fileReadNoPermission) }
        let place = try #require(overworld.savedPlaces.add(name: "End City", dimension: "minecraft:the_end", at: CGPoint(x: 900, y: -400)))
        overworld.annotations.visit(place)
        for await failure in Observations({ overworld.routing.openFailure }) where failure != nil { break }
        // Opening the End normally later keeps its own view, without the failed jump.
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        #expect(end.map?.viewport.center != CGPoint(x: 900.5, y: -399.5) && !end.navigation.canGoBack)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func aDimensionViewWithItsOpeningActionIsReleased() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        var nether: WorldSession? = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        weak let released = nether
        _ = recordOpens(of: try #require(nether))
        let routing = try #require(nether?.routing)
        nether?.routing.openDimension("minecraft:overworld")
        nether?.close()
        await nether?.waitUntilClosed()
        nether = nil
        #expect(released == nil)
        #expect(!routing.route(to: "minecraft:overworld", perform: { _ in
            Issue.record("A released source must not route another action")
        }))
    }

    @Test func anOlderOpenFailureKeepsTheNewerDestinationsAction() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let firstSource = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let secondSource = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let first = try #require(resources.savedPlaces.add(name: "First", dimension: "minecraft:the_end", at: CGPoint(x: 40, y: 80)))
        let latest = try #require(resources.savedPlaces.add(name: "Latest", dimension: "minecraft:the_end", at: CGPoint(x: -90, y: 120)))
        let gate = AsyncReadGate<Void>()
        firstSource.routing.openDocument = { _ in
            await gate.read("first")
            throw CocoaError(.fileReadNoPermission)
        }
        var opened = recordOpens(of: secondSource)
        firstSource.annotations.visit(first)
        await gate.waitForRequest("first")
        secondSource.annotations.visit(latest)
        let destination = await opened.next(isolation: #isolation)
        #expect(destination == resources.documentURL(for: latest.dimension))
        await gate.finish("first", with: ())
        for await failure in Observations({ firstSource.routing.openFailure }) where failure != nil { break }

        let end = WorldSession(resources: resources, dimensionID: latest.dimension)
        #expect(end.map?.viewport.center == latest.mapPosition)
        #expect(firstSource.selectedDimensionID == "minecraft:overworld")
        #expect(secondSource.selectedDimensionID == "minecraft:the_nether")
        #expect(secondSource.routing.openFailure == nil)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func theOlderLayoutsOverworldIsItsRegionFolder() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.removeItem(at: url.appendingPathComponent("dimensions"))
        for folder in ["region", "DIM-1/region"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        let defaults = TestDefaults.make()

        let folders = WorldFolders(defaults: defaults)
        try folders.remember(url)
        let documents = try World(contentsOf: url).dimensions().map { $0.documentURL(inWorldAt: url) }
        #expect(documents.map(\.lastPathComponent).sorted() == ["DIM-1", "region"])
        let overworld = try await DimensionSnapshot.read(url.appendingPathComponent("region"), folders: folders)
        #expect(overworld.dimensionID == "minecraft:overworld")
        overworld.discardUnused()
    }

    @Test func aDimensionDocumentReadsItsWorldThroughTheRememberedFolder() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)

        let defaults = TestDefaults.make()

        let folders = WorldFolders(defaults: defaults)
        let nether = url.appendingPathComponent("DIM-1")
        await #expect(throws: WorldOpenError.needsWorldFolder) { try await DimensionSnapshot.read(nether, folders: folders) }
        try folders.remember(url)
        try folders.remember(url) // remembering again keeps one bookmark
        #expect((defaults.array(forKey: "worldFolderBookmarks") ?? []).count == 1)
        let snapshot = try await DimensionSnapshot.read(nether, folders: folders)
        guard case .snapshot(let world) = snapshot.source else { Issue.record("A fresh read reused an opening"); return }
        #expect(snapshot.dimensionID == "minecraft:the_nether" && world.world.level.name == "Test")
        let overworld = try await DimensionSnapshot.read(url.appendingPathComponent("dimensions/minecraft/overworld"), folders: folders)
        #expect(overworld.dimensionID == "minecraft:overworld")
        await #expect(throws: WorldOpenError.notADimension) {
            try await DimensionSnapshot.read(url.appendingPathComponent("dimensions"), folders: folders)
        }

        // Dimensions of one open world share its resources until the last one closes.
        let model = AppModel(defaults: defaults, cacheRoot: nil)
        let view = try snapshot.makeSession(in: model)
        let other = try overworld.makeSession(in: model)
        let first = view.resources
        #expect(other.resources === first)
        view.close()
        other.close()
        await view.waitUntilClosed()
        await other.waitUntilClosed()
        let again = try await DimensionSnapshot.read(nether, folders: folders)
        let next = try again.makeSession(in: model)
        let second = next.resources
        #expect(second !== first)
        next.close()
        await second.waitUntilClosed()
    }

    @Test func openingAnUnrecognizedFolderAsksForAWorldInsteadOfDiagnosingADimension() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
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
        let defaults = TestDefaults.make()
        let reader = WorldDocument.Reader(folders: WorldFolders(defaults: defaults))
        await #expect(throws: WorldOpenError.unreadable) { try await reader.readFolder(url) }
        #expect(defaults.array(forKey: "worldFolderBookmarks") == nil)
    }

    @Test func theFolderReaderRemembersAWorldAndReadsItsDimensionDocuments() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let folders = WorldFolders(defaults: TestDefaults.make())
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
            defer { snapshot.discardUnused() }
            guard case .snapshot(let world) = snapshot.source else {
                Issue.record("A reader without an AppModel should own its opening snapshot")
                continue
            }
            #expect(world.world.level.name == "Test" && snapshot.documentURL == document)
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
        #expect(nether.map?.availableRegions == [RegionPosition(x: 0, z: 0)])
        #expect(end.map?.availableRegions == [RegionPosition(x: 1, z: -1)])
        #expect(overworld.map?.availableRegions.isEmpty == true)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func savesDuringPlayDoNotPostponeTheRefresh() async throws {
        let url = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: url) }
        for dimension in ["DIM-1", "DIM1"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(dimension + "/region"), withIntermediateDirectories: true)
        }
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       watchWorld: { _, _ in nil })
        defer { resources.close() }
        let delay = AsyncReadGate<Void>()
        resources.waitBeforeRefresh = { duration in
            #expect(duration == .seconds(2))
            await delay.read("refresh")
        }
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        let netherFile = url.appendingPathComponent("DIM-1/region/r.0.0.mca")
        let endFile = url.appendingPathComponent("DIM1/region/r.1.-1.mca")
        try Data(count: 8192).write(to: netherFile)
        try Data(count: 8192).write(to: endFile)
        resources.worldChanged([netherFile])
        await delay.waitForRequest("refresh")
        // Later saves must join the first pending refresh, including another dimension's changes.
        resources.worldChanged([endFile])
        resources.worldChanged([netherFile, endFile])
        await delay.releaseAllAndFuture(with: ())
        await resources.waitForRefresh()
        #expect(await delay.requested == ["refresh"])
        #expect(nether.map?.availableRegions == [RegionPosition(x: 0, z: 0)])
        #expect(end.map?.availableRegions == [RegionPosition(x: 1, z: -1)])
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func closingWhileIndexingEndsTheWaitAndDropsTheQueuedPass() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let gate = AsyncReadGate<RegionFacts>()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       readRegion: { _, _ in await gate.read("region") })
        await gate.waitForRequest("region")
        let waiter = Task { await resources.index.waitForIndex() }
        resources.index.rebuild(firstDimension: nil)   // queued behind the running pass
        resources.close()
        await gate.finish("region", with: try TestWorld.facts())
        await waiter.value                              // ends instead of waiting forever
        await resources.waitUntilClosed()
        #expect(await gate.requested == ["region"])     // the queued pass never ran
    }

    @Test func anOlderPlayerReadCannotOverwriteANewerOne() async throws {
        let (url, resources) = try await makeResources()
        defer { resources.close(); try? FileManager.default.removeItem(at: url) }
        let session = WorldSession(resources: resources)
        let originalPlayers = resources.playerSnapshot
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
        #expect(resources.playerSnapshot !== originalPlayers)
        #expect(session.search.playerSnapshot === resources.playerSnapshot)
        #expect(session.search.players.first?.position?.x == 200)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func focusedDocumentsSetPriorityAndInactiveSavesKeepTheFrontDimension() async throws {
        let defaults = TestDefaults.make()
        let (url, resources) = try await makeResources(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: url) }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        overworld.map?.viewport = MapViewport(center: CGPoint(x: 120, y: 240), scale: 2)
        nether.map?.viewport = MapViewport(center: CGPoint(x: 15, y: 30), scale: 4)
        nether.becameActive()
        #expect(resources.activeDimensionID == "minecraft:the_nether")
        #expect(resources.settings.lastDimension == "minecraft:the_nether")
        overworld.becameActive(isTerminating: true)
        #expect(resources.activeDimensionID == "minecraft:the_nether")
        #expect(resources.settings.lastDimension == "minecraft:the_nether")
        overworld.saveView()
        #expect(resources.settings.lastDimension == "minecraft:the_nether")
        #expect(resources.settings.viewport(for: "minecraft:overworld") == overworld.map?.viewport)
        overworld.close()
        await overworld.waitUntilClosed()
        overworld.becameActive() // a late focus update for a closed document is ignored
        #expect(resources.activeDimensionID == "minecraft:the_nether")
        end.becameActive()
        #expect(resources.settings.lastDimension == "minecraft:the_end")
        nether.saveView()
        resources.close()
        await resources.waitUntilClosed()
        nether.becameActive()
        #expect(resources.settings.lastDimension == "minecraft:the_end")
        let reopened = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: resources.names,
                                      savedSearches: resources.savedSearches, defaults: defaults, cacheRoot: nil)
        #expect(reopened.defaultDimensionID == "minecraft:the_end")
        #expect(reopened.activeDimensionID == "minecraft:the_end")
        reopened.close()
        await reopened.waitUntilClosed()
    }

    @Test func focusKeepsEachWorldsRememberedSelectionIndependent() async throws {
        let defaults = TestDefaults.make()
        let (a, first) = try await makeResources(defaults: defaults)
        let (b, second) = try await makeResources(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let one = WorldSession(resources: first, dimensionID: "minecraft:the_nether")
        let two = WorldSession(resources: second, dimensionID: "minecraft:the_end")
        one.becameActive()
        two.becameActive()
        #expect(first.settings.lastDimension == "minecraft:the_nether")
        #expect(second.settings.lastDimension == "minecraft:the_end")
        #expect(first.activeDimensionID == "minecraft:the_nether" && second.activeDimensionID == "minecraft:the_end")
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed()
    }
}

/// Numbers calls in the order they arrive.
private actor ReadCounter {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
}
