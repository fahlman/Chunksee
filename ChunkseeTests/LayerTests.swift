import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import Chunksee

@Suite struct StructureTests {
    /// A structure start built the way chunks store it, read through ChunkseeKit's public API.
    func start(_ id: String, chunk: (Int, Int), pieces: [(String, [Int])] = [("piece", [0, 60, 0, 9, 70, 9])]) -> StructureStart {
        let nbt = NBT.compound(["structures": .compound(["starts": .compound([id: .compound([
            "id": .string(id), "ChunkX": .int(Int32(chunk.0)), "ChunkZ": .int(Int32(chunk.1)),
            "Children": .list(.compound, pieces.map { .compound(["id": .string($0.0), "BB": .intArray($0.1.map { Int32($0) })]) }),
        ])])])])
        return StructureStart.starts(inChunk: nbt)[0]
    }

    @Test func groupsNamesAndDefaults() {
        #expect(StructureGroup.group(for: "minecraft:village_savanna") == .village)
        #expect(StructureGroup.group(for: "minecraft:ocean_ruin_cold") == .ruins)
        #expect(StructureGroup.group(for: "minecraft:mineshaft_mesa") == .mineshaft)
        #expect(StructureGroup.group(for: "mydatapack:tower") == .other)
        #expect(!StructureGroup.mineshaft.isShownByDefault && !StructureGroup.netherFossil.isShownByDefault)
        #expect(StructureGroup.stronghold.isShownByDefault)
        let names = ["minecraft:village_plains", "minecraft:ocean_ruin_cold", "minecraft:ruined_portal_ocean",
                     "minecraft:shipwreck_beached", "minecraft:ancient_city"].map {
            StructureMarker(start($0, chunk: (0, 0))).name
        }
        #expect(names == ["Plains Village", "Cold Ocean Ruin", "Ocean Ruined Portal", "Beached Shipwreck", "Ancient City"])
    }

    @Test func boundsAndStrongholdPortalRoom() {
        let marker = StructureMarker(start("minecraft:stronghold", chunk: (-302, -51), pieces: [
            ("minecraft:shstart", [-4830, -19, -814, -4826, -9, -810]),
            ("minecraft:shpr", [-4900, -40, -830, -4890, -32, -815]),
        ]))
        #expect(marker.bounds == CGRect(x: -4900, y: -830, width: 75, height: 21))
        #expect(marker.portalRoom == CGPoint(x: -4894.5, y: -822))
    }

    @Test func scannerFindsStructuresAcrossRegions() async throws {
        func withStructure(_ spec: TestWorld.ChunkSpec, _ id: String) -> TestWorld.ChunkSpec {
            var spec = spec
            var root = spec.nbt.compound!
            root["structures"] = .compound(["References": .compound([:]), "starts": .compound([id: .compound([
                "id": .string(id), "ChunkX": .int(Int32(spec.x)), "ChunkZ": .int(Int32(spec.z)),
                "Children": .list([.compound(["id": .string("piece"),
                                              "BB": .intArray([Int32(spec.x * 16), 60, Int32(spec.z * 16), Int32(spec.x * 16 + 9), 70, Int32(spec.z * 16 + 9)])])]),
            ])])])
            spec.nbt = .compound(root)
            return spec
        }
        let stone = { (x: Int, z: Int) in TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } }
        let world = try TestWorld.make(chunks: [
            withStructure(stone(0, 0), "minecraft:village_plains"),
            withStructure(stone(40, -1), "minecraft:stronghold"),   // region (1, -1)
            stone(1, 0),
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let found = await StructureScanner.scan(RegionReader(dimension: dimension, cache: .off))
        #expect(found.map(\.structureID).sorted() == ["minecraft:stronghold", "minecraft:village_plains"])
        #expect(found.first { $0.group == .stronghold }?.bounds == CGRect(x: 640, y: -16, width: 10, height: 10))
    }

    @Test(arguments: ["Status", "status"])
    func unbuiltStructuresAreAbsentFromMarkersAndSearch(_ statusKey: String) async throws {
        let world = try TestWorld.make(chunks: StructureTestWorld.chunks(statusKey: statusKey))
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        // A placed temple remains visible even in taiga, and a stronghold has no HPos field.
        #expect(session.selectedIndex.structures.map(\.structureID).sorted() == ["minecraft:jungle_pyramid", "minecraft:stronghold"])
        #expect(session.mapContent.structures.count == 2)
        #expect(!session.selectedIndex.structures.contains { $0.position == CGPoint(x: -266, y: 71.5) })
        session.search.text = "structure: jungle pyramid"
        await session.search.waitForSearch()
        #expect(session.search.results.count == 1)
        #expect(session.search.results.first?.position == CGPoint(x: 37, y: 5))
    }
}

/// The unplaced start from the upgraded taiga chunk, alongside placed and unfinished structures.
enum StructureTestWorld {
    static func chunks(statusKey: String = "Status") -> [TestWorld.ChunkSpec] {
        func chunk(_ x: Int, _ z: Int, id: String, pieces: [NBT], finished: Bool = true) -> TestWorld.ChunkSpec {
            var spec = TestWorld.chunk(x: x, z: z, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            var root = spec.nbt.compound!
            root.removeValue(forKey: "Status")
            root[statusKey] = .string(finished ? "minecraft:full" : "minecraft:structure_starts")
            var section = root["sections"]!.list![0].compound!
            section["biomes"] = .compound(["palette": .list([.string("minecraft:taiga")])])
            root["sections"] = .list([.compound(section)])
            root["structures"] = .compound(["starts": .compound([id: .compound([
                "id": .string(id), "ChunkX": .int(Int32(x)), "ChunkZ": .int(Int32(z)), "Children": .list(pieces),
            ])])])
            spec.nbt = .compound(root)
            return spec
        }
        func piece(_ id: String, x: Int32, z: Int32, height: Int32? = nil) -> NBT {
            var fields: [String: NBT] = ["id": .string(id), "BB": .intArray([x, 64, z, x + 9, 73, z + 9])]
            if let height { fields["HPos"] = .int(height) }
            return .compound(fields)
        }
        return [
            chunk(-17, 4, id: "minecraft:jungle_pyramid", pieces: [.compound([
                "id": .string("minecraft:tejp"), "BB": .intArray([-272, 64, 64, -261, 73, 78]), "HPos": .int(-1),
                "placedMainChest": .byte(0), "placedHiddenChest": .byte(0), "placedTrap1": .byte(0), "placedTrap2": .byte(0),
            ])]),
            chunk(2, 0, id: "minecraft:jungle_pyramid", pieces: [piece("minecraft:tejp", x: 32, z: 0, height: 68)]),
            chunk(3, 0, id: "minecraft:stronghold", pieces: [piece("minecraft:shstart", x: 48, z: 0)]),
            chunk(4, 0, id: "minecraft:village_taiga", pieces: [piece("minecraft:jigsaw", x: 64, z: 0)], finished: false),
            chunk(5, 0, id: "minecraft:igloo", pieces: []),
        ]
    }
}

@Suite struct PlaceTests {
    func poi(_ type: String, _ x: Int, _ y: Int, _ z: Int, tickets: Int = 1) -> PointOfInterest {
        PointOfInterest(type: type, x: x, y: y, z: z, freeTickets: tickets)
    }

    @Test func groupsNamesAndClaims() {
        #expect(PlaceGroup.group(for: "minecraft:librarian") == .workstation)
        #expect(PlaceGroup.group(for: "minecraft:meeting") == .bell)
        #expect(PlaceGroup.group(for: "minecraft:beehive") == .beeNest)
        #expect(PlaceGroup.portal.isShownByDefault && !PlaceGroup.bed.isShownByDefault)
        #expect(PlaceMarker(poi("minecraft:librarian", 0, 64, 0)).name == "Librarian’s Workstation")
        let claimedBed = PlaceMarker(poi("minecraft:home", 0, 64, 0, tickets: 0))
        #expect(claimedBed.isClaimed && claimedBed.name == "Villager’s Bed")
        #expect(!PlaceMarker(poi("minecraft:meeting", 0, 64, 0, tickets: 0)).isClaimed)  // only beds and workstations
    }

    @Test func onePlacePerPortalFromChunkseeKitsGrouping() {
        // A 2-wide, 3-tall portal at x 10–11, plus a separate single block far away.
        let blocks = [(10, 64), (11, 64), (10, 65), (11, 65), (10, 66), (11, 66)].map { poi("minecraft:nether_portal", $0.0, $0.1, 5) }
            + [poi("minecraft:nether_portal", 200, 70, 5)]
        let places = NetherPortal.portals(from: blocks, in: "minecraft:overworld").map(PlaceMarker.init)
        #expect(places.count == 2)
        #expect(places.contains { $0.position == CGPoint(x: 11, y: 5.5) && $0.y == 64 && $0.portal?.blocks.count == 6 })
        #expect(places.allSatisfy { $0.group == .portal })
    }

    @Test func portalLinkStatuses() {
        typealias Block = NetherPortal.Block
        func frame(_ d: String, _ x: Int, _ z: Int) -> NetherPortal {
            NetherPortal(dimension: d, blocks: [0, 1].flatMap { dx in (0..<3).map { Block(x: x + dx, y: 64 + $0, z: z) } })
        }
        let a = frame("minecraft:overworld", 800, 0), b = frame("minecraft:overworld", 840, 0)  // both lead near nether x 100–105
        let n = frame("minecraft:the_nether", 100, 0)
        let lonely = frame("minecraft:overworld", 8000, 8000)
        let portals = ["minecraft:overworld": [a, b, lonely], "minecraft:the_nether": [n]]
        #expect(PortalLinkStatus.status(of: a, portals: portals) == .linked)    // n leads back to a (closer to 800)
        #expect(PortalLinkStatus.status(of: b, portals: portals) == .oneWay)    // b -> n, but n -> a
        #expect(PortalLinkStatus.status(of: lonely, portals: portals) == .noPartner)
        #expect(PortalLinkStatus.status(of: a, portals: ["minecraft:overworld": [a]]) == nil)  // Nether not loaded yet
    }

    @Test func scannerReadsPoiFiles() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let records: [NBT] = [
            .compound(["type": .string("minecraft:nether_portal"), "pos": .intArray([1, 70, 1]), "free_tickets": .int(0)]),
            .compound(["type": .string("minecraft:nether_portal"), "pos": .intArray([1, 71, 1]), "free_tickets": .int(0)]),
            .compound(["type": .string("minecraft:home"), "pos": .intArray([5, 64, 5]), "free_tickets": .int(0)]),
        ]
        let chunk = NBT.compound(["DataVersion": .int(5023), "Sections": .compound(["4": .compound(["Valid": .byte(1), "Records": .list(records)])])])
        let poiDir = world.appendingPathComponent("dimensions/minecraft/overworld/poi")
        try FileManager.default.createDirectory(at: poiDir, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([TestWorld.ChunkSpec(x: 0, z: 0, nbt: chunk)])).write(to: poiDir.appendingPathComponent("r.0.0.mca"))
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let places = await PlaceScanner.scan(dimension)
        #expect(places.filter { $0.group == .portal }.count == 1)  // two blocks, one portal
        #expect(places.filter { $0.group == .bed }.count == 1)
    }
}

@Suite struct CreatureTests {
    let owner = UUID()

    func entity(_ id: String, x: Double, z: Double, extra: [String: NBT] = [:]) -> NBT {
        .compound(["id": .string(id), "Health": .float(10), "Pos": .list([.double(x), .double(64), .double(z)])].merging(extra) { $1 })
    }

    @Test func groupsAndTitles() throws {
        let villager = try #require(Creature(entity("minecraft:villager", x: 0, z: 0, extra: [
            "VillagerData": .compound(["profession": .string("minecraft:librarian"), "level": .int(5)])])))
        let marker = try #require(CreatureMarker(villager, dimension: "minecraft:overworld"))
        #expect(marker.group == .villager && marker.name == "Librarian")
        #expect(TradeText.levelName(5) == "Master")
        let pet = Creature(id: "minecraft:cat", x: 1, y: 64, z: 2, customName: "Mittens", owner: owner)
        #expect(CreatureGroup.group(for: pet) == .pet && CreatureMarker(pet, dimension: "d")?.name == "Mittens")
        #expect(CreatureGroup.group(for: Creature(id: "minecraft:sheep", x: 0, y: 0, z: 0)) == nil)
    }

    @Test func sessionScansShowsAndSearchesCreatures() async throws {
        // Scans walk the terrain region files, as entities only exist where terrain does.
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: world) }
        let entities = world.appendingPathComponent("dimensions/minecraft/overworld/entities")
        try FileManager.default.createDirectory(at: entities, withIntermediateDirectories: true)
        let chunk = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list([
            entity("minecraft:wolf", x: 10, z: 20, extra: ["CustomName": .string("Summer"), "Owner": .intArray([1, 2, 3, 4])]),
            entity("minecraft:villager", x: 5, z: 5, extra: ["VillagerData": .compound(["profession": .string("minecraft:farmer")])]),
            entity("minecraft:sheep", x: 1, z: 1),
        ])])
        try Data(TestWorld.regionFile([TestWorld.ChunkSpec(x: 0, z: 0, nbt: chunk)])).write(to: entities.appendingPathComponent("r.0.0.mca"))
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.selectedIndex.creatures.map(\.group).sorted { $0.rawValue < $1.rawValue } == [.pet, .villager])
        session.visibility.creatures = [.pet]
        #expect(session.mapContent.creatures.map(\.name) == ["Summer"])
        let summer = try #require(session.mapContent.creatures.first)
        session.mapClicked(.creature(summer))
        #expect(session.mapContent.selection == .creature(summer))
        #expect(session.inspector == .selection)   // its details show in the inspector
        session.mapClicked(nil)
        #expect(session.selection == nil && session.inspector == nil)
        session.mapClicked(.creature(summer))
        session.inspector = .world                 // showing something else lets go of it
        #expect(session.selection == nil)
        // Choosing the creature in the sidebar shows its layer, centers on it and selects it.
        session.visibility.creatures = []
        session.map?.viewport = MapViewport(center: .zero, scale: 0.25)
        session.choose(.creature(summer.id))
        #expect(session.visibility.creatures == [.pet] && session.selection == .creature(summer))
        // The map centers on it but keeps the zoom the user chose.
        #expect(session.map?.viewport == MapViewport(center: summer.position, scale: 0.25))
        // World Info stays selected in the sidebar only while the inspector shows it.
        session.sidebarSelection = .worldInfo
        session.choose(.worldInfo)
        #expect(session.inspector == .world && session.selection == nil)
        session.inspector = .storage
        #expect(session.sidebarSelection == nil)
        #expect(session.name(ofPlayerWith: UUID(uuidString: "00000001-0000-0002-0000-000300000004")!).hasPrefix("a player not in this world"))
        session.center(on: CGPoint(x: 10, y: 20))
        #expect(session.map?.viewport.center == CGPoint(x: 10, y: 20))
        #expect(session.spawnPoint == .zero)   // the test world has no spawn
        session.search.text = "summer"
        await session.search.waitForIndex()
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.detail) == ["“Summer”"])
        #expect(session.search.results.first?.source == .layer(.creature(.pet)))
    }
}

@Suite struct BiomeAreaTests {
    @Test func neighboringChunksJoinAndSliversAreLeftOut() {
        var biomes: [ChunkCoordinate: String] = [:]
        for x in 0..<3 { for z in 0..<2 { biomes[ChunkCoordinate(x: x, z: z)] = "minecraft:plains" } }   // 6 chunks
        biomes[ChunkCoordinate(x: 3, z: 0)] = "minecraft:river"                                            // 1-chunk sliver
        for z in 5..<9 { biomes[ChunkCoordinate(x: 0, z: z)] = "minecraft:plains" }                       // separate 4-chunk area
        let areas = BiomeScanner.areas(from: biomes).sorted { $0.chunkCount > $1.chunkCount }
        #expect(areas.map(\.chunkCount) == [6, 4])
        #expect(areas.allSatisfy { $0.group.id == "minecraft:plains" } && areas[0].group.name == "Plains")
        #expect(areas[0].position == CGPoint(x: 24, y: 8) || areas[0].position == CGPoint(x: 24, y: 24))   // a middle chunk
        #expect(areas[0].name == "6 chunks")
        // The outline runs around the 3×2 chunks, not between them.
        #expect(areas[0].bounds == CGRect(x: 0, y: 0, width: 48, height: 32))
        #expect(areas[0].outline.boundingRect == CGRect(x: 0, y: 0, width: 48, height: 32))
        #expect(!areas[0].outline.contains(CGPoint(x: 16, y: 8)))
        #expect(Set(BiomeColors.table.values).count == BiomeColors.table.count)   // every biome's outline differs
    }

    @Test func sessionFindsBiomeAreas() async throws {
        let chunks = (0..<2).flatMap { x in (0..<2).map { z in TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } } }
        let world = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.selectedIndex.biomeAreas.map(\.chunkCount) == [4])
        #expect(session.selectedIndex.biomeAreas.first?.group.name == "Plains")
        #expect(session.mapContent.biome(at: CGPoint(x: 20.5, y: 3)) == "minecraft:plains")
        #expect(session.mapContent.biome(at: CGPoint(x: -1, y: 0)) == nil)
        // Biomes start without outlines.
        session.visibility.biomes = []
        #expect(session.mapContent.biomeAreas.isEmpty)
        session.visibility.biomes = [BiomeGroup(id: "minecraft:plains")]
        #expect(session.mapContent.biomeAreas.count == 1)
    }

    @Test func caveBiomesBelowTheSurfaceGetTheirOwnAreas() async throws {
        // Plains at the surface (section 0), with Sulfur Caves (section -3) and the Deep Dark (section -4) below.
        let chunks = (0..<2).flatMap { x in (0..<2).map { z in
            var spec = TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
            var root = spec.nbt.compound!
            let deep = NBT.compound(["Y": .byte(-4),
                                     "block_states": .compound(["palette": .list([.string("minecraft:sculk")])]),
                                     "biomes": .compound(["palette": .list([.string("minecraft:deep_dark")])])])
            let sulfur = NBT.compound(["Y": .byte(-3),
                                       "block_states": .compound(["palette": .list([.string("minecraft:stone")])]),
                                       "biomes": .compound(["palette": .list([.string("minecraft:sulfur_caves")])])])
            root["sections"] = .list([deep, sulfur] + (root["sections"]?.list ?? []))
            spec.nbt = .compound(root)
            return spec
        } }
        let world = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let areas = session.selectedIndex.biomeAreas
        #expect(Set(areas.map(\.group.id)) == ["minecraft:plains", "minecraft:deep_dark", "minecraft:sulfur_caves"])
        #expect(areas.first { $0.group.id == "minecraft:deep_dark" }?.chunkCount == 4)
        // The surface is unchanged; the readout adds what's below.
        #expect(session.mapContent.biome(at: CGPoint(x: 20.5, y: 3)) == "minecraft:plains")
        #expect(session.mapContent.biomeDescription(at: CGPoint(x: 20.5, y: 3)) == "Plains · Deep Dark and Sulfur Caves below")
        #expect(session.mapContent.biomeDescription(at: CGPoint(x: -1, y: 0)) == nil)
        session.search.text = "biome:deep dark"
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.detail) == ["Deep Dark"])
    }

    @Test func unfinishedChunksPlaceholderBiomesAreIgnored() async throws {
        // Four generated chunks, and four unfinished ones beside them whose placeholder biome is
        // desert. Only the generated chunks have a biome.
        let generated = (0..<2).flatMap { x in (0..<2).map { z in
            TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        } }
        let unfinished = (2..<4).flatMap { x in (0..<2).map { z in
            var spec = TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
            var root = spec.nbt.compound!
            root["Status"] = .string("minecraft:structure_starts")
            var section = root["sections"]!.list![0].compound!
            section["biomes"] = .compound(["palette": .list([.string("minecraft:desert")])])
            root["sections"] = .list([.compound(section)])
            spec.nbt = .compound(root)
            return spec
        } }
        let world = try TestWorld.make(chunks: generated + unfinished)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.selectedIndex.biomeAreas.map(\.group.id) == ["minecraft:plains"])
        #expect(session.mapContent.biome(at: CGPoint(x: 40, y: 8)) == nil)   // chunk (2, 0), unfinished
    }
}

@Suite struct HeatMapTests {
    @Test func logarithmicScaleAndColors() throws {
        #expect(HeatMap.level(ofTicks: 1_199) == nil)
        #expect(HeatMap.level(ofTicks: HeatMap.minimumTicks) == 0)
        #expect(HeatMap.level(ofTicks: HeatMap.maximumTicks * 50) == 1)
        let hour = try #require(HeatMap.level(ofTicks: 72_000))
        #expect(hour > 0.3 && hour < 0.45)
        #expect(HeatMap.hue(atLevel: 1) == 0)   // red
        let red = HeatMap.rgb(hue: 0), blue = HeatMap.rgb(hue: 0.66)
        #expect(red.0 == 1 && red.2 == 0 && blue.2 == 1)
        var ticks = [Int](repeating: 0, count: 1024)
        #expect(HeatMap.image(fromTicks: ticks) == nil)
        ticks[33] = 72_000
        let image = try #require(HeatMap.image(fromTicks: ticks))
        #expect(image.width == 32 && image.height == 32)
    }

    @Test func sessionReadsTheSelectedDimensionWhenShown() async throws {
        var lived = TestWorld.chunk(x: 1, z: 1, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        var root = lived.nbt.compound!
        root["InhabitedTime"] = .long(720_000)
        lived.nbt = .compound(root)
        let world = try TestWorld.make(chunks: [lived])
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        #expect(session.heatMap.visibleImages == nil && !session.heatMap.isLoading)
        session.heatMap.isShown = true
        #expect(session.heatMap.isLoading)
        await session.heatMap.waitForReads()
        #expect(session.heatMap.visibleImages?.keys.sorted { $0.x < $1.x } == [RegionCoordinate(x: 0, z: 0)])
        session.heatMap.isShown = false
        #expect(session.heatMap.visibleImages == nil)
    }
}

@Suite struct InGameMapTests {
    func mapNBT(dimension: NBT, scale: Int8 = 0, x: Int32 = 0, z: Int32 = 0, drawn: Bool = true) -> NBT {
        var colors = [Int8](repeating: 0, count: 128 * 128)
        if drawn { colors[0] = 4 * 12 + 2 }   // water, top-left pixel
        return .compound(["DataVersion": .int(5023), "data": .compound([
            "dimension": dimension, "scale": .byte(scale), "xCenter": .int(x), "zCenter": .int(z), "colors": .byteArray(colors),
        ])])
    }

    @Test func imageAndFittingScale() throws {
        let map = try #require(MapItem(id: 1, nbt: mapNBT(dimension: .string("minecraft:overworld"), scale: 3)))
        let image = try #require(InGameMapImage.make(map))
        #expect(image.width == 128 && image.height == 128)
        #expect(InGameMapImage.fittingScale(for: map) == 0.5)   // 1,024 blocks in about 512 points
        #expect(InGameMapImage.fittingScale(for: try #require(MapItem(id: 2, nbt: mapNBT(dimension: .byte(0))))) == 4)
    }

    @Test func sessionListsDrawnMapsAndShowsOne() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let maps = world.appendingPathComponent("data/minecraft/maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        func write(_ id: Int, _ nbt: NBT) throws {
            try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: maps.appendingPathComponent("\(id).dat"))
        }
        try write(3, mapNBT(dimension: .string("minecraft:overworld"), scale: 1, x: 256, z: -2432))
        try write(4, mapNBT(dimension: .string("minecraft:overworld"), drawn: false))   // blank
        try write(5, mapNBT(dimension: .byte(15)))                                       // another Bukkit world
        try write(6, mapNBT(dimension: .string("minecraft:the_nether")))                 // dimension not in this world
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        #expect(session.inGameMaps.map(\.id) == [3])
        session.show(session.inGameMaps[0])
        #expect(session.mapContent.inGameMap?.map.id == 3)
        #expect(session.map?.viewport.center == CGPoint(x: 256, y: -2432) && session.map?.viewport.scale == 2)
        #expect(session.inspector == .selection)
        // Clicking the map elsewhere leaves an in-game map laid over the terrain.
        session.mapClicked(nil)
        #expect(session.mapContent.inGameMap?.map.id == 3)
        // Closing the inspector takes it away.
        session.inspector = nil
        #expect(session.selection == nil && session.mapContent.inGameMap == nil)
    }
}
