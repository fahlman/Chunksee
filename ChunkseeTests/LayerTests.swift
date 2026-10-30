import ChunkseeKitTestSupport
import ChunkseeIndex
import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
import Observation
@testable import ChunkseeTestHost

@Observable private final class HeatReaderSource {
    var reader: RegionReader?
    init(_ reader: RegionReader?) { self.reader = reader }
}

@Suite(.isolatedStores) struct StructureTests {
    /// A structure start built the way chunks store it, read through ChunkseeKit's public API.
    func start(_ id: String, chunk: (Int, Int), pieces: [(String, [Int])] = [("piece", [0, 60, 0, 9, 70, 9])]) -> StructureStart {
        let nbt = NBT.compound(["structures": .compound(["starts": .compound([id: .compound([
            "id": .string(id), "ChunkX": .int(Int32(chunk.0)), "ChunkZ": .int(Int32(chunk.1)),
            "Children": .list(.compound, pieces.map { .compound(["id": .string($0.0), "BB": .intArray($0.1.map { Int32($0) })]) }),
        ])])])])
        return StructureStart.starts(inChunk: nbt)[0]
    }

    @Test func groupsNamesAndDefaults() throws {
        let groups = try StructureTagFixture.catalog()
        #expect(groups.group(for: "minecraft:village_savanna") == .village)
        #expect(groups.group(for: "minecraft:ocean_ruin_cold") == .ruins)
        #expect(groups.group(for: "minecraft:mineshaft_mesa") == .mineshaft)
        #expect(groups.group(for: "mydatapack:tower") == .other)
        #expect(!StructureGroup.mineshaft.isShownByDefault && !StructureGroup.netherFossil.isShownByDefault)
        #expect(StructureGroup.stronghold.isShownByDefault)
        let names = ["minecraft:village_plains", "minecraft:ocean_ruin_cold", "minecraft:ruined_portal_ocean",
                     "minecraft:shipwreck_beached", "minecraft:ancient_city"].map {
            StructureMarker(start($0, chunk: (0, 0))).name(in: .unavailable)
        }
        #expect(names == ["Village Plains", "Ocean Ruin Cold", "Ruined Portal Ocean", "Shipwreck Beached", "Ancient City"])
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
        let found = await TestWorld.index(RegionReader(dimension: dimension, cache: .off)).structures
        #expect(found.map(\.structureID).sorted() == ["minecraft:stronghold", "minecraft:village_plains"])
        #expect(found.first { $0.group == .stronghold }?.bounds == CGRect(x: 640, y: -16, width: 10, height: 10))
    }

    @Test(arguments: ["Status", "status"])
    func unbuiltStructuresAreAbsentFromMarkersAndSearch(_ statusKey: String) async throws {
        let world = try TestWorld.make(chunks: StructureTestWorld.chunks(statusKey: statusKey))
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        // A placed temple remains visible even in taiga, and a stronghold has no HPos field.
        #expect(session.presentation.selectedIndex.structures.map(\.structureID).sorted() == ["minecraft:jungle_pyramid", "minecraft:stronghold"])
        #expect(MapContent(session: session).structures.count == 2)
        #expect(!session.presentation.selectedIndex.structures.contains { $0.position == CGPoint(x: -266, y: 71.5) })
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
            root.removeValue(forKey: "status")
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

@Suite(.isolatedStores) struct PlaceTests {
    func poi(_ type: String, _ x: Int, _ y: Int, _ z: Int, tickets: Int = 1) -> PointOfInterest {
        PointOfInterest(type: type, x: x, y: y, z: z, freeTickets: tickets)
    }

    @Test func groupsNamesAndClaims() {
        #expect(PlaceGroup.group(for: "minecraft:librarian") == .workstation)
        #expect(PlaceGroup.group(for: "minecraft:meeting") == .bell)
        #expect(PlaceGroup.group(for: "minecraft:beehive") == .beeNest)
        #expect(PlaceGroup.portal.isShownByDefault && !PlaceGroup.bed.isShownByDefault)
        #expect(PlaceMarker(poi("minecraft:librarian", 0, 64, 0)).name(in: .unavailable) == "Librarian’s Workstation")
        let claimedBed = PlaceMarker(poi("minecraft:home", 0, 64, 0, tickets: 0))
        #expect(claimedBed.isClaimed && claimedBed.name(in: .unavailable) == "Villager’s Bed")
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

    @Test func portalLinkStatuses() throws {
        let context = try PortalTestContext()
        typealias Block = NetherPortal.Block
        func frame(_ d: String, _ x: Int, _ z: Int) -> NetherPortal {
            NetherPortal(dimension: d, blocks: [0, 1].flatMap { dx in (0..<3).map { Block(x: x + dx, y: 64 + $0, z: z) } })
        }
        let a = frame("minecraft:overworld", 800, 0), b = frame("minecraft:overworld", 840, 0)  // both lead near nether x 100–105
        let n = frame("minecraft:the_nether", 100, 0)
        let lonely = frame("minecraft:overworld", 8000, 8000)
        let portals = ["minecraft:overworld": [a, b, lonely], "minecraft:the_nether": [n]]
        #expect(PortalLinkStatus.status(of: a, portals: portals, dimensionTypes: context.types, borders: context.borders) == .linked)    // n leads back to a (closer to 800)
        #expect(PortalLinkStatus.status(of: b, portals: portals, dimensionTypes: context.types, borders: context.borders) == .oneWay)    // b -> n, but n -> a
        #expect(PortalLinkStatus.status(of: lonely, portals: portals, dimensionTypes: context.types, borders: context.borders) == .noPartner)
        #expect(PortalLinkStatus.status(of: a, portals: ["minecraft:overworld": [a]], dimensionTypes: context.types, borders: context.borders) == nil)  // Nether not loaded yet
    }

    @Test func returnWouldCreateIsKnownOneWayRatherThanUnknown() throws {
        let context = try PortalTestContext()
        let source = NetherPortal(dimension: NetherPortal.overworld, blocks: [.init(x: 7, y: 64, z: 0)])
        let target = NetherPortal(dimension: NetherPortal.nether, blocks: [.init(x: -16, y: 64, z: 0)])
        let portals = [NetherPortal.overworld: [source], NetherPortal.nether: [target]]
        #expect(PortalLinkStatus.status(of: source, portals: portals, dimensionTypes: context.types, borders: context.borders) == .oneWay)
        let trip = try #require(PortalLinkStatus.roundTrip(of: source, portals: portals, dimensionTypes: context.types, borders: context.borders))
        guard case .oneWay(let found, _, .wouldCreateNewPortal(let destination)) = trip else {
            Issue.record("The inspector needs the known return-creates prediction")
            return
        }
        #expect(found == target)
        #expect(destination == .init(x: -128, y: 64, z: 0))
        #expect(PortalLinkStatus.roundTrip(of: source, portals: [NetherPortal.overworld: [source]], dimensionTypes: context.types, borders: context.borders) == nil)
        if case .returnUnknown? = PortalLinkStatus.roundTrip(of: source, portals: [NetherPortal.nether: [target]],
            dimensionTypes: context.types, borders: context.borders) {} else { Issue.record("Known outward link lost while return index is unread") }
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
        let places = await TestWorld.index(RegionReader(dimension: dimension, cache: .off)).places
        #expect(places.filter { $0.group == .portal }.count == 1)  // two blocks, one portal
        #expect(places.filter { $0.group == .bed }.count == 1)
    }
}

@Suite(.isolatedStores) struct CreatureTests {
    let owner = UUID()

    func entity(_ id: String, x: Double, z: Double, extra: [String: NBT] = [:]) -> NBT {
        Fixtures.mob(["id": .string(id), "Health": .float(10), "Pos": .list([.double(x), .double(64), .double(z)])].merging(extra) { $1 })
    }

    @Test func groupsAndTitles() throws {
        let villager = try #require(Creature(entity("minecraft:villager", x: 0, z: 0, extra: [
            "VillagerData": .compound(["profession": .string("minecraft:librarian"), "level": .int(5)])])))
        let marker = try #require(CreatureMarker(villager, dimension: "minecraft:overworld"))
        #expect(marker.group == .villager && marker.name(in: .unavailable) == "Librarian")
        #expect(GameNames.unavailable.merchantLevel(5) == "Level 5")
        let pet = Creature(id: "minecraft:cat", x: 1, y: 64, z: 2, customName: "Mittens", owner: owner)
        #expect(CreatureGroup.group(for: pet) == .pet && CreatureMarker(pet, dimension: "d")?.name(in: .unavailable) == "Mittens")
        #expect(CreatureGroup.group(for: Creature(id: "minecraft:sheep", x: 0, y: 0, z: 0)) == .mob)
    }

    @Test(arguments: [5, 6, 7, 8, 9, 10]) func oldCacheIsRebuiltAndSelectedPetDetailsFollowSavedChanges(oldVersion: Int) async throws {
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let file = dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca")
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        func save(health: Float) throws {
            let pet = entity("minecraft:wolf", x: 4, z: 4, extra: [
                "Health": .float(health), "CustomName": .string("Summer"), "Owner": .intArray([1, 2, 3, 4]),
                "UUID": .intArray([11, 12, 13, 14]),
                "attributes": .list([.compound(["id": .string("minecraft:max_health"), "base": .double(40)])]),
                "Sitting": .byte(health == 8 ? 1 : 0), "CollarColor": .byte(health == 8 ? 1 : 11),
                "variant": .string(health == 8 ? "minecraft:pale" : "minecraft:woods"),
                "equipment": .compound(health == 8 ? [:] : ["body": .compound(["id": .string("minecraft:wolf_armor")])]),
            ])
            let chunk = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list([pet])])
            try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: chunk)])).write(to: file)
        }
        try save(health: 8)
        let root = world.appendingPathComponent("app-cache")
        let cache = ScanCache(forWorldAt: world, dimensionID: dimension.id, root: root)
        let fingerprint = ScanCache.legacyFingerprint([dimension.regionDirectory.appendingPathComponent("r.0.0.mca"), file])
        let oldFile = try #require(cache.directory).appendingPathComponent("creatures.0.0.\(fingerprint).v\(oldVersion)")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldPet = Creature(id: "minecraft:wolf", x: 4, y: 64, z: 4, customName: "Summer", owner: owner, health: oldVersion == 6 ? 8 : nil)
        let encoded = try PropertyListEncoder().encode([oldPet])
        try ((encoded as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: root)
        defer { session.close() }
        await session.search.waitForIndex()
        let pet = try #require(session.presentation.selectedIndex.creatures.first)
        #expect(pet.creature.health == 8 && !FileManager.default.fileExists(atPath: oldFile.path))
        #expect(pet.creature.uuid == NBT.intArray([11, 12, 13, 14]).uuid)
        #expect(pet.creature.maxHealth == 40 && pet.creature.sittingOrder == true && pet.creature.collarColor == "orange")
        #expect(pet.creature.appearance?.variant == "minecraft:pale" && pet.creature.equipment?.isEmpty == true)
        let cached = cache.load(.init(dimension: dimension, region: .init(x: 0, z: 0), options: .init(try #require(session.resources.readers[dimension.id]).scanOptions)))?.creatures
        #expect(cached?.first?.health == 8)
        #expect(cached?.first?.maxHealth == 40 && cached?.first?.appearance == pet.creature.appearance)
        session.selection.choose(.creature(pet.id))
        #expect(session.selection.mapSelection == .creature(pet))
        try save(health: 4)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        session.search.rebuild(firstDimension: dimension.id)
        await session.search.waitForIndex()
        let refreshed = try #require(session.presentation.selectedIndex.creatures.first)
        #expect(refreshed.creature.health == 4 && pet.creature.health == 8)
        #expect(refreshed.creature.sittingOrder == false && refreshed.creature.collarColor == "blue")
        #expect(refreshed.creature.appearance?.variant == "minecraft:woods")
        #expect(refreshed.creature.equipment?["body"]?.id == "minecraft:wolf_armor")
        #expect(session.selection.mapSelection == .creature(refreshed) && MapContent(session: session).selection == .creature(refreshed))
        #expect(refreshed.creature.owner == pet.creature.owner && refreshed.position == pet.position)
        session.map?.viewport.scale = 0.125
        let map = MapContent(session: session)
        let visible = map.accessibleLocations(viewport: try #require(session.map).viewport, size: CGSize(width: 400, height: 300))
        let location = try #require(visible.first { $0.target == .row(.creature(refreshed.id)) })
        var disclosure = SidebarDisclosure()
        disclosure.selectOnMap(location.target, y: nil, in: session)
        #expect(session.selection.sidebarSelection == .creature(refreshed.id) && session.selection.mapSelection == .creature(refreshed))
        session.close()
        await session.waitUntilClosed()
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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.presentation.selectedIndex.creatures.map(\.group).sorted { $0.rawValue < $1.rawValue } == [.mob, .pet, .villager])
        // Once read, the sidebar can list every Overworld biome, found or not.
        #expect(session.presentation.possibleBiomes.count == 4 && session.presentation.possibleBiomes.contains(BiomeGroup(id: "minecraft:mushroom_fields")))
        session.visibility.creatures = [.pet]
        #expect(MapContent(session: session).creatures.map { $0.name(in: session.resources.gameNames) } == ["Summer"])
        let summer = try #require(MapContent(session: session).creatures.first)
        session.selection.mapClicked(.row(.creature(summer.id)), y: nil)
        #expect(MapContent(session: session).selection == .creature(summer))
        #expect(session.selection.sidebarSelection == .creature(summer.id))
        #expect(session.selection.inspector == .selection)   // its details show in the inspector
        session.selection.mapClicked(nil, y: nil)
        #expect(session.selection.mapSelection == nil && session.selection.inspector == nil && session.selection.sidebarSelection == nil)
        session.selection.mapClicked(.row(.creature(summer.id)), y: nil)
        session.selection.inspector = .world                 // showing something else lets go of it
        #expect(session.selection.mapSelection == nil)
        // Choosing the creature in the sidebar shows its layer, centers on it and selects it.
        session.visibility.creatures = []
        session.map?.viewport = MapViewport(center: .zero, scale: 0.25)
        session.selection.choose(.creature(summer.id))
        #expect(session.visibility.creatures == [.pet] && session.selection.mapSelection == .creature(summer))
        // The map centers on it but keeps the zoom the user chose.
        #expect(session.map?.viewport == MapViewport(center: summer.position, scale: 0.25))
        // World Info stays selected in the sidebar only while the inspector shows it.
        session.selection.choose(.worldInfo)
        #expect(session.selection.inspector == .world && session.selection.mapSelection == nil)
        session.selection.inspector = .storage
        #expect(session.selection.sidebarSelection == .storage)
        #expect(session.presentation.name(ofPlayerWith: UUID(uuidString: "00000001-0000-0002-0000-000300000004")!) == "Player 00000001 (not in this world)")
        session.navigation.focus(on: CGPoint(x: 10, y: 20))
        #expect(session.map?.viewport.center == CGPoint(x: 10, y: 20))
        #expect(session.presentation.spawnPoint == .zero)   // the test world has no spawn
        session.search.text = "summer"
        await session.search.waitForIndex()
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.title) == [summer.name(in: session.resources.gameNames)])
        #expect(session.search.results.first?.detail == "Wolf")
        #expect(session.search.results.first?.source == .layer(.creature(.pet), markerID: summer.id))
    }
}

@Suite(.isolatedStores) struct SpawnerTests {
    @Test func spawnersAreListedByTheirMobAndSearchable() async throws {
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        guard case .compound(var chunk) = spec.nbt else { Issue.record("not a compound"); return }
        chunk["block_entities"] = .list([
            .compound(["id": .string("minecraft:mob_spawner"), "x": .int(3), "y": .int(12), "z": .int(5),
                       "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])])]),
            .compound(["id": .string("minecraft:mob_spawner"), "x": .int(9), "y": .int(4), "z": .int(9), "SpawnData": .compound([:])]),
        ])
        spec.nbt = .compound(chunk)
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let spawners = session.presentation.selectedIndex.places.filter { $0.group == .spawner }
        #expect(spawners.map { $0.name(in: session.resources.gameNames) }.sorted() == ["Empty Spawner", "Zombie Spawner"])
        #expect(spawners.first { $0.mob == "minecraft:zombie" }?.position == CGPoint(x: 3.5, y: 5.5))
        #expect(!PlaceGroup.spawner.isShownByDefault)   // thousands in a typical world
        session.search.text = "place:zombie spawner"
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.title) == ["Zombie Spawner"])
    }
}

@Suite(.isolatedStores) struct BiomeAreaTests {
    @Test func neighboringChunksJoinAndEveryAreaIsKept() {
        var biomes: [ChunkPosition: String] = [:]
        for x in 0..<3 { for z in 0..<2 { biomes[ChunkPosition(x: x, z: z)] = "minecraft:plains" } }   // 6 chunks
        biomes[ChunkPosition(x: 3, z: 0)] = "minecraft:river"                                            // 1-chunk river
        for z in 5..<9 { biomes[ChunkPosition(x: 0, z: z)] = "minecraft:plains" }                       // separate 4-chunk area
        let areas = BiomePresentation.areas(from: biomes).sorted { $0.chunkCount > $1.chunkCount }
        #expect(areas.map(\.chunkCount) == [6, 4, 1])
        #expect(areas.map(\.group.id) == ["minecraft:plains", "minecraft:plains", "minecraft:river"] && areas[0].group.name(in: .unavailable) == "Plains")
        #expect(areas[0].position == CGPoint(x: 24, y: 8) || areas[0].position == CGPoint(x: 24, y: 24))   // a middle chunk
        #expect(areas[0].name(in: .unavailable) == "6 chunks")
        // The outline runs around the 3×2 chunks, not between them.
        #expect(areas[0].bounds == CGRect(x: 0, y: 0, width: 48, height: 32))
        #expect(areas[0].outline.boundingRect == CGRect(x: 0, y: 0, width: 48, height: 32))
        #expect(!areas[0].outline.contains(CGPoint(x: 16, y: 8)))
        #expect(Set(BiomeColors.table.values).count == BiomeColors.table.count)   // every biome's outline differs
    }

    @Test func aCaveBiomeAtTheSurfaceIsOneArea() async throws {
        var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var root = try #require(chunk.nbt.compound)
        var section = try #require(root["sections"]?.list?.first?.compound)
        section["biomes"] = .compound(["palette": .list([.string("minecraft:sulfur_caves")])])
        root["sections"] = .list([.compound(section)])
        chunk.nbt = .compound(root)
        let world = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let index = await TestWorld.index(reader)
        await reader.close()
        #expect(index.biomeAreas.map(\.id) == ["minecraft:sulfur_caves@0,0"])
    }

    @Test func sessionFindsBiomeAreas() async throws {
        let chunks = (0..<2).flatMap { x in (0..<2).map { z in TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } } }
        let world = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.presentation.selectedIndex.biomeAreas.map(\.chunkCount) == [4])
        #expect(session.presentation.selectedIndex.biomeAreas.first?.group.name(in: session.resources.gameNames) == "Plains")
        #expect(MapContent(session: session).biome(at: CGPoint(x: 20.5, y: 3)) == "minecraft:plains")
        #expect(MapContent(session: session).biome(at: CGPoint(x: -1, y: 0)) == nil)
        // Biomes start without outlines.
        session.visibility.biomes = []
        #expect(MapContent(session: session).biomeAreas.isEmpty)
        session.visibility.biomes = [BiomeGroup(id: "minecraft:plains")]
        #expect(MapContent(session: session).biomeAreas.count == 1)
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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let areas = session.presentation.selectedIndex.biomeAreas
        #expect(Set(areas.map(\.group.id)) == ["minecraft:plains", "minecraft:deep_dark", "minecraft:sulfur_caves"])
        #expect(areas.first { $0.group.id == "minecraft:deep_dark" }?.chunkCount == 4)
        // The surface is unchanged; the readout adds what's below.
        #expect(MapContent(session: session).biome(at: CGPoint(x: 20.5, y: 3)) == "minecraft:plains")
        #expect(MapContent(session: session).biomeDescription(at: CGPoint(x: 20.5, y: 3)) == "Plains · Deep Dark and Sulfur Caves below")
        #expect(MapContent(session: session).biomeDescription(at: CGPoint(x: -1, y: 0)) == nil)
        session.search.text = "biome:deep dark"
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.title) == ["Deep Dark"])
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
            root["status"] = .string("minecraft:structure_starts")
            var section = root["sections"]!.list![0].compound!
            section["biomes"] = .compound(["palette": .list([.string("minecraft:desert")])])
            root["sections"] = .list([.compound(section)])
            spec.nbt = .compound(root)
            return spec
        } }
        let world = try TestWorld.make(chunks: generated + unfinished)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.presentation.selectedIndex.biomeAreas.map(\.group.id) == ["minecraft:plains"])
        #expect(MapContent(session: session).biome(at: CGPoint(x: 40, y: 8)) == nil)   // chunk (2, 0), unfinished
    }
}

@Suite(.isolatedStores) struct HeatMapTests {
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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        #expect(session.heatMap.visibleImages == nil && !session.heatMap.isLoading)
        #expect(!MapContent(session: session).showsHeatMap)
        session.heatMap.isShown = true
        #expect(session.heatMap.isLoading)
        #expect(MapContent(session: session).showsHeatMap)
        await session.heatMap.waitForReads()
        #expect(session.heatMap.visibleImages?.keys.sorted { $0.x < $1.x } == [RegionPosition(x: 0, z: 0)])
        #expect(MapContent(session: session).showsHeatMap)
        session.heatMap.isShown = false
        #expect(session.heatMap.visibleImages == nil)
        #expect(!MapContent(session: session).showsHeatMap)
    }

    @Test func dimensionDocumentsKeepTheirOwnHeatImagesAndVisibility() async throws {
        func chunk(ticks: Int) -> TestWorld.ChunkSpec {
            var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            var root = spec.nbt.compound!
            root["InhabitedTime"] = .long(Int64(ticks))
            spec.nbt = .compound(root)
            return spec
        }
        let world = try TestWorld.make(chunks: [chunk(ticks: HeatMap.maximumTicks)])
        defer { try? FileManager.default.removeItem(at: world) }
        let netherFolder = world.appendingPathComponent("DIM-1/region")
        try FileManager.default.createDirectory(at: netherFolder, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([chunk(ticks: HeatMap.minimumTicks)])).write(to: netherFolder.appendingPathComponent("r.0.0.mca"))
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(world), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        await resources.index.waitForIndex()
        func pixel(_ session: WorldSession) throws -> [UInt8] {
            let image = try #require(session.heatMap.visibleImages?[RegionPosition(x: 0, z: 0)])
            let data = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(data))
            return Array(UnsafeBufferPointer(start: bytes, count: 4))
        }
        overworld.heatMap.isShown = true
        await overworld.heatMap.waitForReads()
        #expect(nether.heatMap.visibleImages == nil && !nether.heatMap.isLoading)
        let red = try pixel(overworld)
        #expect(red[0] > red[2] && red[3] > 0)
        nether.heatMap.isShown = true
        await nether.heatMap.waitForReads()
        let blue = try pixel(nether)
        #expect(blue[2] > blue[0] && blue[3] > 0)
        overworld.heatMap.isShown = false
        overworld.heatMap.load(reread: true)
        #expect(overworld.heatMap.visibleImages == nil)
        #expect(try pixel(nether) == blue)
        overworld.heatMap.isShown = true
        await overworld.heatMap.waitForReads()
        #expect(try pixel(overworld) == red)
        #expect(try pixel(nether) == blue)
        resources.close()
        await resources.waitUntilClosed()
        #expect(overworld.isClosed && nether.isClosed)
    }

    @Test(.timeLimit(.minutes(1))) func savesDuringAReadAreCoalescedAndHiddenSavesAreRemembered() async throws {
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimensions().first)
        let gate = AsyncReadGate<RegionFacts>()
        let reader = RegionReader(dimension: dimension, cache: .off) { _, _, _ in await gate.read("region") }
        let layer = HeatMapLayer(reader: { reader }, work: BackgroundWork())
        layer.isShown = true
        await gate.waitForRequest("region")
        layer.load(reread: true)
        layer.load(reread: true)
        let waiting = Task { await layer.waitForReads() }
        let inhabited = try TestWorld.facts(inhabitedTime: HeatMap.maximumTicks)
        await gate.finish("region", with: inhabited)
        await gate.waitForRequest("region", count: 2)
        #expect(layer.visibleImages?.count == 1) // completed data stays visible during the next pass
        await gate.finish("region", with: try TestWorld.facts())
        await waiting.value
        #expect(layer.visibleImages?.isEmpty == true)
        #expect(await gate.requested == ["region", "region"])

        layer.isShown = false
        layer.load(reread: true)
        #expect(await gate.requested.count == 2)
        layer.isShown = true
        await gate.waitForRequest("region", count: 3)
        await gate.finish("region", with: inhabited)
        await layer.waitForReads()
        #expect(layer.visibleImages?.count == 1)
        layer.cancel()
        await reader.close()
    }

    @Test(.timeLimit(.minutes(1))) func replacingTheReaderRejectsItsLateHeatImage() async throws {
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimensions().first)
        let gate = AsyncReadGate<RegionFacts>(), work = BackgroundWork()
        let older = RegionReader(dimension: dimension, cache: .off) { _, _, _ in await gate.read("older") }
        let newer = RegionReader(dimension: dimension, cache: .off) { _, _, _ in await gate.read("newer") }
        let source = HeatReaderSource(older)
        let layer = HeatMapLayer(reader: { source.reader }, work: work)
        layer.isShown = true
        await gate.waitForRequest("older")
        source.reader = newer
        await gate.waitForRequest("newer")
        await gate.finish("newer", with: try TestWorld.facts())
        // Replacement publishes while the retired read is still held. The loader's drain
        // now includes that retired read, so observe publication before awaiting its scope.
        for await ready in Observations({ layer.visibleImages?.isEmpty == true }) where ready { break }
        #expect(layer.visibleImages?.isEmpty == true)
        var drained = false
        var waiting: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiting = Task { started.resume(); await layer.waitForReads(); drained = true }
        }
        #expect(!drained)
        await gate.finish("older", with: try TestWorld.facts(inhabitedTime: HeatMap.maximumTicks))
        await waiting?.value
        await work.waitUntilFinished()
        #expect(drained)
        #expect(layer.visibleImages?.isEmpty == true && !layer.isLoading)
        layer.cancel()
        await older.close(); await newer.close()
    }

    @Test(.timeLimit(.minutes(1))) func closingRejectsALateImageAndDropsTheQueuedPass() async throws {
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimensions().first)
        let gate = AsyncReadGate<RegionFacts>()
        let reader = RegionReader(dimension: dimension, cache: .off) { _, _, _ in await gate.read("region") }
        let layer = HeatMapLayer(reader: { reader }, work: BackgroundWork())
        layer.isShown = true
        await gate.waitForRequest("region")
        layer.load(reread: true)
        layer.cancel()
        let inhabited = try TestWorld.facts(inhabitedTime: HeatMap.maximumTicks)
        await gate.finish("region", with: inhabited)
        await layer.waitForReads()
        layer.load(reread: true)
        #expect(layer.visibleImages == nil)
        #expect(await gate.requested == ["region"])
        await reader.close()
    }
}

@Suite(.isolatedStores) struct InGameMapTests {
    func mapNBT(dimension: NBT, scale: Int8 = 0, x: Int32 = 0, z: Int32 = 0, drawn: Bool = true) -> NBT {
        var colors = [Int8](repeating: 0, count: 128 * 128)
        if drawn { colors[0] = 4 * 12 + 2 }   // water, top-left pixel
        return .compound(["DataVersion": .int(5023), "data": .compound([
            "dimension": dimension, "scale": .byte(scale), "xCenter": .int(x), "zCenter": .int(z), "colors": .byteArray(colors),
        ])])
    }

    @Test func imageSize() throws {
        let map = try #require(MapItem(id: 1, nbt: mapNBT(dimension: .string("minecraft:overworld"), scale: 3)))
        let image = try #require(InGameMapImage.make(map))
        #expect(image.width == 128 && image.height == 128)
    }

    @Test(arguments: [0.125, 8.0])
    func showingAMapPreservesZoomAndRecordsOnlyActualMovement(_ scale: CGFloat) async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let directory = world.appendingPathComponent("data/minecraft/maps")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nbt = mapNBT(dimension: .string("minecraft:overworld"), scale: 3, x: 128, z: -256)
        try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: directory.appendingPathComponent("3.dat"))
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        let item = try #require(session.presentation.inGameMaps.first)
        let map = try #require(session.map)
        let original = MapViewport(center: CGPoint(x: item.centerX, y: item.centerZ), scale: scale)
        map.viewport = original
        session.selection.show(item)
        #expect(map.viewport == original && !session.navigation.canGoBack)
        let moved = MapViewport(center: CGPoint(x: -100, y: 200), scale: scale)
        map.viewport = moved
        session.selection.show(item)
        #expect(map.viewport == original)
        session.navigation.goBack()
        #expect(map.viewport == moved && !session.navigation.canGoBack)
        session.navigation.goForward()
        #expect(map.viewport == original)
        #expect(!session.navigation.canGoForward)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func sessionListsAllReadableMapsAndShowsAnAvailableOne() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let maps = world.appendingPathComponent("data/minecraft/maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        func write(_ id: Int, _ nbt: NBT) throws {
            try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: maps.appendingPathComponent("\(id).dat"))
        }
        try write(3, mapNBT(dimension: .string("minecraft:overworld"), scale: 1, x: 256, z: -2432))
        try write(4, mapNBT(dimension: .string("minecraft:overworld"), drawn: false))   // blank
        try write(5, mapNBT(dimension: .byte(15)))                                       // unrecognized numeric dimension
        try write(6, mapNBT(dimension: .string("minecraft:the_nether")))                 // dimension not in this world
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        // The Nether map's dimension isn't in this world, so it's listed with the Overworld but can't be shown.
        #expect(session.presentation.inGameMaps.map(\.id).sorted() == [3, 4, 5, 6])
        let nether = try #require(session.presentation.inGameMaps.first { $0.id == 6 })
        #expect(session.routing.availability(of: Coordinates(CGPoint(x: nether.centerX, y: nether.centerZ)),
                                            in: nether.dimension) == .missingDimension)
        let before = session.map?.viewport
        session.selection.show(nether)
        #expect(!session.presentation.canShow(nether) && session.selection.mapSelection == nil && session.map?.viewport == before)
        session.selection.show(try #require(session.presentation.inGameMaps.first { $0.id == 3 }))
        #expect(MapContent(session: session).inGameMap?.map.id == 3)
        #expect(session.map?.viewport.center == CGPoint(x: 256, y: -2432) && session.map?.viewport.scale == before?.scale)
        #expect(session.selection.inspector == .selection)
        // Clicking the map elsewhere leaves an in-game map laid over the terrain.
        session.selection.mapClicked(nil, y: nil)
        #expect(MapContent(session: session).inGameMap?.map.id == 3)
        // Closing the inspector takes it away.
        session.selection.inspector = nil
        #expect(session.selection.mapSelection == nil && MapContent(session: session).inGameMap == nil)
        session.close()
        await session.waitUntilClosed()
        #expect(!session.presentation.canShow(nether))
    }
}
