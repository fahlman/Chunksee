import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import Chunksee

@Suite struct RegionRefreshTests {
    private let overworld = "minecraft:overworld"

    private func terrain(_ x: Int, count: Int32 = 1) throws -> TestWorld.ChunkSpec {
        var spec = TestWorld.chunk(x: x, z: 0, palette: ["minecraft:stone", "minecraft:diamond_ore"]) { bx, y, z in
            y == 3 && z == 0 && bx < Int(count) ? 1 : 0
        }
        var root = try #require(spec.nbt.compound)
        root["InhabitedTime"] = .long(2400)
        let blockX = Int32(x * 16)
        root["block_entities"] = .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(blockX), "y": .int(64), "z": .int(0),
                       "Items": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(count)])])]),
            .compound(["id": .string("minecraft:sign"), "x": .int(blockX), "y": .int(65), "z": .int(0),
                       "front_text": .compound(["messages": .list([.string("region \(x) version \(count)")])])]),
            .compound(["id": .string("minecraft:mob_spawner"), "x": .int(blockX), "y": .int(66), "z": .int(0),
                       "SpawnData": .compound(["entity": .compound(["id": .string(count == 1 ? "minecraft:zombie" : "minecraft:skeleton")])])]),
        ])
        root["structures"] = .compound(["starts": .compound(["minecraft:stronghold": .compound([
            "id": .string("minecraft:stronghold"), "ChunkX": .int(Int32(x)), "ChunkZ": .int(0),
            "Children": .list([.compound(["id": .string("minecraft:shstart"), "BB": .intArray([blockX, 64, 0, blockX + 9, 73, 9])])]),
        ])])])
        var sections = try #require(root["sections"]?.list)
        sections.append(.compound(["Y": .byte(-1), "biomes": .compound(["palette": .list([.string("minecraft:lush_caves")])])]))
        root["sections"] = .list(sections)
        spec.nbt = .compound(root)
        return spec
    }

    private func write(_ specs: [TestWorld.ChunkSpec], in dimension: ChunkseeKit.Dimension, folder: ChunkseeKit.Dimension.Folder, region: Int) throws -> URL {
        let directory = dimension.directory(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("r.\(region).0.mca")
        try Data(TestWorld.regionFile(specs)).write(to: file, options: .atomic)
        return file
    }

    private func entities(_ x: Int, name: String) -> TestWorld.ChunkSpec {
        .init(x: x, z: 0, nbt: .compound(["DataVersion": .int(5023), "Entities": .list([.compound([
            "id": .string("minecraft:wolf"), "UUID": .intArray([1, 2, 3, Int32(x)]),
            "Owner": .intArray([5, 6, 7, 8]), "Health": .float(8), "CustomName": .string(name),
            "Pos": .list([.double(Double(x * 16)), .double(64), .double(0)]),
        ])])]))
    }

    private func poi(_ x: Int, type: String = "minecraft:nether_portal") -> TestWorld.ChunkSpec {
        .init(x: x >> 4, z: 0, nbt: .compound(["DataVersion": .int(5023), "Sections": .compound([
            "4": .compound(["Valid": .byte(1), "Records": .list([64, 65].map { y in
                .compound(["type": .string(type), "pos": .intArray([Int32(x), Int32(y), 0]), "free_tickets": .int(0)])
            })]),
        ])]))
    }

    // These tests drive notifications explicitly. A real watcher would deliver them again after
    // its coalescing delay, making exact read counts depend on the test's speed.
    private func resources(_ url: URL, reads: Reads,
                           watchWorld: (URL, @escaping ([URL]) -> Void) -> WorldWatcher? = { _, _ in nil }) async throws -> WorldResources {
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: watchWorld,
                                       readRegion: { dimension, region in
                                           await reads.record(dimension.id, region)
                                           return await RegionData.read(dimension, region: region)
                                       })
        resources.refreshDelay = .zero
        await resources.index.waitForIndex()
        return resources
    }

    private func changed(_ files: [URL], in resources: WorldResources) async {
        resources.worldChanged(files)
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
    }

    private func matchesCompleteRead(_ resources: WorldResources, dimension: ChunkseeKit.Dimension) async throws {
        let reader = RegionReader(dimension: dimension, cache: .off)
        let complete = await DimensionIndex.read(reader, previous: nil, change: .all)
        await reader.close()
        let incremental = try #require(resources.index.index.dimensions[dimension.id])
        #expect(incremental.containers == complete.containers)
        #expect(incremental.storage == complete.storage)
        #expect(incremental.signs == complete.signs)
        #expect(incremental.structures == complete.structures)
        #expect(incremental.places == complete.places)
        #expect(incremental.creatures == complete.creatures)
        #expect(incremental.biomes == complete.biomes && incremental.caveBiomes == complete.caveBiomes)
        #expect(Set(incremental.biomeAreas.map(\.id)) == Set(complete.biomeAreas.map(\.id)))
        #expect(incremental.biomeAreas.map(\.chunkCount).sorted() == complete.biomeAreas.map(\.chunkCount).sorted())
        #expect(incremental.blocks.sorted { $0.chunk.x < $1.chunk.x } == complete.blocks.sorted { $0.chunk.x < $1.chunk.x })
        #expect(incremental.formats == complete.formats)
    }

    @Test(.timeLimit(.minutes(1))) func realFileNotificationsRefreshTheWorldWithoutInjectedChanges() async throws {
        let url = try TestWorld.make(chunks: [terrain(0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reads = Reads()
        let (events, continuation) = AsyncStream.makeStream(of: [URL].self)
        defer { continuation.finish() }
        var watching = false
        let resources = try await self.resources(url, reads: reads, watchWorld: { folder, notify in
            let watcher = WorldWatcher(folder: folder) { files in
                notify(files)
                continuation.yield(files)
            }
            watching = watcher != nil
            return watcher
        })
        defer { resources.close() }
        try #require(watching)
        #expect(resources.index.index.dimensions[overworld]?.storage.first?.count == 1)
        await reads.reset()
        let file = try write([terrain(0, count: 9)], in: dimension, folder: .terrain, region: 0)
        for await files in events {
            if files.contains(where: { $0.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }) { break }
        }
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(resources.index.index.dimensions[overworld]?.storage.first?.count == 9)
        #expect(await reads.requested.contains("\(overworld)@0,0"))
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func terrainEntitiesAndPOIReuseOtherRegionsAndPreserveWholeDimensionAggregates() async throws {
        let url = try TestWorld.make(chunks: [terrain(31), terrain(32)])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url)
        let dimension = try #require(world.dimension("overworld"))
        _ = try write([entities(-33, name: "Entity-only pet")], in: dimension, folder: .entities, region: -2)
        _ = try write([entities(31, name: "Original")], in: dimension, folder: .entities, region: 0)
        _ = try write([poi(511)], in: dimension, folder: .pointsOfInterest, region: 0)
        _ = try write([poi(512)], in: dimension, folder: .pointsOfInterest, region: 1)
        _ = try write([poi(1536, type: "minecraft:meeting")], in: dimension, folder: .pointsOfInterest, region: 3)
        let netherURL = url.appendingPathComponent("dimensions/minecraft/the_nether/poi")
        try FileManager.default.createDirectory(at: netherURL, withIntermediateDirectories: true)
        let nether = try #require(World(contentsOf: url).dimension("the_nether"))
        _ = try write([poi(64)], in: nether, folder: .pointsOfInterest, region: 0)
        let reads = Reads(), resources = try await self.resources(url, reads: reads)
        let initial = try #require(resources.index.index.dimensions[overworld])
        #expect(initial.storage.first?.count == 2)
        #expect(initial.creatures.count == 2) // includes the negative entity-only region
        #expect(initial.places.contains { $0.group == .bell }) // includes a POI-only region
        #expect(initial.biomeAreas.filter { $0.chunkCount == 2 }.count == 2) // surface and cave join across x=512
        let portal = try #require(initial.places.first { $0.group == .portal }?.portal)
        #expect(portal.blocks.count == 4)
        #expect(PortalLinkStatus.status(of: portal, portals: resources.index.portals) == .linked)
        await reads.reset()
        let terrainFile = try write([terrain(32, count: 9)], in: dimension, folder: .terrain, region: 1)
        await changed([terrainFile], in: resources)
        #expect(await reads.requested == ["\(overworld)@1,0"])
        let updated = try #require(resources.index.index.dimensions[overworld])
        #expect(updated.storage.first?.count == 10)
        #expect(updated.places.contains { $0.mob == "minecraft:skeleton" })
        #expect(updated.signs.contains { $0.front.contains("region 32 version 9") })
        #expect(updated.formats.readable == 2 && updated.structures.count == 2)
        try await matchesCompleteRead(resources, dimension: dimension)
        await reads.reset()
        let entityFile = try write([entities(31, name: "Updated")], in: dimension, folder: .entities, region: 0)
        await changed([entityFile], in: resources)
        #expect(await reads.requested == ["\(overworld)@0,0"])
        #expect(resources.index.index.dimensions[overworld]?.creatures.contains { $0.name == "Updated" } == true)
        try await matchesCompleteRead(resources, dimension: dimension)
        await reads.reset()
        let poiFile = try write([poi(512, type: "minecraft:home")], in: dimension, folder: .pointsOfInterest, region: 1)
        await changed([poiFile], in: resources)
        #expect(await reads.requested == ["\(overworld)@1,0"])
        #expect(resources.index.portals[overworld]?.first?.blocks.count == 2)
        #expect(resources.index.index.dimensions[overworld]?.places.contains { $0.group == .bed && $0.isClaimed } == true)
        #expect(resources.index.portals[nether.id]?.count == 1)
        try await matchesCompleteRead(resources, dimension: dimension)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func addedDeletedAndBroadDirectoryRegionsReconcileIndexAndMap() async throws {
        let url = try TestWorld.make(chunks: [terrain(0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reads = Reads(), resources = try await self.resources(url, reads: reads)
        let session = WorldSession(resources: resources, dimensionID: overworld)
        await reads.reset()
        let file = try write([terrain(32, count: 3)], in: dimension, folder: .terrain, region: 1)
        await changed([file], in: resources)
        #expect(await reads.requested == ["\(overworld)@1,0"])
        #expect(session.map?.availableRegions.count == 2)
        #expect(resources.index.index.dimensions[overworld]?.storage.first?.count == 4)
        try await matchesCompleteRead(resources, dimension: dimension)
        await reads.reset()
        try FileManager.default.removeItem(at: file)
        await changed([file], in: resources)
        #expect(await reads.requested.isEmpty)
        #expect(resources.index.index.dimensions[overworld]?.formats.readable == 1)
        #expect(session.map?.availableRegions == [RegionCoordinate(x: 0, z: 0)])
        try await matchesCompleteRead(resources, dimension: dimension)
        let broadFile = try write([terrain(-32, count: 4)], in: dimension, folder: .terrain, region: -1)
        await changed([dimension.regionDirectory], in: resources)
        #expect(session.map?.availableRegions == [RegionCoordinate(x: -1, z: 0), RegionCoordinate(x: 0, z: 0)])
        try await matchesCompleteRead(resources, dimension: dimension)
        try FileManager.default.removeItem(at: broadFile)
        await changed([url], in: resources)
        #expect(session.map?.availableRegions == [RegionCoordinate(x: 0, z: 0)])
        try await matchesCompleteRead(resources, dimension: dimension)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(arguments: [false, true]) func savedDataEventsKeepIndexTerrainAndHeatImages(legacy: Bool) async throws {
        let url = try TestWorld.make(chunks: [terrain(0), terrain(32)])
        defer { try? FileManager.default.removeItem(at: url) }
        if legacy {
            try FileManager.default.moveItem(at: url.appendingPathComponent("dimensions/minecraft/overworld/region"),
                                             to: url.appendingPathComponent("region"))
            try FileManager.default.removeItem(at: url.appendingPathComponent("dimensions"))
        }
        let reads = Reads(), resources = try await self.resources(url, reads: reads)
        let dimension = try #require(resources.dimensions.first { $0.id == overworld })
        let session = WorldSession(resources: resources, dimensionID: overworld)
        let map = try #require(session.map)
        map.viewport.center = CGPoint(x: 512, y: 8)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 300), displayScale: 1)
        await map.waitUntilIdle()
        session.heatMap.isShown = true
        await session.heatMap.waitForReads()
        let regions = [RegionCoordinate(x: 0, z: 0), RegionCoordinate(x: 1, z: 0)]
        let tiles = try regions.map { try #require(map.tiles[$0]) }
        let heat = try regions.map { try #require(session.heatMap.visibleImages?[$0]) }
        for relative in ["data/minecraft/raids.dat", "data/minecraft/chunk_tickets.dat",
                         "data/minecraft/ender_dragon_fight.dat", "data",
                         "region/r.0.0.mca.tmp", "region/notes.txt"] {
            await reads.reset()
            await changed([dimension.url.appendingPathComponent(relative)], in: resources)
            await map.waitUntilIdle()
            await session.heatMap.waitForReads()
            #expect(await reads.requested.isEmpty, "Unconsumed file: \(relative)")
            for (i, region) in regions.enumerated() {
                #expect(map.tiles[region] === tiles[i], "Terrain retained after \(relative)")
                #expect(session.heatMap.visibleImages?[region] === heat[i], "Time Spent retained after \(relative)")
            }
        }
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(arguments: [false, true]) func mixedSavedDataAndTerrainEventsKeepOtherRegions(dataFirst: Bool) async throws {
        let url = try TestWorld.make(chunks: [terrain(0), terrain(32)])
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = Reads(), resources = try await self.resources(url, reads: reads)
        let dimension = try #require(resources.dimensions.first { $0.id == overworld })
        let session = WorldSession(resources: resources, dimensionID: overworld)
        let map = try #require(session.map)
        map.viewport.center = CGPoint(x: 512, y: 8)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 300), displayScale: 1)
        await map.waitUntilIdle()
        let unchanged = RegionCoordinate(x: 0, z: 0), changedRegion = RegionCoordinate(x: 1, z: 0)
        let firstTile = try #require(map.tiles[unchanged]), secondTile = try #require(map.tiles[changedRegion])
        let file = try write([terrain(32, count: 5)], in: dimension, folder: .terrain, region: 1)
        let data = dimension.url.appendingPathComponent("data/minecraft/raids.dat")
        await reads.reset()
        await changed(dataFirst ? [data, file] : [file, data], in: resources)
        await map.waitUntilIdle()
        #expect(await reads.requested == ["\(overworld)@1,0"])
        #expect(map.tiles[unchanged] === firstTile)
        #expect(map.tiles[changedRegion] !== secondTile)
        #expect(resources.index.index.dimensions[overworld]?.storage.first?.count == 6)
        try await matchesCompleteRead(resources, dimension: dimension)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(arguments: ["world", "dimension", "region", "entities", "poi"])
    func exactDirectoryEventsStillReconcileIndexTerrainAndHeat(directory: String) async throws {
        let url = try TestWorld.make(chunks: [terrain(0), terrain(32)])
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = Reads(), resources = try await self.resources(url, reads: reads)
        let dimension = try #require(resources.dimensions.first { $0.id == overworld })
        let session = WorldSession(resources: resources, dimensionID: overworld)
        let map = try #require(session.map)
        map.viewport.center = CGPoint(x: 512, y: 8)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 300), displayScale: 1)
        await map.waitUntilIdle()
        session.heatMap.isShown = true
        await session.heatMap.waitForReads()
        let region = RegionCoordinate(x: 0, z: 0)
        let tile = try #require(map.tiles[region]), heat = try #require(session.heatMap.visibleImages?[region])
        let event = directory == "world" ? url : directory == "dimension" ? dimension.url : dimension.url.appendingPathComponent(directory)
        await reads.reset()
        await changed([event], in: resources)
        await map.waitUntilIdle()
        await session.heatMap.waitForReads()
        #expect(Set(await reads.requested) == ["\(overworld)@0,0", "\(overworld)@1,0"])
        #expect(map.tiles[region] !== tile)
        #expect(session.heatMap.visibleImages?[region] !== heat)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func queuedRegionsMergeAndBroadChangesDominate(broad: Bool) async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let gate = AsyncReadGate<DimensionIndex>(), requests = Changes()
        let index = WorldIndexStore(readers: [RegionReader(dimension: dimension, cache: .off)], firstDimension: nil,
                                    readDimension: { _, _, change in
                                        let key = await requests.record(change)
                                        return await gate.read(key)
                                    })
        await gate.waitForRequest("0")
        let a = RegionCoordinate(x: -1, z: 0), b = RegionCoordinate(x: 2, z: 3)
        index.rebuild(firstDimension: nil, changes: [overworld: .regions([a])])
        if broad { index.rebuild(firstDimension: nil, changes: [overworld: .all]) }
        index.rebuild(firstDimension: nil, changes: [overworld: .regions([b])])
        await gate.finish("0", with: DimensionIndex())
        await gate.waitForRequest("1")
        #expect(await requests.values == [.all, broad ? .all : .regions([a, b])])
        await gate.finish("1", with: DimensionIndex())
        await index.waitForIndex()
        index.cancel()
        await index.waitForTasks()
    }

    private actor Reads {
        private(set) var requested: [String] = []
        func record(_ dimension: String, _ region: RegionCoordinate) { requested.append("\(dimension)@\(region.x),\(region.z)") }
        func reset() { requested = [] }
    }

    private actor Changes {
        private(set) var values: [RegionChange] = []
        func record(_ change: RegionChange) -> String { values.append(change); return String(values.count - 1) }
    }
}
