import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeKitTestSupport
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct PlayerMarkerTests {
    let you = UUID(uuidString: "52DFB519-DE9C-47E6-BC6C-BB053CC423E7")!
    let friend = UUID(uuidString: "06D119DA-BC79-410F-8F7B-062CE442A86D")!
    let legacy = UUID(uuidString: "11C0E607-2120-4B62-A7E5-938F830B3CE7")!

    func pos(_ x: Double, _ z: Double) -> NBT { .list([.double(x), .double(64), .double(z)]) }

    var playerData: [(uuid: UUID, data: NBT)] {
        [
            (you, .compound([
                "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"), "Pos": pos(-2806.6, -3895.2),
                "LastDeathLocation": .compound(["dimension": .string("minecraft:the_nether"), "pos": .intArray([10, 70, 20])]),
                "respawn": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([-2811, 48, -3918])]),
            ])),
            (friend, .compound(["DataVersion": .int(2730), "Dimension": .string("minecraft:overworld"), "Pos": pos(99, -68)])),
            (legacy, .compound(["Dimension": .int(0), "Pos": pos(-12, 241)])),
        ]
    }

    var players: [PlayerInfo] { playerData.map { PlayerInfo(uuid: $0.uuid, nbt: $0.data) } }

    @Test func markersForTheOverworld() {
        let markers = PlayerPresentation.markers(for: players, in: "minecraft:overworld", singleplayerUUID: you, worldDataVersion: 5023)
        // You (position + respawn), the friend and a legacy numeric-dimension player; death is in the Nether.
        #expect(markers.count == 4)
        let mine = markers.first { $0.kind == .player && $0.label == "You" }
        #expect(mine?.position == CGPoint(x: -2806.6, y: -3895.2))
        #expect(mine?.isOutdated == false)
        #expect(markers.contains { $0.kind == .respawn && $0.label == "Your respawn point" })
        let theirs = markers.first { $0.label == "Player 06d119da" }
        #expect(theirs?.isOutdated == true)  // file predates the world's version
        #expect(markers.contains { $0.position == CGPoint(x: -12, y: 241) })
    }

    @Test func eachDimensionListsThePlayersLastSeenInIt() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        for id in ["the_nether", "the_end"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/\(id)/region"), withIntermediateDirectories: true)
        }
        let playerDirectory = url.appendingPathComponent("players/data")
        let missingID = UUID(), missingData = NBT.compound([
            "Dimension": .string("example:missing"), "Pos": pos(1, 2),
        ])
        let missing = PlayerInfo(uuid: missingID, nbt: missingData)
        for (uuid, data) in playerData + [(missingID, missingData)] {
            try Fixtures.writeGzippedNBT(data, to: playerDirectory.appendingPathComponent(uuid.uuidString.lowercased() + ".dat"))
        }
        let defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(Set(overworld.presentation.listedPlayers.map(\.uuid)) == [you, friend, legacy, missingID])
        #expect(nether.presentation.listedPlayers.isEmpty) // a death marker does not move the player's row
        #expect(!overworld.routing.canFocus(missing))
        for player in resources.players {
            #expect(overworld.presentation.listedPlayers.contains { $0.uuid == player.uuid }
                    == overworld.presentation.lists(PlayerPresentation.position(of: player)?.dimension))
        }
        #expect(MapContent(session: nether).players.contains { $0.playerID == you && $0.kind == .death })
        nether.selection.mapClicked(.row(.player(you)), y: nil)
        #expect(nether.selection.inspector == .player(you))
        nether.visibility.hiddenPlayers.insert(you)
        #expect(!MapContent(session: nether).players.contains { $0.playerID == you })
        nether.selection.mapClicked(.row(.player(you)), y: nil)
        #expect(nether.selection.inspector == nil)
        overworld.close(); nether.close()
        await overworld.waitUntilClosed(); await nether.waitUntilClosed()
    }

    @Test func inspectorAndMarkersShareValidLocationsWithoutLosingMissingDimensionDetails() {
        let locations = PlayerPresentation.locations(of: players[0])
        #expect(locations.map(\.kind) == [.player, .death, .respawn])
        #expect(locations.map(\.title) == ["Last Location", "Last Death", "Respawn Point"])
        #expect(locations.map(\.isBlockPosition) == [false, true, true])
        #expect(PlayerPresentation.locations(of: players[2]).map(\.kind) == [.player])
        let invalid = PlayerInfo(uuid: UUID(), nbt: .compound([
            "Dimension": .string("minecraft:overworld"), "Pos": pos(.nan, 0),
            "LastDeathLocation": .compound(["dimension": .string("example:missing"), "pos": .intArray([1, 64, 2])]),
        ]))
        let valid = PlayerPresentation.locations(of: invalid)
        #expect(valid.map(\.kind) == [.death])
        #expect(valid.first?.position.dimension == "example:missing")
        #expect(PlayerPresentation.position(of: invalid) == nil)
        #expect(PlayerPresentation.absentPlayerName(friend, knownName: nil) == "Player 06d119da (not in this world)")
        #expect(PlayerPresentation.absentPlayerName(friend, knownName: "Friend") == "Friend")
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
        #expect(!MapContent(session: first).players.isEmpty)
        first.visibility.hiddenPlayers.insert(uuid)
        #expect(MapContent(session: first).players.isEmpty)
        first.close()
        let second = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { second.close() }
        #expect(second.visibility.hiddenPlayers == [uuid] && MapContent(session: second).players.isEmpty)
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
        let swordNBT = NBT.compound(["id": .string("minecraft:diamond_sword"), "count": .int(1), "Slot": .byte(10), "components": .compound([
            "minecraft:custom_name": .string("Excalibur"), "minecraft:enchantments": .compound(["minecraft:sharpness": .int(5)]),
        ])])
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "Inventory": .list([swordNBT, .compound(["id": .string("minecraft:torch"), "count": .int(64), "Slot": .byte(0)])]),
        ]))
        let hotbar = player.inventorySlots(in: .hotbar), storage = player.inventorySlots(in: .storage)
        let sword = try #require(storage[1]), torches = try #require(hotbar[0])
        #expect(ItemAppearance.description(of: sword) == "Diamond Sword “Excalibur”, enchanted")
        #expect(ItemAppearance.description(of: torches) == "64 Torch")
        #expect(hotbar.count == 9 && hotbar[0]?.id == "minecraft:torch" && hotbar.compactMap(\.self).count == 1)
        #expect(storage.count == 27 && storage[1]?.id == "minecraft:diamond_sword")
        #expect(player.inventorySlots(in: .enderChest).count == 27 && player.inventorySlots(in: .enderChest).allSatisfy { $0 == nil })
        #expect(!ItemAppearance.isEnchanted(torches))
    }
}

@Suite(.isolatedStores) struct PlayerRecordsTests {
    @Test func namesRankingsAndDistances() {
        #expect(PlayerRecords.travelName("minecraft:aviate_one_cm") == "Aviate One Cm")
        #expect(PlayerRecords.travelName("minecraft:boat_one_cm") == "Boat One Cm")
        #expect(PlayerRecords.advancementName("minecraft:story/mine_diamond") == "Story Mine Diamond")
        let records = PlayerRecords(statistics: PlayerStatistics(values: [
            "minecraft:custom": ["minecraft:walk_one_cm": 250_000, "minecraft:boat_one_cm": 2_087_548_000, "minecraft:crouch_one_cm": 5_000],
            "minecraft:mined": ["minecraft:stone": 900, "minecraft:dirt": 1200, "minecraft:sand": 5],
        ]))
        #expect(records.distances.map(\.name) == ["Boat One Cm", "Walk One Cm"])   // crouching, under 100 m, is left out
        #expect(records.distances.first?.value == 2_087_548_000)
        #expect(records.top("minecraft:mined", count: 2).map(\.name) == ["Dirt", "Stone"])
        #expect(records.rows.count == 6 && records.rows.contains { $0.category == "General" && $0.name == "Walk One Cm" })
    }

    @Test func summaryAndTableShareReadableStatistics() throws {
        let records = PlayerRecords(statistics: PlayerStatistics(dataVersion: SaveVersion.java26_3, values: [
            "minecraft:custom": ["minecraft:play_time": 72_000, "minecraft:mob_kills": 3, "minecraft:deaths": 1,
                                 "minecraft:walk_one_cm": 250_000, "minecraft:crouch_one_cm": 25,
                                 "minecraft:damage_taken": 155, "mod:walk_one_cm": 999],
        ]))
        let english = StatisticRow.ValueStyle().locale(Locale(identifier: "en_US"))
        #expect(records.summaryStatistics.map(\.name) == ["Play Time", "Mob Kills", "Deaths", "Walk One Cm"])
        for summary in records.summaryStatistics {
            let table = try #require(records.rows.first { $0.id == summary.id })
            #expect(summary.name == table.name && summary.value == table.value && summary.unit == table.unit)
            #expect(english.format(summary) == english.format(table))
        }
        let play = try #require(records.summaryStatistics.first)
        #expect(english.format(play).contains("1 hour") && !english.format(play).contains("72,000"))
        let walk = try #require(records.distances.first)
        #expect(english.format(walk).contains("2.5") && english.format(walk).contains("km"))
        let french = StatisticRow.ValueStyle().locale(Locale(identifier: "fr_FR"))
        #expect(french.format(walk).contains("2,5") && french.format(walk).contains("km"))
        let crouch = try #require(records.rows.first { $0.statisticID == "minecraft:crouch_one_cm" })
        #expect(english.format(crouch).contains("25") && english.format(crouch).contains("cm"))
        let damage = try #require(records.rows.first { $0.statisticID == "minecraft:damage_taken" })
        #expect(english.format(damage) == "7.75 hearts")
        let unknown = try #require(records.rows.first { $0.statisticID == "mod:walk_one_cm" })
        #expect(english.format(unknown) == "999" && unknown.value == 999)
    }

    @Test func statisticsKeepRawIdentityAndNumericSortValues() throws {
        let records = PlayerRecords(statistics: PlayerStatistics(values: [
            "minecraft:custom": ["minecraft:play_one_minute": 40, "minecraft:walk_one_cm": 100_000],
            "minecraft:mined": ["mod_a:stone": 2, "mod_b:stone": 10],
        ]))
        let rows = records.rows
        #expect(Set(rows.map(\.id)).count == 4)
        let stones = records.top("minecraft:mined")
        #expect(stones.map(\.name) == ["Stone", "Stone"] && stones.map(\.value) == [10, 2])
        #expect(stones[0].id != stones[1].id)
        #expect(records.summaryStatistics.first?.name == "Play Time")
        #expect(records.summaryStatistics.first?.unit == .ticks)
        let legacyTime = try #require(rows.first { $0.statisticID == "minecraft:play_one_minute" })
        let summaryTime = try #require(records.summaryStatistics.first)
        let style = StatisticRow.ValueStyle().locale(Locale(identifier: "en_US"))
        #expect(summaryTime.value == legacyTime.value && style.format(summaryTime) == style.format(legacyTime))
        #expect(legacyTime.statisticID == "minecraft:play_one_minute" && summaryTime.statisticID == "minecraft:play_time")
        #expect(rows.sorted(using: KeyPathComparator(\StatisticRow.value)).map(\.value) == [2, 10, 40, 100_000])
        for values in [[:], ["minecraft:play_time": -1], ["minecraft:play_one_minute": -1],
                       ["minecraft:play_time": 80, "minecraft:play_one_minute": 40]] {
            let statistics = PlayerStatistics(values: ["minecraft:custom": values])
            let summary = PlayerRecords(statistics: statistics).summaryStatistics
            if let time = statistics.playTime, time >= 0 {
                #expect(summary.map(\.value) == [time])
            } else {
                #expect(summary.isEmpty)
            }
        }
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
