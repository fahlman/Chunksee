import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

enum PlaceTagFixture {
    static func files(_ members: [String: [String]]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: members.map { name, values in
            ("data/minecraft/tags/point_of_interest_type/\(name).json",
             try JSONSerialization.data(withJSONObject: ["values": values], options: .sortedKeys))
        })
    }

    static func catalog(_ members: [String: [String]]) throws -> PlaceGroup.Catalog {
        let game = try ItemPictureFixture(extraFiles: files(members))
        defer { game.remove() }
        let assets = try #require(try GameAssets(contentsOf: game.jar))
        var tags: [String: GameTag] = [:]
        for id in PlaceGroup.tagIDs { tags[id] = try assets.tag(id, in: "point_of_interest_type") }
        return PlaceGroup.Catalog(tags: tags)
    }
}

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct PlaceGroupingTests {
    @Test func familiesUseTagsWithoutAProfessionOrNamespaceInventory() throws {
        let groups = try PlaceTagFixture.catalog([
            "acquirable_job_site": ["test:needle_keeper", "test:shared"],
            "bee_home": ["test:apiary", "test:shared"],
        ])
        for (id, expected) in ["test:needle_keeper": PlaceGroup.workstation, "test:apiary": .beeNest,
                               "test:shared": .workstation, "minecraft:librarian": .other,
                               "minecraft:beehive": .other, "test:home": .other] {
            #expect(groups.group(for: id) == expected)
        }
        let job = PlaceMarker(.init(type: "test:needle_keeper", x: 1, y: 64, z: 2, freeTickets: 0), groups: groups)
        let home = PlaceMarker(.init(type: "test:apiary", x: 3, y: 65, z: 4, freeTickets: 0), groups: groups)
        #expect(job.name == "Needle Keeper’s Workstation" && job.isClaimed)
        #expect(home.name == "Apiary" && !home.isClaimed)
    }

    @Test func unavailableOrEmptyTagsKeepSavedPointsWithoutGuessingFamilies() throws {
        for groups in [PlaceGroup.Catalog(tags: [:]), try PlaceTagFixture.catalog(["acquirable_job_site": [], "bee_home": []])] {
            for id in ["minecraft:librarian", "minecraft:beehive", "test:custom_job"] {
                let point = PointOfInterest(type: id, x: 1, y: 64, z: 2, freeTickets: 0)
                let markers = PlacePresentation.markers(from: [point], portals: [], groups: groups)
                let marker = try #require(markers.first)
                #expect(markers.count == 1 && marker.type == id && marker.group == .other)
                #expect(marker.y == 64 && !marker.isClaimed)
            }
        }
    }

    @Test func familyTagsCannotDuplicateGroupedPortalBlocks() throws {
        let groups = try PlaceTagFixture.catalog(["acquirable_job_site": ["minecraft:nether_portal", "minecraft:home"]])
        let points = [64, 65].map { PointOfInterest(type: "minecraft:nether_portal", x: 1, y: $0, z: 2, freeTickets: 0) }
        let portals = NetherPortal.portals(from: points, in: "minecraft:overworld")
        let markers = PlacePresentation.markers(from: points, portals: portals, groups: groups)
        #expect(markers.count == 1 && markers.first?.portal?.blocks.count == 2)
        #expect(markers.first?.group == .portal)
        #expect(groups.group(for: "home") == .bed && groups.group(for: "test:home") == .other)
    }

    @Test func liveTagsReclassifyTheSharedPlacesWithoutRereadingCachedRegions() async throws {
        let ids = ["minecraft:librarian", "minecraft:beehive", "test:needle_keeper", "test:apiary", "test:unclassified"]
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        let game = try ItemPictureFixture(extraFiles: PlaceTagFixture.files([
            "acquirable_job_site": ["minecraft:librarian"], "bee_home": ["minecraft:beehive"]
        ]))
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let records = ids.enumerated().map { index, id in NBT.compound([
            "type": .string(id), "pos": .intArray([Int32(index), 64, 0]), "free_tickets": .int(0)
        ]) }
        let poi = NBT.compound(["DataVersion": .int(5023), "Sections": .compound([
            "4": .compound(["Valid": .byte(1), "Records": .list(records)])
        ])])
        try Fixtures.write(try Fixtures.region([.init(localX: 0, localZ: 0, nbt: poi)]),
                           to: dimension.regionURL(.pointsOfInterest, x: 0, z: 0))
        let reads = ReadCount(), defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: root.appendingPathComponent("test-cache"),
            watchWorld: { _, _ in nil }, readRegion: { dimension, region, options in
                await reads.record()
                return try await RegionReader.scan(dimension, region: region, options: options)
            })
        resources.refreshDelay = .zero
        defer { resources.close() }
        func places() async throws -> [PlaceMarker] {
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            return try #require(resources.index.index.dimensions[dimension.id]).places
        }
        func groups() async throws -> [String: PlaceGroup] {
            Dictionary(uniqueKeysWithValues: try await places().map { ($0.type, $0.group) })
        }
        let original = try await places()
        #expect(original.count == ids.count && original.allSatisfy { $0.group == .other })
        #expect(await reads.count == 1)
        resources.names.minecraft.choose(game.root)
        #expect(try await groups()["minecraft:librarian"] == .workstation)
        #expect(try await groups()["minecraft:beehive"] == .beeNest)
        let before = try #require(resources.readers[dimension.id])
        let tag = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/point_of_interest_type/acquirable_job_site.json")
        func write(_ json: String) throws {
            try FileManager.default.createDirectory(at: tag.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: tag, options: .atomic)
        }
        try write(#"{"replace":true,"values":["test:needle_keeper",{"id":"test:absent","required":false}]}"#)
        resources.worldChanged([tag])
        #expect(try await groups()["test:needle_keeper"] == .workstation)
        #expect(try await groups()["minecraft:librarian"] == .other)
        let after = try #require(resources.readers[dimension.id])
        #expect(before !== after && before.scanOptions == after.scanOptions)
        let hits = WorldSearch.search("place:needle keeper", in: resources.index.index, players: []) { _ in .named("") }
        #expect(hits.map(\.title) == ["Needle Keeper’s Workstation"])
        #expect(try await places().first(where: { $0.type == "test:needle_keeper" })?.isClaimed == true)
        try write(#"{"replace":true,"values":[]}"#)
        resources.worldChanged([tag])
        #expect(try await groups()["test:needle_keeper"] == .other)
        #expect(try await groups()["minecraft:librarian"] == .other)
        try write("damaged tag")
        resources.worldChanged([tag])
        #expect(try await groups()["minecraft:librarian"] == .other)
        #expect(try await groups()["minecraft:beehive"] == .beeNest)
        try FileManager.default.removeItem(at: tag)
        resources.worldChanged([tag])
        #expect(try await groups()["minecraft:librarian"] == .workstation)
        resources.names.minecraft.forget()
        #expect(try await places().allSatisfy { $0.group == .other })
        let updated = try await places()
        #expect(updated.map(\.id) == original.map(\.id))
        #expect(updated.map(\.position) == original.map(\.position) && updated.map(\.y) == original.map(\.y))
        #expect(await reads.count == 1)
        resources.close(); await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    private actor ReadCount {
        var count = 0
        func record() { count += 1 }
    }
}
