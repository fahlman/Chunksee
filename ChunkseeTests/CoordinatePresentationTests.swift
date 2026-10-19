import AppKit
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct CoordinatePresentationTests {
    @Test func negativeReadoutsAndAccessibleLocationsKeepTheSameSavedXYZAsCopy() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimensions().first)
        let position = CGPoint(x: -8.7, y: -16.1)
        let map = MapModel(dimension: dimension, center: position, cacheDirectory: nil)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); map.close() }
        var content = MapContent()
        content.players = [.init(id: "player", playerID: UUID(), kind: .player, position: position,
                                 y: -0.1, label: "Player", isOutdated: false)]
        let location = try #require(content.accessibleLocations(viewport: .init(center: position, scale: 32),
                                                               size: CGSize(width: 400, height: 300)).first)
        #expect(location.position == position && location.y == -0.1)
        #expect(Coordinates.text(location.position, y: location.y) == "X -9  Y -1  Z -17")
        #expect(Coordinates.text(location.position, y: location.y, dimension: "Overworld") == "Overworld · X -9  Y -1  Z -17")
        MapClipboard.copy(location.position, y: location.y, on: map, to: board)
        #expect(board.string(forType: .string) == "-9 -1 -17")
        #expect(map.unfinishedCoordinateReads == 0)
        #expect(Coordinates.text(x: -0.1, z: -16.1) == "X -1  Z -17")
        map.close()
        await map.waitForRenders()
    }

    @Test func blockMarkersUseTheirCentersForDrawingHitTestingAndAccessibility() {
        let size = CGSize(width: 400, height: 300), center = CGPoint(x: 200, y: 150)
        let block = CGPoint(x: -9, y: -17), blockCenter = CGPoint(x: -8.5, y: -16.5)
        let viewport = MapViewport(center: blockCenter, scale: 32)
        for kind in [MapMarker.Kind.death, .respawn] {
            let player = MapMarker(id: "point", playerID: UUID(), kind: kind, position: block, y: 64,
                                   label: "Location", isOutdated: false)
            var content = MapContent()
            content.players = [player]
            #expect(player.anchor == blockCenter)
            #expect(content.hit(at: center, viewport: viewport, size: size)?.target == .row(.player(player.playerID)))
            #expect(content.accessibleLocations(viewport: viewport, size: size).first?.anchor == blockCenter)
        }
        let saved = SavedPlace(name: "Base", dimension: "minecraft:overworld", x: -9, z: -17)
        var content = MapContent()
        content.savedPlaces = [saved]
        #expect(saved.position == block && saved.mapPosition == blockCenter)
        #expect(content.hit(at: center, viewport: viewport, size: size)?.target == .row(.savedPlace(saved.id)))
        #expect(content.accessibleLocations(viewport: viewport, size: size).first?.anchor == blockCenter)
    }

    @Test func upgradingTheParserDiscardsPreviouslyTruncatedContainerCoordinates() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let entity = NBT.compound(["id": .string("minecraft:chest_minecart"),
            "Pos": .list([.double(-8.7), .double(-0.1), .double(-16.1)]),
            "Items": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(1)])])])
        let nbt = NBT.compound(["DataVersion": .int(5023), "Entities": .list([entity])])
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        let file = dimension.entitiesDirectory.appendingPathComponent("r.-1.-1.mca")
        try Data(TestWorld.regionFile([.init(x: -1, z: -2, nbt: nbt)])).write(to: file)
        let cache = ScanCache(directory: url.appendingPathComponent("cache"))
        let fingerprint = ScanCache.fingerprint([dimension.regionDirectory.appendingPathComponent("r.-1.-1.mca"), file])
        var oldContainer = try #require(ItemContainer.containers(inEntityChunk: nbt).first)
        oldContainer.x = -8; oldContainer.y = 0; oldContainer.z = -16
        let oldFile = try #require(cache.directory).appendingPathComponent("contents.-1.-1.\(fingerprint).v12")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(SearchContents(containers: [oldContainer]))
        try ((data as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)
        let reader = RegionReader(dimension: dimension, cache: cache)
        let contents = await reader.contents(RegionCoordinate(x: -1, z: -1))
        await reader.close()
        let container = try #require(contents.containers.first)
        #expect(container.x == -9 && container.y == -1 && container.z == -17)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        let saved: SearchContents? = cache.load("contents", region: RegionCoordinate(x: -1, z: -1), fingerprint: fingerprint)
        #expect(saved?.containers == contents.containers)
    }

    @Test(arguments: ["nan", "infinity", "negative infinity", "out of range"])
    func malformedSavedPositionsStayUnmappableThroughTheRealSearchPath(_ value: String) async throws {
        let invalid: Double = switch value {
        case "nan": .nan
        case "infinity": .infinity
        case "negative infinity": -.infinity
        default: .greatestFiniteMagnitude
        }
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url)
        let dimension = try #require(world.dimensions().first)
        try FileManager.default.createDirectory(at: world.playerDataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        let diamond = NBT.compound(["id": .string("minecraft:diamond"), "count": .int(1), "Slot": .byte(0)])
        func entity(_ pos: [Double], named name: String, villager: Bool) -> NBT {
            var fields: [String: NBT] = ["id": .string(villager ? "minecraft:villager" : "minecraft:wolf"), "Health": .float(20),
                                       "Pos": .list(pos.map(NBT.double)), "CustomName": .string(name)]
            if villager {
                fields["VillagerData"] = .compound(["profession": .string("minecraft:farmer"), "level": .int(1)])
                fields["Offers"] = .compound(["Recipes": .list([.compound([
                    "buy": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
                    "sell": .compound(["id": .string("minecraft:carrot"), "count": .int(1)]),
                    "uses": .int(0), "maxUses": .int(12),
                ])])])
            } else {
                fields["Owner"] = .intArray([1, 2, 3, 4])
            }
            return .compound(fields)
        }
        var entities: [NBT] = []
        for axis in 0..<4 {
            var pos: [Double] = [-8.7, -0.1, -16.1]
            if axis < 3 { pos[axis] = invalid }
            let player = NBT.compound(["Dimension": .string("minecraft:overworld"), "Pos": .list(pos.map(NBT.double)),
                                       "Inventory": .list([diamond])])
            try Data(Compression.deflate(player.serialized(), gzip: true))
                .write(to: world.playerDataDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).dat"))
            entities.append(.compound(["id": .string("minecraft:chest_minecart"), "Pos": .list(pos.map(NBT.double)),
                "Items": .list([.compound(["id": .string("minecraft:gold_ingot"), "count": .int(1)])])]))
            for villager in [false, true] {
                entities.append(entity(pos, named: axis < 3 ? "Broken" : "Valid", villager: villager))
            }
        }
        let nbt = NBT.compound(["DataVersion": .int(5023), "Entities": .list(entities)])
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: nbt)]))
            .write(to: dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca"))
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        await session.search.waitForIndex()
        #expect(session.selectedIndex.creatures.count == 2)
        for (query, count) in [("creature:", 2), ("pet:", 1), ("villager:", 1), ("trade:carrot", 1), ("Broken", 0)] {
            session.search.text = query
            await session.search.waitForSearch()
            #expect(session.search.results.count == count, "\(query), \(value)")
        }
        session.search.text = "gold_ingot"
        await session.search.waitForSearch()
        #expect(session.search.results.count == 1)
        #expect(session.search.results.first?.position == CGPoint(x: -8.5, y: -16.5))
        #expect(session.search.results.first?.y == -1)
        session.search.text = "diamond"
        await session.search.waitForSearch()
        let results = session.search.results
        #expect(results.count == 4)
        #expect(results.filter { $0.position == nil && $0.dimension == nil && $0.y == nil }.count == 3)
        #expect(results.contains { $0.position == CGPoint(x: -8.7, y: -16.1) && $0.y == -1 })
        for player in session.players where PlayerPresentation.position(of: player) == nil {
            let viewport = session.map?.viewport
            #expect(!session.canFocus(player))
            session.choose(.player(player.uuid))
            #expect(session.map?.viewport == viewport)
        }
        #expect(session.mapContent.players.count == 1)
        #expect(Coordinates.text(CGPoint(x: invalid, y: 0), y: 64) == "Location unknown")
        #expect(Coordinates.text(.zero, y: invalid) == "Location unknown")
        let invalidPoint = CGPoint(x: invalid, y: 0)
        #expect(session.map?.topBlock(at: invalidPoint) == nil)
        session.map?.loadTopBlocks(at: invalidPoint)
        #expect(session.map?.unfinishedHoverReads == 0)
        session.close()
        await session.waitUntilClosed()
    }
}
