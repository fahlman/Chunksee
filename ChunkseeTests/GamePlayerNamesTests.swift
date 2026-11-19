import ChunkseeIndex
import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GamePlayerNamesTests {
    private let uuid = UUID(uuidString: "06D119DA-BC79-410F-8F7B-062CE442A86D")!

    private var savedPlayer: NBT {
        .compound([
            "DataVersion": .int(Int32(5023)),
            "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(-8.7), .double(48), .double(-16.2)]),
            "LastDeathLocation": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([-9, 64, -17])]),
            "respawn": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([-10, 72, -20])]),
            "Inventory": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(1), "Slot": .byte(0)])]),
            "EnderItems": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(2), "Slot": .byte(0)])]),
        ])
    }

    @Test func markersAndSearchKeepLiteralNamesDistinctFromThePersonalPronounAndUUIDFallback() async throws {
        let player = PlayerInfo(uuid: uuid, nbt: savedPlayer)
        let cases: [(singleplayer: UUID?, known: String?, markerNames: [String], inventory: String, ender: String)] = [
            (nil, nil, ["Player 06d119da’s respawn point", "Where Player 06d119da last died", "Player 06d119da"],
             "Player 06d119da’s inventory", "Player 06d119da’s ender chest"),
            (uuid, nil, ["Your respawn point", "Where you last died", "You"], "Your inventory", "Your ender chest"),
            (uuid, "You", ["You’s respawn point", "Where You last died", "You"], "You’s inventory", "You’s ender chest"),
        ]
        let viewport = MapViewport(center: CGPoint(x: -9, y: -17), scale: 8), size = CGSize(width: 400, height: 200)
        var reference: MapContent?
        for expected in cases {
            let markers = PlayerPresentation.markers(for: [player], in: "minecraft:overworld",
                singleplayerUUID: expected.singleplayer, worldDataVersion: player.dataVersion, knownName: { _ in expected.known })
            #expect(markers.map(\.kind) == [.respawn, .death, .player])
            #expect(markers.map { GameNames.unavailable.playerMarker($0) } == expected.markerNames)
            #expect(markers.map(\.y) == [72, 64, 48])
            #expect(markers.map(\.anchor) == [CGPoint(x: -9.5, y: -19.5), CGPoint(x: -8.5, y: -16.5), CGPoint(x: -8.7, y: -16.2)])
            var content = MapContent(gameNames: .unavailable)
            content.players = markers
            let locations = content.accessibleLocations(viewport: viewport, size: size)
            #expect(locations.map(\.name) == expected.markerNames)
            #expect(content.scene(viewport: viewport, size: size).items.map { $0.label.name(in: content.gameNames) } == expected.markerNames)
            if let reference {
                let previous = reference.accessibleLocations(viewport: viewport, size: size)
                #expect(locations.map(\.id) == previous.map(\.id) && locations.map(\.target) == previous.map(\.target))
                #expect(locations.map(\.frame) == previous.map(\.frame) && locations.map(\.position) == previous.map(\.position))
                #expect(content.hit(at: CGPoint(x: 200, y: 100), viewport: viewport, size: size)?.target
                    == reference.hit(at: CGPoint(x: 200, y: 100), viewport: viewport, size: size)?.target)
            } else { reference = content }

            let name = GameNames.PlayerName(playerID: uuid, singleplayerUUID: expected.singleplayer, knownName: expected.known)
            // An omitted request entry exercises the production unnamed-player fallback.
            let names: [UUID: GameNames.PlayerName] = expected.singleplayer == nil && expected.known == nil ? [:] : [uuid: name]
            let results = await WorldSearch.execute(SearchRequest(queries: ["diamond"], index: .overworld(DimensionContent()),
                players: [player], playerNames: names, gameNames: .unavailable))
            let hits = try #require(results["diamond"]).hits
            #expect(hits.map { $0.title(in: .unavailable) } == [expected.ender, expected.inventory])
            #expect(hits.map(\.source) == [.enderChest(uuid), .inventory(uuid)] && hits.map(\.count) == [2, 1])
            #expect(hits.first?.position == nil && hits.last?.position == player.position.map { CGPoint(x: $0.x, y: $0.z) })
        }
    }

    @Test func twoWindowsPublishKnownPlayerNamesWithoutChangingSavedFactsOrMapTargets() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.writeGzippedNBT(savedPlayer, to: root.appendingPathComponent("players/data/\(uuid.uuidString.lowercased()).dat"))
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in (Data(#"{"name":"You"}"#.utf8), 200) }))
        let world = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { world.close() }
        let first = WorldSession(resources: world), second = WorldSession(resources: world)
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in [first, second] {
            session.search.text = "diamond"
            await session.search.waitForSearch()
            session.selection.choose(.player(uuid))
        }
        let original = MapContent(session: first), hits = first.search.matches(for: first.search.text).hits
        let player = try #require(world.players.first)
        let absent = UUID(uuidString: "52DFB519-DE9C-47E6-BC6C-BB053CC423E7")!
        let viewport = MapViewport(center: CGPoint(x: -9, y: -17), scale: 8), size = CGSize(width: 400, height: 200)
        let before = original.accessibleLocations(viewport: viewport, size: size).filter { $0.id.hasPrefix("player-") }
        #expect(before.count == 3 && hits.map(\.count) == [2, 1])
        #expect(first.presentation.name(of: player) == "Player 06d119da")
        #expect(first.presentation.name(ofPlayerWith: absent) == "Player 52dfb519 (not in this world)")
        let indexRevision = world.index.revision, gameNamesID = world.gameNames.identity
        names.looksUpOnline = true
        await names.lookUp([uuid, absent])
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.presentation.name(of: player) == "You")
            #expect(session.presentation.name(ofPlayerWith: absent) == "You")
            #expect(session.selection.sidebarSelection == .player(uuid))
            #expect(session.search.matches(for: session.search.text).hits.map { $0.title(in: world.gameNames) } == ["You’s ender chest", "You’s inventory"])
            #expect(session.search.matches(for: session.search.text).hits.map(\.id) == hits.map(\.id) && session.search.matches(for: session.search.text).hits.map(\.count) == hits.map(\.count))
            let current = MapContent(session: session)
            let locations = current.accessibleLocations(viewport: viewport, size: size).filter { $0.id.hasPrefix("player-") }
            #expect(locations.map(\.name) == ["You’s respawn point", "Where You last died", "You"])
            #expect(locations.map(\.id) == before.map(\.id) && locations.map(\.target) == before.map(\.target))
            #expect(locations.map(\.frame) == before.map(\.frame) && locations.map(\.position) == before.map(\.position))
            #expect(current.players.map(\.id) == original.players.map(\.id) && current.players.map(\.y) == original.players.map(\.y))
        }
        #expect(world.index.revision == indexRevision && world.gameNames.identity == gameNamesID)
        #expect(original.accessibleLocations(viewport: viewport, size: size).filter { $0.id.hasPrefix("player-") }.map(\.name) == before.map(\.name))
        world.close()
        await world.waitUntilClosed()
        await names.minecraft.waitUntilIdle()
    }
}
