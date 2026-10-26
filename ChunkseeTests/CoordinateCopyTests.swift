import ChunkseeKitTestSupport
import ChunkseeIndex
import AppKit
import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized) struct CoordinateCopyTests {
    private let size = CGSize(width: 400, height: 300)

    private func world(roof: Bool = false, dimensionSettings: [String: NBT] = [:]) throws -> URL {
        try TestWorld.make(chunks: [TestWorld.chunk(x: -1, z: -1,
            palette: ["minecraft:air", "minecraft:stone", "minecraft:bedrock"]) { _, y, _ in
            roof && y >= 14 ? 2 : y <= 2 ? 1 : 0
        }], dimensionSettings: dimensionSettings)
    }

    private func map(_ url: URL, dimensionID: String = "overworld",
                     read: MapModel.TopBlockReader? = nil) throws -> MapModel {
        let world = try World(contentsOf: url)
        let dimension = try #require(world.dimension(dimensionID))
        let context = MapSurfaceContext(settings: WorldDetails.read(world).dimensionSettings[dimension.id])
        if let read { return MapModel(work: BackgroundWork(), dimension: dimension, center: .zero,
                                     cacheDirectory: nil, surfaceContext: context, readTopBlocks: read) }
        return MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, cacheDirectory: nil, surfaceContext: context)
    }

    private func board() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.setString("previous clipboard", forType: .string)
        return board
    }

    private func result(_ url: URL, y: Int) throws -> MapModel.TopBlockRead {
        let file = try RegionFile(contentsOf: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.-1.-1.mca"))
        return (file, Array(repeating: .init(id: "minecraft:stone", y: y, waterDepth: 0), count: 256))
    }

    @Test func everyMarkerCopiesItsSavedXYZThroughTheNativeAction() throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let map = try map(url)
        defer { map.close() }
        let board = board()
        defer { board.releaseGlobally() }
        var examples: [(MapContent, CGPoint, String)] = []
        var content = MapContent()
        let pet = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: -3.093, y: 64.9, z: 0.3,
                                                       owner: UUID()), dimension: "minecraft:overworld"))
        content.creatures = [pet]
        examples.append((content, pet.position, "-4 64 0"))
        content = MapContent()
        let place = PlaceMarker(Spawner(x: -7, y: -23, z: 4, mob: "minecraft:zombie"))
        content.places = [place]
        examples.append((content, place.position, "-7 -23 4"))
        content = MapContent()
        let portal = PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: -8, y: -30, z: -2)]))
        content.places = [portal]
        examples.append((content, portal.position, "-8 -30 -2"))
        content = MapContent()
        let hit = SearchHit(id: "chest", source: .container(kind: "minecraft:chest"), dimension: "minecraft:overworld",
                            position: CGPoint(x: -20.2, y: -30.8), y: -32, title: "Chest", detail: "", count: 1)
        content.hits = [hit]
        examples.append((content, try #require(hit.position), "-21 -32 -31"))
        content = MapContent()
        let structure = StructureMarker(StructureTests().start("minecraft:mineshaft", chunk: (-1, -1),
                                      pieces: [("piece", [-10, -60, -20, -1, -41, -11])]))
        content.structures = [structure]
        examples.append((content, structure.position, "-5 -50 -15"))
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(-13.2), .double(77.8), .double(2.9)]),
            "LastDeathLocation": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([11, -14, -12])]),
            "respawn": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([20, 92, 25])]),
        ]))
        for marker in PlayerPresentation.markers(for: [player], in: "minecraft:overworld", singleplayerUUID: nil, worldDataVersion: 5023) {
            content = MapContent(); content.players = [marker]
            let expected: String
            switch marker.kind {
            case .player: expected = "-14 77 2"
            case .death: expected = "11 -14 -12"
            case .respawn: expected = "20 92 25"
            }
            examples.append((content, marker.position, expected))
        }
        #expect(examples.count == 8)
        for (content, position, expected) in examples {
            let viewport = MapViewport(center: position, scale: 8)
            // An offset click on the badge must copy the marker, not the pointer's block.
            let hit = try #require(content.hit(at: CGPoint(x: 204, y: 150), viewport: viewport, size: size))
            let menu = MapContextMenu.make {
                Button("Copy Coordinates") { MapClipboard.copy(hit.position, y: hit.y, on: map, to: board) }
            }
            menu.update()
            _ = try #require(menu.item(at: 0))
            menu.performActionForItem(at: 0)
            #expect(board.string(forType: .string) == expected)
            let copied = try #require(board.string(forType: .string))
            let destination = try #require(MapCoordinates(text: copied))
            #expect(destination.position == MapCoordinates(point: hit.position)?.position)
            #expect(destination.y == hit.y.flatMap(Coordinates.block))
            #expect(map.unfinishedCoordinateReads == 0)
        }
    }

    @Test func activeAndSavedLayerSearchPinsKeepTheirMarkersHeight() async throws {
        var chunk = TestWorld.chunk(x: -1, z: -1, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= 2 ? 1 : 0 }
        var data = try #require(chunk.nbt.compound)
        data["structures"] = .compound(["starts": .compound(["minecraft:mineshaft": .compound([
            "id": .string("minecraft:mineshaft"), "ChunkX": .int(-1), "ChunkZ": .int(-1),
            "Children": .list([.compound(["id": .string("piece"), "BB": .intArray([-14, -60, -14, -11, -41, -11])])]),
        ])])])
        data["block_entities"] = .list([.compound([
            "id": .string("minecraft:mob_spawner"), "x": .int(-3), "y": .int(-23), "z": .int(-3),
            "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])]),
        ])])
        chunk.nbt = .compound(data)
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let entities = url.appendingPathComponent("dimensions/minecraft/overworld/entities")
        try FileManager.default.createDirectory(at: entities, withIntermediateDirectories: true)
        let pets = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([-1, -1]), "Entities": .list([
            Fixtures.mob(["id": .string("minecraft:wolf"), "Health": .float(20), "Owner": .intArray([1, 2, 3, 4]),
                       "Pos": .list([.double(-8.7), .double(-12.3), .double(-5.2)])]),
            Fixtures.mob(["id": .string("minecraft:villager"), "Health": .float(20),
                       "VillagerData": .compound(["profession": .string("minecraft:farmer")]),
                       "Pos": .list([.double(-3.7), .double(-22.3), .double(-13.2)])]),
        ])])
        try Data(TestWorld.regionFile([.init(x: -1, z: -1, nbt: pets)])).write(to: entities.appendingPathComponent("r.-1.-1.mca"))
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let map = try #require(session.map)
        session.visibility.creatures = [.pet, .villager]
        session.visibility.places = [.spawner]
        session.visibility.structures = [.mineshaft]
        let board = board()
        defer { board.releaseGlobally() }
        let examples: [(String, String, Bool)] = [
            ("pet:", "-9 -13 -6", true), ("creature:wolf", "-9 -13 -6", true),
            ("villager:", "-4 -23 -14", true), ("place:", "-3 -23 -3", true),
            ("structure:", "-12 -50 -12", true), ("biome:plains", "-8 2 -8", false),
        ]
        for (query, expected, hasSavedHeight) in examples {
            session.search.text = query
            await session.search.waitForSearch()
            for saved in [false, true] {
                if saved {
                    session.search.saveSearch()
                    session.search.text = ""
                    await session.search.waitForSearch()
                }
                let content = MapContent(session: session)
                #expect(content.hits.count == 1)
                let pin = try #require(content.hits.first)
                let position = try #require(pin.position)
                let viewport = MapViewport(center: position, scale: 8)
                let hit = try #require(content.hit(at: CGPoint(x: 204, y: 150), viewport: viewport, size: size))
                #expect(hit.target == .searchHit(pin.id))  // the pin must win over its underlying marker
                #expect((hit.y != nil) == hasSavedHeight)
                MapClipboard.copy(hit.position, y: hit.y, on: map, to: board)
                await map.waitForCoordinateReads()
                #expect(board.string(forType: .string) == expected)
            }
            for saved in session.savedSearches.all { session.savedSearches.remove(saved.id) }
        }
        session.close()
        await session.waitUntilClosed()
    }

    @Test func inventoryPinsCopyTheSameNegativeBlockAsThePlayer() throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let map = try map(url)
        defer { map.close() }
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(-8.7), .double(-12.3), .double(-5.2)]),
            "Inventory": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(1), "Slot": .byte(0)])]),
        ]))
        let board = board()
        defer { board.releaseGlobally() }
        var content = MapContent()
        content.players = PlayerPresentation.markers(for: [player], in: "minecraft:overworld", singleplayerUUID: nil, worldDataVersion: 5023)
        let viewport = MapViewport(center: CGPoint(x: -8.7, y: -5.2), scale: 8)
        let playerHit = try #require(content.hit(at: CGPoint(x: 200, y: 150), viewport: viewport, size: size))
        MapClipboard.copy(playerHit.position, y: playerHit.y, on: map, to: board)
        #expect(board.string(forType: .string) == "-9 -13 -6")
        content.players = []   // a hidden player leaves the inventory pin as the copy target
        content.hits = WorldSearch.search("diamond", in: SearchIndex(), players: [player]) { _ in .named("Player") }
        let pin = try #require(content.hits.first)
        #expect(pin.source == .inventory(player.uuid))
        let hit = try #require(content.hit(at: CGPoint(x: 200, y: 150), viewport: viewport, size: size))
        #expect(hit.target == .searchHit(pin.id))
        MapClipboard.copy(hit.position, y: hit.y, on: map, to: board)
        #expect(board.string(forType: .string) == "-9 -13 -6")
        #expect(map.unfinishedCoordinateReads == 0)
    }

    @Test func anUnhoveredBlockUsesTheDisplayedHeightAndNegativeContainingBlock() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let map = try map(url)
        defer { map.close() }
        let board = board()
        defer { board.releaseGlobally() }
        MapClipboard.copy(CGPoint(x: -0.2, y: -0.7), on: map, to: board)
        await map.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "-1 2 -1")
    }

    @Test func theNetherUsesTheDisplayedFloorBelowItsRoof() async throws {
        let url = try world(roof: true, dimensionSettings: [
            "minecraft:overworld": TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld")),
            "minecraft:the_nether": TestWorld.noiseDimension(type: .string("minecraft:the_nether"), noise: .string("minecraft:nether")),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let nether = url.appendingPathComponent("DIM-1/region")
        try FileManager.default.createDirectory(at: nether, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.-1.-1.mca"),
                                        to: nether.appendingPathComponent("r.-1.-1.mca"))
        let surface = try map(url), underground = try map(url, dimensionID: "the_nether")
        defer { surface.close(); underground.close() }
        let board = board()
        defer { board.releaseGlobally() }
        MapClipboard.copy(CGPoint(x: -1, y: -1), on: surface, to: board)
        await surface.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "-1 15 -1")
        MapClipboard.copy(CGPoint(x: -1, y: -1), on: underground, to: board)
        await underground.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "-1 2 -1")
    }

    @Test func twoWindowsKeepTheNewerCopyAndItsOriginalPoint() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let first = try map(url) { _, _, _ in await gate.read("first") }
        let second = try map(url) { _, _, _ in await gate.read("second") }
        defer { first.close(); second.close() }
        let board = board()
        defer { board.releaseGlobally() }
        MapClipboard.copy(CGPoint(x: 1.25, y: 2.5), on: first, to: board)
        await gate.waitForRequest("first")
        MapClipboard.copy(CGPoint(x: -3.25, y: 4.5), on: second, to: board)
        await gate.waitForRequest("second")
        first.viewport.center = CGPoint(x: 20_000, y: 30_000)
        second.viewport.center = CGPoint(x: -20_000, y: -30_000)
        await gate.finish("first", with: try result(url, y: 41))
        await first.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "previous clipboard")
        await gate.finish("second", with: try result(url, y: 82))
        await second.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "-4 82 4")
    }

    @Test func aLateReadCannotReplaceANewerMarkerCopyOrAnotherClipboardChange() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        for externalChange in [false, true] {
            let gate = AsyncReadGate<MapModel.TopBlockRead?>()
            let map = try map(url) { _, _, _ in await gate.read("read") }
            defer { map.close() }
            let board = board()
            defer { board.releaseGlobally() }
            MapClipboard.copy(CGPoint(x: 1, y: 2), on: map, to: board)
            await gate.waitForRequest("read")
            let expected: String
            if externalChange {
                board.clearContents(); board.setString("another app's copy", forType: .string)
                expected = "another app's copy"
            } else {
                MapClipboard.copy(CGPoint(x: -9, y: 3), y: 64, on: map, to: board)
                expected = "-9 64 3"
            }
            await gate.finish("read", with: try result(url, y: 7))
            await map.waitForCoordinateReads()
            #expect(board.string(forType: .string) == expected)
        }
    }

    @Test func closingCancelsAndDrainsEveryReadWithoutChangingTheClipboard() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = try map(url) { chunk, _, _ in await gate.read("\(chunk.x)") }
        let board = board()
        defer { board.releaseGlobally() }
        MapClipboard.copy(.zero, on: map, to: board)
        await gate.waitForRequest("0")
        MapClipboard.copy(CGPoint(x: 16, y: 0), on: map, to: board)
        await gate.waitForRequest("1")
        map.close()
        await gate.waitForCancellation("0"); await gate.waitForCancellation("1")
        #expect(map.unfinishedCoordinateReads == 2)
        await gate.finish("0", with: try result(url, y: 3))
        await gate.finish("1", with: try result(url, y: 4))
        await map.waitForRenders()
        #expect(map.unfinishedCoordinateReads == 0)
        #expect(board.string(forType: .string) == "previous clipboard")
    }

    @Test func cachedHoverColumnsAreReusedAndUnknownHeightNeverCopiesPartialCoordinates() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = try map(url) { _, _, _ in await gate.read("hover") }
        defer { map.close() }
        map.loadTopBlocks(at: CGPoint(x: -1, y: -1))
        await gate.waitForRequest("hover")
        await gate.finish("hover", with: try result(url, y: -10))
        await map.waitForTopBlocks()
        let board = board()
        defer { board.releaseGlobally() }
        MapClipboard.copy(CGPoint(x: -1, y: -1), on: map, to: board)
        #expect(board.string(forType: .string) == "-1 -10 -1")
        #expect(await gate.requested == ["hover"])
        let empty = try self.map(url) { _, _, _ in nil }
        defer { empty.close() }
        MapClipboard.copy(CGPoint(x: 500, y: 500), on: empty, to: board)
        await empty.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "-1 -10 -1")
    }

    @Test(arguments: [5, 8, 9, 10]) func oldStructureCachesAreRebuiltWithTheirVerticalLocation(oldVersion: Int) async throws {
        var chunk = TestWorld.chunk(x: -1, z: -1, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var data = try #require(chunk.nbt.compound)
        data["structures"] = .compound(["starts": .compound(["minecraft:mineshaft": .compound([
            "id": .string("minecraft:mineshaft"), "ChunkX": .int(-1), "ChunkZ": .int(-1),
            "Children": .list([.compound(["id": .string("piece"), "BB": .intArray([-10, -60, -20, -1, -41, -11])])]),
        ])])])
        chunk.nbt = .compound(data)
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let cache = ScanCache(directory: url.appendingPathComponent("cache")), region = RegionPosition(x: -1, z: -1)
        let fingerprint = ScanCache.fingerprint([dimension.regionDirectory.appendingPathComponent("r.-1.-1.mca"),
                                                 dimension.entitiesDirectory.appendingPathComponent("r.-1.-1.mca")])
        var old = StructureMarker(StructureTests().start("minecraft:mineshaft", chunk: (-1, -1),
                                 pieces: [("piece", [-10, -60, -20, -1, -41, -11])]))
        old.y = nil
        let previous = try TestWorld.legacyCache([old], name: "structures.-1.-1.\(fingerprint).v\(oldVersion)",
                                                directory: #require(cache.directory))
        let reader = RegionReader(dimension: dimension, cache: cache)
        let rebuilt = await TestWorld.index(reader).structures
        #expect(rebuilt.map(\.y) == [-50])
        let saved = cache.load(.init(dimension: dimension, region: region, options: RegionReader.options()))?.structures.map { StructureMarker($0) }
        #expect(saved?.first?.y == -50)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        await reader.close()
    }
}
