import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldSourceReplacementTests {
    private final class Fixture {
        let original: URL
        let moved: URL
        let copy: URL
        let alias: URL
        let model: AppModel
        var sessions: [WorldSession] = []

        init(readRegion: @escaping RegionReader.Read = RegionReader.scan) throws {
            original = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
            moved = original.appendingPathExtension("moved")
            copy = original.appendingPathExtension("copy")
            alias = original.appendingPathExtension("alias")
            model = AppModel(defaults: TestDefaults.make(), cacheRoot: nil, readRegion: readRegion)
            try FileManager.default.createDirectory(at: document("the_nether", at: original).appendingPathComponent("region"), withIntermediateDirectories: true)
            try Self.writeMap(at: original, center: 10)
            try model.worldFolders.remember(original)
        }

        func document(_ dimension: String = "overworld", at root: URL) -> URL {
            root.appendingPathComponent("dimensions/minecraft/" + dimension)
        }

        static func writeMap(at root: URL, center: Int32) throws {
            try Fixtures.writeGzippedNBT(.compound(["data": .compound([
                "dimension": .string("minecraft:overworld"), "scale": .byte(0),
                "xCenter": .int(center), "zCenter": .int(0),
                "colors": .byteArray([Int8](repeating: 4, count: MapItem.size * MapItem.size)),
            ])]), to: root.appendingPathComponent("data/minecraft/maps/1.dat"))
        }

        func open(_ url: URL, reusing session: WorldSession? = nil, reread: Bool = false) async throws -> WorldSession {
            let reader = WorldDocument.Reader(folders: model.worldFolders, model: model, reuseOpenWorld: { !reread })
            guard case .dimension(let snapshot) = try await reader.readFolder(url) else { throw WorldOpenError.notADimension }
            let opened = try await snapshot.makeSession(in: model, reusing: session)
            if !sessions.contains(where: { $0 === opened }) { sessions.append(opened) }
            return opened
        }

        func close() async {
            sessions.forEach { $0.close() }
            for session in sessions { await session.waitUntilClosed() }
            for url in [alias, original, moved, copy] { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func withFixture(readRegion: @escaping RegionReader.Read = RegionReader.scan,
                             _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(readRegion: readRegion)
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func movedWorldKeepsOneOwnerAndEveryWindowsChoicesAndSavedPlaces() async throws {
        try await withFixture { f in
            let first = try await f.open(f.document(at: f.original))
            let second = try await f.open(f.document("the_nether", at: f.original))
            let resources = first.resources, index = resources.index, places = first.savedPlaces
            let firstMap = try #require(first.map), secondMap = try #require(second.map)
            await resources.waitForRefresh(); await resources.index.waitForIndex()
            first.selection.choose(.inGameMap(1))
            second.selection.choose(.worldInfo)
            first.selection.inGameMapOpacity = 0.3
            first.search.text = "block:minecraft:stone"
            await first.search.waitForSearch()
            firstMap.viewport = MapViewport(center: CGPoint(x: 50, y: 60), scale: 2)
            first.navigation.goToCoordinates(CGPoint(x: 100, y: 200))
            firstMap.setDepth(MapDepth(y: 20, isSurface: false))
            firstMap.setStyle(.height)
            firstMap.setCastsShadows(false)
            secondMap.setStyle(.waterDepth)
            first.annotations.ruler.isEnabled = true
            first.annotations.ruler.mark(.zero); first.annotations.ruler.mark(CGPoint(x: 3, y: 4))
            let view = firstMap.viewport, ruler = first.annotations.ruler, id = first.viewID
            let home = try #require(places.add(name: "Home", dimension: "minecraft:overworld", at: .zero))

            try FileManager.default.moveItem(at: f.original, to: f.moved)
            let reread = try await f.open(f.document(at: f.moved), reusing: first, reread: true)
            await resources.waitForRefresh(); await resources.index.waitForIndex(); await first.search.waitForSearch()
            #expect(reread === first && first.viewID == id && first.map === firstMap && second.map === secondMap)
            #expect(first.resources === resources && second.resources === resources && resources.index === index)
            #expect(resources.url.resolvingSymlinksInPath() == f.moved.resolvingSymlinksInPath())
            #expect(resources.index.readers.count == 2)
            #expect(resources.dimensions.allSatisfy { $0.url.resolvingSymlinksInPath().path.hasPrefix(f.moved.resolvingSymlinksInPath().path + "/") })
            #expect(try requiredRenderer(firstMap).dimension.url == f.document(at: f.moved))
            #expect(try requiredRenderer(secondMap).dimension.url == f.document("the_nether", at: f.moved))
            #expect(firstMap.viewport == view && firstMap.depth == MapDepth(y: 20, isSurface: false))
            #expect(firstMap.chosenStyle == .height && !firstMap.castsShadows && secondMap.chosenStyle == .waterDepth)
            #expect(first.navigation.canGoBack && first.annotations.ruler == ruler)
            #expect(first.search.text == "block:minecraft:stone")
            #expect(first.selection.sidebarSelection == .inGameMap(1) && first.selection.inspector == .selection)
            #expect(first.selection.inGameMapOpacity == 0.3 && second.selection.inspector == .world)
            #expect(first.savedPlaces === places && second.savedPlaces === places)
            let away = try #require(second.savedPlaces.add(name: "Away", dimension: "minecraft:the_nether", at: CGPoint(x: 2, y: 3)))
            #expect(Set(first.savedPlaces.all.map(\.id)) == [home.id, away.id])
            first.close(); await first.waitUntilClosed()
            #expect(!resources.isClosed)
            let reopened = try await f.open(f.document(at: f.moved))
            #expect(reopened.resources === resources && reopened.savedPlaces === places)
            #expect(Set(reopened.savedPlaces.all.map(\.id)) == [home.id, away.id])
        }
    }

    @Test func aliasesShareAnOwnerAndAnOpenedCopyHasItsOwnPlaces() async throws {
        try await withFixture { f in
            let first = try await f.open(f.document(at: f.original))
            try FileManager.default.createSymbolicLink(at: f.alias, withDestinationURL: f.original)
            try f.model.worldFolders.remember(f.alias)
            let alias = try await f.open(f.document(at: f.alias))
            #expect(alias.resources === first.resources)
            try FileManager.default.copyItem(at: f.original, to: f.copy)
            try f.model.worldFolders.remember(f.copy)
            let copy = try await f.open(f.document(at: f.copy))
            #expect(copy.resources !== first.resources && copy.resources.settings.worldID != first.resources.settings.worldID)
            let place = try #require(copy.savedPlaces.add(name: "Copy", dimension: "minecraft:overworld", at: .zero))
            #expect(copy.savedPlaces.all == [place] && first.savedPlaces.all.isEmpty && alias.savedPlaces.all.isEmpty)
        }
    }

    @Test func indexedSelectionsSurviveAMoveWhileNewReadersCheckTheirFiles() async throws {
        let gate = AsyncReadGate<Bool>()
        try await withFixture(readRegion: { dimension, region, options in
            if dimension.url.path.contains(".moved/") { _ = await gate.read(dimension.id) }
            return try await RegionReader.scan(dimension, region: region, options: options)
        }) { f in
            var failure: (any Error)?
            do {
                var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
                var values = try #require(chunk.nbt.compound)
                values["block_entities"] = .list([.compound([
                    "id": .string("minecraft:mob_spawner"), "x": .int(8), "y": .int(2), "z": .int(8),
                    "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])]),
                ])])
                chunk.nbt = .compound(values)
                let relativeFile = "region/r.0.0.mca"
                try Data(TestWorld.regionFile([chunk])).write(to: f.document(at: f.original).appendingPathComponent(relativeFile))
                let first = try await f.open(f.document(at: f.original))
                let second = try await f.open(f.document(at: f.original))
                await first.search.waitForIndex()
                let place = try #require(first.presentation.selectedIndex.places.first { $0.group == .spawner })
                first.selection.choose(.place(place.id))
                second.search.text = "place:spawner"
                await second.search.waitForSearch()
                let hit = try #require(second.search.results.first)
                let selectedHit = SidebarItem.hit(query: second.search.text, id: hit.id)
                second.selection.choose(selectedHit)

                try FileManager.default.moveItem(at: f.original, to: f.moved)
                _ = try await f.open(f.document(at: f.moved), reusing: first, reread: true)
                await gate.waitForRequest("minecraft:overworld")
                await second.search.waitForSearch()
                #expect(first.selection.sidebarSelection == .place(place.id) && first.selection.inspector == .selection)
                #expect(second.selection.sidebarSelection == selectedHit && second.selection.inspector == .selection)

                await gate.releaseAllAndFuture(with: true)
                await first.search.waitForIndex(); await second.search.waitForSearch()
                #expect(first.selection.sidebarSelection == .place(place.id) && first.selection.inspector == .selection)
                #expect(second.selection.sidebarSelection == selectedHit && second.selection.inspector == .selection)

                // Retention lasts only until a successful read establishes that the item is gone.
                try Data(TestWorld.regionFile([])).write(to: f.document(at: f.moved).appendingPathComponent(relativeFile))
                _ = try await f.open(f.document(at: f.moved), reusing: first, reread: true)
                await first.search.waitForIndex(); await second.search.waitForSearch()
                #expect(first.selection.sidebarSelection == nil && first.selection.inspector == nil)
                #expect(second.selection.sidebarSelection == nil && second.selection.inspector == nil)
            } catch { failure = error }
            await gate.releaseAllAndFuture(with: true)
            if let failure { throw failure }
        }
    }

    @Test func samePathRereadReplacesSavedDataWithoutReplacingTheSession() async throws {
        try await withFixture { f in
            let session = try await f.open(f.document(at: f.original))
            let resources = session.resources, oldSource = resources.readSource
            session.selection.choose(.inGameMap(1))
            session.selection.inGameMapOpacity = 0.2
            let viewport = session.map?.viewport
            try Fixture.writeMap(at: f.original, center: 200)
            let reread = try await f.open(f.document(at: f.original), reusing: session, reread: true)
            #expect(reread === session && reread.resources === resources && resources.readSource !== oldSource)
            #expect(resources.details.maps.first?.centerX == 200)
            #expect(session.selection.sidebarSelection == .inGameMap(1) && session.selection.inspector == .selection)
            #expect(MapContent(session: session).inGameMap?.map.centerX == 200)
            #expect(session.selection.inGameMapOpacity == 0.2 && session.map?.viewport == viewport)
        }
    }

    @Test func aRemovedDimensionStopsReadingAndKeepsItsViewForReappearance() async throws {
        try await withFixture { f in
            let first = try await f.open(f.document(at: f.original))
            let netherURL = f.document("the_nether", at: f.original)
            let second = try await f.open(netherURL), map = try #require(second.map)
            map.setStyle(.waterDepth)
            map.viewport = MapViewport(center: CGPoint(x: 30, y: 60), scale: 4)
            let view = map.viewport
            try FileManager.default.removeItem(at: netherURL)
            _ = try await f.open(f.document(at: f.original), reusing: first, reread: true)
            #expect(second.map === map && map.currentRenderer == nil && map.availableRegions.isEmpty)
            #expect(!second.imageExport.canCreate && map.chosenStyle == .waterDepth && map.viewport == view)
            try FileManager.default.createDirectory(at: netherURL.appendingPathComponent("region"), withIntermediateDirectories: true)
            _ = try await f.open(f.document(at: f.original), reusing: first, reread: true)
            #expect(try second.map === map && requiredRenderer(map).dimension.url == netherURL)
            #expect(map.chosenStyle == .waterDepth && map.viewport == view)
        }
    }

    @Test func aNewerRereadRetiresAnOlderReadThatFinishesLast() async throws {
        try await withFixture { f in
            let document = f.document(at: f.original)
            let session = try await f.open(document)
            let folder = try #require(f.model.worldFolders.world(containing: document))
            let olderValue = try await WorldSnapshot.read(f.original)
            try Fixture.writeMap(at: f.original, center: 200)
            let newerValue = try await WorldSnapshot.read(f.original)
            let gate = AsyncReadGate<WorldSnapshot?>()
            var tasks: [Task<DimensionSnapshot, any Error>] = []
            var failure: (any Error)?
            do {
                let older = Task {
                    try await f.model.rereadDimension(at: document, in: folder) { _ in
                        guard let value = await gate.read("old") else { throw CancellationError() }
                        return value
                    }
                }
                tasks.append(older)
                await gate.waitForRequest("old")
                let newer = Task {
                    try await f.model.rereadDimension(at: document, in: folder) { _ in
                        guard let value = await gate.read("new") else { throw CancellationError() }
                        return value
                    }
                }
                tasks.append(newer)
                await gate.waitForRequest("new"); await gate.waitForCancellation("old")
                await gate.finish("new", with: newerValue)
                let accepted = try await newer.value
                let current = try await accepted.makeSession(in: f.model, reusing: session)
                #expect(current === session && current.resources.details.maps.first?.centerX == 200)
                await gate.finish("old", with: olderValue)
                switch await older.result {
                case .success(let retired):
                    retired.discardUnused()
                    Issue.record("The retired reread was accepted after the newer source")
                case .failure(let error): #expect(error is CancellationError)
                }
                #expect(session.resources.details.maps.first?.centerX == 200)
            } catch { failure = error }
            await gate.releaseAllAndFuture(with: nil)
            for task in tasks {
                if case .success(let value) = await task.result { value.discardUnused() }
            }
            if let failure { throw failure }
        }
    }

    @Test(arguments: [false, true])
    func retiredAccessOutlivesHeldReadsIncludingCloseDuringReplacement(closeDuringReplacement: Bool) async throws {
        try await withFixture { f in
            let session = try await f.open(f.document(at: f.original)), resources = session.resources
            await resources.waitForRefresh(); await resources.index.waitForIndex()
            weak let retiredAccess = resources.access
            let gate = AsyncReadGate<BlockState?>()
            let position = try #require(BlockPosition(x: 0, y: 0, z: 0))
            resources.readHeadingBlock = { _, _ in await gate.read("old") }
            let reading = Task { await resources.headingBlock(at: position, in: "minecraft:overworld") }
            await gate.waitForRequest("old")
            var failure: (any Error)?
            do {
                try FileManager.default.moveItem(at: f.original, to: f.moved)
                if closeDuringReplacement {
                    withObservationTracking(options: [.didSet]) { _ = resources.url } onChange: { event in
                        event.cancel()
                        MainActor.assumeIsolated { resources.close() }
                    }
                    do {
                        _ = try await f.open(f.document(at: f.moved), reusing: session, reread: true)
                        Issue.record("A closed world accepted a replacement opening")
                    } catch is CancellationError {}
                    #expect(resources.isClosed)
                } else {
                    _ = try await f.open(f.document(at: f.moved), reusing: session, reread: true)
                    #expect(resources.access !== retiredAccess)
                }
                #expect(retiredAccess != nil)
            } catch { failure = error }
            await gate.releaseAllAndFuture(with: BlockState("minecraft:stone"))
            let obsolete = await reading.value
            #expect(obsolete == nil)
            await resources.backgroundWork.waitUntilFinished()
            await resources.waitUntilClosed()
            #expect(retiredAccess == nil)
            if !resources.isClosed {
                let expected = f.document(at: f.moved).resolvingSymlinksInPath()
                resources.readHeadingBlock = { dimension, _ in
                    #expect(dimension.url.resolvingSymlinksInPath() == expected)
                    return BlockState("minecraft:dirt")
                }
                let current = await resources.headingBlock(at: position, in: "minecraft:overworld")
                #expect(current?.id == "minecraft:dirt")
            }
            if let failure { throw failure }
        }
    }
}
