import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct PlayerMarkerTests {
    let you = UUID(uuidString: "52DFB519-DE9C-47E6-BC6C-BB053CC423E7")!
    let friend = UUID(uuidString: "06D119DA-BC79-410F-8F7B-062CE442A86D")!
    let bukkit = UUID(uuidString: "11C0E607-2120-4B62-A7E5-938F830B3CE7")!

    func pos(_ x: Double, _ z: Double) -> NBT { .list([.double(x), .double(64), .double(z)]) }

    var players: [PlayerInfo] {
        [
            PlayerInfo(uuid: you, nbt: .compound([
                "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"), "Pos": pos(-2806.6, -3895.2),
                "LastDeathLocation": .compound(["dimension": .string("minecraft:the_nether"), "pos": .intArray([10, 70, 20])]),
                "respawn": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([-2811, 48, -3918])]),
            ])),
            PlayerInfo(uuid: friend, nbt: .compound(["DataVersion": .int(2730), "Dimension": .string("minecraft:overworld"), "Pos": pos(99, -68)])),
            PlayerInfo(uuid: bukkit, nbt: .compound(["Dimension": .int(0), "Pos": pos(-12, 241), "SpawnWorld": .string("laurenland")])),
        ]
    }

    @Test func markersForTheOverworld() {
        let markers = PlayerPresentation.markers(for: players, in: "minecraft:overworld", singleplayerUUID: you, worldDataVersion: 5023)
        // You (position + respawn) and the friend; the death is in the Nether; the Bukkit player is left off.
        #expect(markers.count == 3)
        let mine = markers.first { $0.kind == .player && $0.label == "You" }
        #expect(mine?.position == CGPoint(x: -2806.6, y: -3895.2))
        #expect(mine?.isOutdated == false)
        #expect(markers.contains { $0.kind == .respawn && $0.label == "Your respawn point" })
        let theirs = markers.first { $0.label == "Player 06d119da" }
        #expect(theirs?.isOutdated == true)  // file predates the world's version
        #expect(!markers.contains { $0.position == CGPoint(x: -12, y: 241) })
    }

    @Test func eachDimensionListsThePlayersLastSeenInIt() {
        let dimensions = ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"]
        func listed(_ id: String) -> [UUID] { PlayerPresentation.listed(players, in: id, dimensions: dimensions).map(\.uuid) }
        // The Bukkit player's position may be in another world, so they're listed with the Overworld.
        #expect(listed("minecraft:overworld") == [you, friend, bukkit])
        #expect(listed("minecraft:the_nether").isEmpty)   // your last death there doesn't list you
        #expect(listed("minecraft:the_end").isEmpty)
    }

    @Test func deathMarkerAppearsInItsOwnDimension() {
        let nether = PlayerPresentation.markers(for: players, in: "minecraft:the_nether", singleplayerUUID: you, worldDataVersion: 5023)
        #expect(nether.map(\.kind) == [.death])
        #expect(nether.first?.position == CGPoint(x: 10, y: 20))
        #expect(nether.first?.label == "Where you last died")
        let named = PlayerPresentation.markers(for: players, in: "minecraft:the_nether", singleplayerUUID: you,
                                               worldDataVersion: 5023, knownName: { _ in "You" })
        #expect(named.first?.label == "Where You last died")
    }
}

@Suite(.isolatedStores) struct PlayerNameTests {
    let friend = UUID(uuidString: "06D119DA-BC79-410F-8F7B-062CE442A86D")!
    let you = UUID(uuidString: "52DFB519-DE9C-47E6-BC6C-BB053CC423E7")!

    /// A fake Mojang that records requests and answers from a table.
    nonisolated final class FakeMojang: @unchecked Sendable {  // state guarded by `lock`
        var requests: [URL] = []
        var answers: [String: (String, Int)] = [:]
        let lock = NSLock()

        var profiles: MojangProfiles {
            MojangProfiles(fetch: { url in
                self.lock.withLock {
                    self.requests.append(url)
                    let (body, status) = self.answers[url.lastPathComponent] ?? ("", 404)
                    return (Data(body.utf8), status)
                }
            })
        }
    }

    func freshDefaults() -> UserDefaults {

        let defaults = TestDefaults.make()

        return defaults
    }

    @Test func mojangProfileURLAndResponses() async throws {
        #expect(MojangProfiles.profileURL(for: friend).absoluteString
                == "https://sessionserver.mojang.com/session/minecraft/profile/06d119dabc79410f8f7b062ce442a86d")
        let fake = FakeMojang()
        fake.answers["06d119dabc79410f8f7b062ce442a86d"] = (#"{"id":"06d119dabc79410f8f7b062ce442a86d","name":"Friend"}"#, 200)
        fake.answers["52dfb519de9c47e6bc6cbb053cc423e7"] = ("", 500)
        #expect(try await fake.profiles.name(for: friend) == "Friend")
        await #expect(throws: MojangProfiles.LookupError.unexpectedStatus(500)) { try await fake.profiles.name(for: you) }
        #expect(try await fake.profiles.name(for: UUID()) == nil)  // 404: no such profile
    }

    @Test func onlineLookupIsOffByDefaultAndSendsNothing() async {
        let fake = FakeMojang()
        let names = PlayerNames(defaults: freshDefaults(), mojang: fake.profiles)
        #expect(!names.looksUpOnline)
        await names.lookUp([friend])
        #expect(fake.requests.isEmpty)
        #expect(names.name(for: friend) == nil)
    }

    @Test func onlineLookupFindsRemembersAndDoesNotRepeat() async {
        let fake = FakeMojang()
        fake.answers["06d119dabc79410f8f7b062ce442a86d"] = (#"{"name":"Friend"}"#, 200)
        let defaults = freshDefaults()
        let names = PlayerNames(defaults: defaults, mojang: fake.profiles)
        names.looksUpOnline = true
        await names.lookUp([friend, you])  // `you` answers 404
        await names.lookUp([friend, you])
        #expect(names.name(for: friend) == "Friend")
        #expect(fake.requests.count == 2)  // each UUID asked once
        // Remembered across launches, without asking again.
        let relaunched = PlayerNames(defaults: defaults, mojang: FakeMojang().profiles)
        #expect(relaunched.name(for: friend) == "Friend")
        #expect(relaunched.looksUpOnline)
    }

    @Test func localCachesWinAndAreReadFromTheChosenFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseeNames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("vanilla/release"), withIntermediateDirectories: true)
        try Data(#"[{"uuid":"52dfb519-de9c-47e6-bc6c-bb053cc423e7","name":"fahlman","expiresOn":"2026-11-09 21:40:44 -0500"}]"#.utf8)
            .write(to: folder.appendingPathComponent("vanilla/release/usercache.json"))
        let fake = FakeMojang()
        let names = PlayerNames(defaults: freshDefaults(), mojang: fake.profiles)
        await names.chooseMinecraftFolder(folder)
        names.looksUpOnline = true
        await names.lookUp([you])
        #expect(names.name(for: you) == "fahlman")
        #expect(fake.requests.isEmpty)  // known locally, so not sent online
        let player = PlayerInfo(uuid: you, nbt: .compound([:]))
        #expect(PlayerPresentation.name(of: player, singleplayerUUID: you, knownName: names.name(for: you)) == "fahlman")
        names.forgetMinecraftFolder()
        #expect(names.name(for: you) == nil)
    }
}

@Suite(.isolatedStores) struct PlayerLayerTests {
    @Test func hiddenPlayersLoseTheirMarkersAndStayHidden() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let players = world.appendingPathComponent("players/data")
        try FileManager.default.createDirectory(at: players, withIntermediateDirectories: true)
        let uuid = UUID()
        let nbt = NBT.compound(["DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
                                "Pos": .list([.double(1), .double(64), .double(2)])])
        try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: players.appendingPathComponent(uuid.uuidString.lowercased() + ".dat"))
        let defaults = TestDefaults.make()
        let first = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        #expect(!first.mapContent.players.isEmpty)
        first.visibility.hiddenPlayers.insert(uuid)
        #expect(first.mapContent.players.isEmpty)
        first.close()
        let second = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { second.close() }
        #expect(second.visibility.hiddenPlayers == [uuid] && second.mapContent.players.isEmpty)
    }
}

@Suite(.isolatedStores) struct ItemAppearanceTests {
    @Test func symbolsAndTintsByCategoryAndMaterial() {
        #expect(ItemAppearance.symbol(for: "minecraft:diamond_pickaxe") == "hammer.fill")
        #expect(ItemAppearance.symbol(for: "minecraft:iron_chestplate") == "tshirt.fill")
        #expect(ItemAppearance.symbol(for: "minecraft:golden_apple") == "fork.knife")
        #expect(ItemAppearance.symbol(for: "minecraft:filled_map") == "map.fill")
        #expect(ItemAppearance.symbol(for: "minecraft:cobblestone") == "cube.fill")
        #expect(ItemAppearance.tint(for: "minecraft:redstone_torch") == .red)
        #expect(ItemAppearance.tint(for: "minecraft:stone_axe") == .gray)
    }

    @Test func slotsDescriptionsAndEnchantments() throws {
        let sword = try #require(ItemStack(.compound(["id": .string("minecraft:diamond_sword"), "count": .int(1), "Slot": .byte(10), "components": .compound([
            "minecraft:custom_name": .string("Excalibur"), "minecraft:enchantments": .compound(["minecraft:sharpness": .int(5)]),
        ])])))
        let torches = ItemStack(id: "minecraft:torch", count: 64, slot: 0)
        #expect(ItemAppearance.description(of: sword) == "Diamond Sword “Excalibur”, enchanted")
        #expect(ItemAppearance.description(of: torches) == "64 Torch")
        let hotbar = ItemAppearance.slots([torches, sword], count: 9)
        #expect(hotbar.count == 9 && hotbar[0]?.id == "minecraft:torch" && hotbar.compactMap(\.self).count == 1)
        #expect(ItemAppearance.slots([torches, sword], first: 9, count: 27)[1]?.id == "minecraft:diamond_sword")
        #expect(!ItemAppearance.isEnchanted(torches))
    }
}

@Suite(.isolatedStores) struct PlayerRecordsTests {
    @Test func namesRankingsAndDistances() {
        #expect(PlayerRecords.travelName("minecraft:aviate_one_cm") == "Elytra")
        #expect(PlayerRecords.travelName("minecraft:boat_one_cm") == "Boat")
        #expect(PlayerRecords.advancementName("minecraft:story/mine_diamond") == "Mine Diamond")
        let records = PlayerRecords(statistics: PlayerStatistics(values: [
            "minecraft:custom": ["minecraft:walk_one_cm": 250_000, "minecraft:boat_one_cm": 2_087_548_000, "minecraft:crouch_one_cm": 5_000],
            "minecraft:mined": ["minecraft:stone": 900, "minecraft:dirt": 1200, "minecraft:sand": 5],
        ]))
        #expect(records.distances.map(\.name) == ["Boat", "Walk"])   // crouching, under 100 m, is left out
        #expect(records.distances.first?.kilometers == 20_875.48)
        #expect(records.top("minecraft:mined", count: 2).map(\.name) == ["Dirt", "Stone"])
        #expect(records.rows.count == 6 && records.rows.contains { $0.category == "General" && $0.name == "Walk One Cm" })
    }

    @Test func readsUUIDFilesAndFallsBackToNameKeyedStatistics() async throws {
        let worldURL = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: worldURL) }
        let uuid = UUID()
        let stats = worldURL.appendingPathComponent("players/stats")
        let advancements = worldURL.appendingPathComponent("players/advancements")
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: advancements, withIntermediateDirectories: true)
        try Data(#"{"stat.playOneMinute":144000}"#.utf8).write(to: stats.appendingPathComponent("PlayerTwo.json"))
        try Data(#"{"minecraft:story/mine_stone":{"criteria":{"get_stone":"2012-01-01 10:00:00 +0000"},"done":true},"minecraft:recipes/misc/x":{"criteria":{},"done":true},"DataVersion":5023}"#.utf8)
            .write(to: advancements.appendingPathComponent(uuid.uuidString.lowercased() + ".json"))
        let world = try World(contentsOf: worldURL)
        let records = await PlayerRecords.load(from: world, uuid: uuid, name: "PlayerTwo")
        #expect(records.statistics?.playTime == 144_000)
        #expect(records.completedAdvancements.map(\.id) == ["minecraft:story/mine_stone"])
        #expect(await PlayerRecords.load(from: world, uuid: UUID(), name: nil).statistics == nil)
    }
}
