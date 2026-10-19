import AppKit
import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct ShoulderPetTests {
    let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let carrier = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let bird = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    let otherBird = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    let overworld = "minecraft:overworld", nether = "minecraft:the_nether"

    func parrot(_ id: UUID?, name: String = "Gray", owner: UUID? = nil) -> NBT {
        var fields: [String: NBT] = ["id": .string("minecraft:parrot"), "Health": .float(6),
            "CustomName": .string(name), "Variant": .int(4), "Sitting": .byte(0),
            "Owner": .string((owner ?? self.owner).uuidString),
            "Pos": .list([.double(999), .double(20), .double(888)])]
        if let id { fields["UUID"] = .string(id.uuidString) }
        return .compound(fields)
    }

    func player(pets: [NBT], dimension: NBT = .string("minecraft:the_nether"),
                position: [Double]? = [-8.7, 70.75, 2.2]) -> PlayerInfo {
        var fields: [String: NBT] = ["DataVersion": .int(5023), "Dimension": dimension]
        if let position { fields["Pos"] = .list(position.map(NBT.double)) }
        for (key, pet) in zip(["ShoulderEntityLeft", "ShoulderEntityRight"], pets) { fields[key] = pet }
        return PlayerInfo(uuid: carrier, nbt: .compound(fields))
    }

    @discardableResult func save(_ player: PlayerInfo, in url: URL) throws -> URL {
        let file = url.appendingPathComponent("players/data/\(player.uuid.uuidString.lowercased()).dat")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Compression.deflate(player.nbt.serialized(), gzip: true)).write(to: file)
        return file
    }

    func makeWorld() throws -> URL {
        let url = try PlayerInspectorTests().makeWorld()
        try PlayerInspectorTests().savePets([parrot(bird)], in: url)
        try save(player(pets: [parrot(bird), parrot(otherBird, name: "Blue", owner: carrier)]), in: url)
        return url
    }

    @Test func sharedPetPresentationUsesCarrierLocationAndSavedOwner() async throws {
        let url = try makeWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try await PlayerInspectorTests().open(url)
        let second = WorldSession(resources: first.resources, dimensionID: nether)
        defer { first.close(); second.close() }
        #expect(first.resources.playerSnapshot === second.resources.playerSnapshot)
        #expect(!first.presentation.selectedIndex.creatures.contains { $0.creature.uuid == bird })
        let pets = second.presentation.selectedIndex.creatures.filter { $0.carrier == carrier }
        #expect(pets.count == 2 && Set(pets.map(\.id)).count == 2)
        let gray = try #require(pets.first { $0.creature.uuid == bird })
        #expect(gray.position == CGPoint(x: -8.7, y: 2.2) && gray.creature.y == 70.75)
        #expect(gray.creature.owner == owner && gray.carrier == carrier)
        #expect(gray.creature.health == 6)
        #expect(gray.creature.maxHealth == 6)
        #expect(gray.creature.appearance?.variant == "minecraft:gray")
        #expect(first.presentation.linkedPets(to: owner).map(\.id) == [gray.id])
        #expect(second.presentation.linkedPets(to: carrier).map(\.creature.uuid) == [otherBird])

        second.selection.choose(.creature(gray.id))
        #expect(second.selection.mapSelection == .creature(gray))
        #expect(second.map?.depth.y == 70 && second.map?.viewport.center == gray.position)
        let content = MapContent(session: second)
        let viewport = MapViewport(center: gray.position, scale: 16), size = CGSize(width: 800, height: 600)
        let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first { $0.id == "creature-" + gray.id })
        #expect(location.position == gray.position && location.y == 70.75)
        #expect(location.target == .row(.creature(gray.id)))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        MapClipboard.copy(location.position, y: location.y, on: try #require(second.map), to: board)
        #expect(board.string(forType: .string) == "-9 70 2")

        first.search.text = "pet: Gray"
        await first.search.waitForSearch()
        let hit = try #require(first.search.results.first)
        #expect(first.search.results.count == 1 && hit.dimension == nether && hit.position == gray.position && hit.y == 70)
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed()
    }

    @Test func playerRefreshMovesShoulderPetsAndLandingRetainsTheirIdentity() async throws {
        let url = try makeWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await PlayerInspectorTests().open(url)
        defer { session.close() }
        session.resources.refreshDelay = .zero
        let old = try #require(session.presentation.linkedPets(to: owner).first)
        session.search.text = "pet: Gray"
        await session.search.waitForSearch()
        let movedFile = try save(player(pets: [parrot(bird)], dimension: .string(overworld), position: [12.5, 48.75, -4.5]), in: url)
        session.resources.worldChanged([movedFile])
        await session.resources.waitForRefresh()
        await session.search.waitForSearch()
        let moved = try #require(session.presentation.linkedPets(to: owner).first)
        #expect(moved.id == old.id && moved.dimension == overworld && moved.position == CGPoint(x: 12.5, y: -4.5))
        #expect(session.presentation.linkedPets(to: carrier).isEmpty)
        #expect(session.search.results.first?.dimension == overworld && session.search.results.first?.y == 48)
        session.selection.showLinkedPet(moved, ownedBy: owner)
        #expect(session.selection.mapSelection == .creature(moved))

        var landed = try #require(parrot(bird).compound)
        landed["Pos"] = .list([.double(13.5), .double(49), .double(-4.5)])
        let region = try PlayerInspectorTests().savePets([.compound(landed)], in: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: region.path)
        let playerFile = try save(player(pets: [], dimension: .string(overworld), position: [12.5, 48.75, -4.5]), in: url)
        session.resources.worldChanged([playerFile, region])
        await session.resources.waitForRefresh()
        await session.search.waitForIndex()
        let current = try #require(session.presentation.linkedPets(to: owner).first)
        #expect(current.id == moved.id && current.carrier == nil && current.position.x == 13.5)
        #expect(session.selection.mapSelection == .creature(current))
        #expect(session.resources.playerSnapshot.shoulderPets.isEmpty)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func unavailableCarriersKeepDetailsAndNeverUseMountingCoordinates() throws {
        let players = [player(pets: [parrot(bird)], position: nil),
                       player(pets: [parrot(bird)], position: [.nan, 64, 0]),
                       player(pets: [parrot(bird)], dimension: .int(999)),
                       player(pets: [parrot(bird)], dimension: .string("mod:unavailable"))]
        for player in players {
            let snapshot = PlayerSnapshot([player])
            let carried = try #require(snapshot.shoulderPets.first)
            #expect(snapshot.shoulderPets.count == 1 && carried.name == "Gray" && carried.creature.owner == owner)
            var part = DimensionIndex()
            let regionCreature = try #require(Creature(parrot(bird)))
            part.creatures = [try #require(CreatureMarker(regionCreature, dimension: overworld))]
            let projected = SearchIndex(dimensions: [overworld: part]).including(snapshot.shoulderPets)
            #expect(projected.creatures.isEmpty)
            #expect(projected.dimensions.keys.sorted() == [overworld])
        }
        let unidentified = PlayerSnapshot([player(pets: [parrot(nil), parrot(nil)])]).shoulderPets
        #expect(unidentified.count == 2 && Set(unidentified.compactMap { $0.marker?.id }).count == 2)
    }
}
