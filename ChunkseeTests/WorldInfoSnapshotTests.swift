import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldInfoSnapshotTests {
    private func editLevel(_ root: URL, _ edit: (inout [String: NBT]) -> Void) throws {
        let file = root.appendingPathComponent("level.dat")
        var fields = try #require(try NBT.read(contentsOf: file)["Data"]?.compound)
        edit(&fields)
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound(fields)]), to: file)
    }

    private func saved(_ name: String, _ fields: [String: NBT], at root: URL) throws -> URL {
        let file = root.appendingPathComponent("data/minecraft/\(name).dat")
        try Fixtures.writeGzippedNBT(.compound(["data": .compound(fields)]), to: file)
        return file
    }

    private func resources(_ root: URL) async throws -> WorldResources {
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root),
            names: PlayerNames(defaults: defaults), savedSearches: SavedSearches(defaults: defaults),
            defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        resources.refreshDelay = .zero
        return resources
    }

    @Test func readableFactsAdvanceWhileAFailedFieldAndDefinitionsKeepTheirPriorValues() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try editLevel(root) { $0["LevelName"] = .string("Before"); $0["Time"] = .long(10); $0["DayTime"] = nil }
        let weather = try saved("weather", ["raining": .byte(1), "rain_time": .int(200)], at: root)
        let rules = try saved("game_rules", ["minecraft:keep_inventory": .byte(1)], at: root)
        let clock = try saved("world_clocks", ["minecraft:overworld": .compound(["total_ticks": .long(6000)])], at: root)
        let generation = try saved("world_gen_settings", ["seed": .long(42)], at: root)
        let resources = try await resources(root)
        defer { resources.close() }
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        let originalDefinitions = resources.details.definitions, originalWeather = resources.details.weather
        #expect(first.details.dayTime == 6000 && originalWeather?.isRaining == true)
        #expect(first.slimeChunks.seed == 42 && second.slimeChunks.seed == 42)
        let definitions = AsyncReadGate<WorldDefinitions>()
        resources.readDefinitions = { _, _ in await definitions.read("held") }
        try Data([1, 2, 3]).write(to: weather)
        _ = try saved("game_rules", ["minecraft:keep_inventory": .byte(0)], at: root)
        _ = try saved("world_gen_settings", ["seed": .long(43)], at: root)
        try editLevel(root) {
            $0["LevelName"] = .string("After"); $0["Time"] = .long(20); $0["Difficulty"] = .byte(3)
            $0["DataVersion"] = .int(9000); $0["Version"] = .compound(["Name": .string("Updated Save")])
        }
        resources.worldChanged([root.appendingPathComponent("level.dat"), weather, rules, generation])
        await definitions.waitForRequest("held")
        for await name in Observations({ resources.world.level.name }) where name == "After" { break }
        #expect(first.world.level.time == 20 && second.world.level.difficulty == "hard")
        #expect(first.presentation.displayName == "After" && second.presentation.displayName == "After")
        #expect(resources.savedVersion.name == "Updated Save")
        #expect(resources.details.gameRules["minecraft:keep_inventory"] == .bool(false))
        #expect(first.slimeChunks.seed == 43 && second.slimeChunks.seed == 43)
        #expect(resources.details.weather == originalWeather && resources.details.definitions == originalDefinitions)
        await definitions.finish("held", with: originalDefinitions)
        await resources.waitForRefresh()
        resources.readDefinitions = { try await WorldResources.readDefinitions($0, library: $1) }
        first.close(); await first.waitUntilClosed()
        #expect(!resources.isClosed)

        for file in [weather, rules, clock] { try FileManager.default.removeItem(at: file) }
        resources.worldChanged([weather, rules, clock])
        await resources.waitForRefresh()
        #expect(resources.details.weather == nil && resources.details.gameRules.isEmpty && resources.details.dayTime == nil)
        let levelFile = root.appendingPathComponent("level.dat"), goodLevel = try Data(contentsOf: levelFile)
        try Data([1, 2, 3]).write(to: levelFile)
        resources.worldChanged([levelFile]); await resources.waitForRefresh()
        #expect(resources.world.level.name == "After" && resources.savedVersion.name == "Updated Save")
        try goodLevel.write(to: levelFile)
        _ = try saved("weather", ["raining": .byte(0), "rain_time": .int(300)], at: root)
        resources.worldChanged([levelFile, weather]); await resources.waitForRefresh()
        #expect(second.details.weather?.isRaining == false && second.details.weather?.rainTime == 300)
        second.close(); await second.waitUntilClosed()
    }

    @Test func overlappingSavesPublishProgressAndClosingRejectsTheLastRead() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        defer { resources.close() }
        let reads = AsyncReadGate<RefreshRead<WorldInfoSnapshot>>(), schedules = AsyncReadGate<Void>(), numbers = ReadNumbers()
        let lighting = AsyncReadGate<[String: MapLighting]>()
        resources.readInfo = { _, _ in await reads.read(String(await numbers.next())) }
        resources.readLighting = { _, _ in await lighting.read("save") }
        resources.waitBeforeRefresh = { _ in await schedules.read("save") }
        let file = root.appendingPathComponent("data/minecraft/world_clocks.dat")
        resources.worldChanged([file])
        await schedules.waitForRequest("save"); await schedules.finish("save", with: ())
        await reads.waitForRequest("0")
        await lighting.waitForRequest("save"); await lighting.finish("save", with: [:])
        for _ in 0..<3 { resources.worldChanged([file]) }
        await schedules.waitForRequest("save", count: 2); await schedules.finish("save", with: ())
        // Entering the second lighting pass proves the scheduled refresh reached its producers;
        // the same main-actor turn has also queued the following world-info read.
        await lighting.waitForRequest("save", count: 2)
        await lighting.releaseAllAndFuture(with: [:])
        var first = resources.infoSnapshot
        first.dayTime = 100
        await reads.finish("0", with: .complete(first))
        await reads.waitForRequest("1")
        #expect(resources.details.dayTime == 100)
        var second = first; second.dayTime = 200
        await reads.finish("1", with: .complete(second))
        await resources.waitForRefresh()
        #expect(resources.details.dayTime == 200)
        #expect(await reads.requested == ["0", "1"])
        resources.worldChanged([file])
        await schedules.waitForRequest("save", count: 3); await schedules.finish("save", with: ())
        await reads.waitForRequest("2")
        resources.close()
        let closed = resources.details.dayTime
        await reads.waitForCancellation("2")
        var late = second; late.dayTime = 300
        await reads.finish("2", with: .complete(late))
        await resources.waitUntilClosed()
        #expect(resources.details.dayTime == closed)
    }

    @Test func regionWritesAndGameResourceChangesDoNotReadSavedWorldFacts() async throws {
        let root = try TestWorld.make(chunks: [])
        let game = try ItemPictureFixture(extraFiles: [:])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        defer { resources.close() }
        let dimension = try #require(resources.dimensions.first)
        resources.readInfo = { _, _ in Issue.record("Unrelated input reread saved world facts"); throw CancellationError() }
        resources.worldChanged([dimension.regionDirectory.appendingPathComponent("r.0.0.mca")])
        await resources.waitForRefresh()
        resources.names.minecraft.usesGameArtwork.toggle()
        await resources.waitForRefresh()
        resources.names.minecraft.choose(game.root)
        await resources.waitForRefresh()
        resources.names.minecraft.forget()
        await resources.waitForRefresh()
        resources.close(); await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func addingADimensionReplacesTheReadAndRejectsTheRetiredCatalog() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        defer { resources.close() }
        let reads = AsyncReadGate<RefreshRead<WorldInfoSnapshot>>(), numbers = ReadNumbers()
        resources.readInfo = { _, _ in await reads.read(String(await numbers.next())) }
        resources.worldChanged([root.appendingPathComponent("data/minecraft/weather.dat")])
        await reads.waitForRequest("0")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/example/new/region"),
                                               withIntermediateDirectories: true)
        let added = try await WorldSnapshot.read(root)
        defer { added.access.release() }
        try await resources.includeDimensions(from: added)
        await reads.waitForCancellation("0"); await reads.waitForRequest("1")
        var current = added.details.info; current.dayTime = 200
        await reads.finish("1", with: .complete(current))
        for await time in Observations({ resources.details.dayTime }) where time == 200 { break }
        var retired = current; retired.dayTime = 100
        await reads.finish("0", with: .complete(retired))
        await resources.waitForRefresh()
        #expect(resources.details.dayTime == 200)
        #expect(resources.dimensions.contains { $0.id == "example:new" })
        #expect(await reads.requested == ["0", "1"])
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func borderFailureRetainsOnlyThatBorderAndAnotherWorldCannotReuseFacts() async throws {
        let root = try TestWorld.make(chunks: []), other = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let world = try World(contentsOf: root), dimension = try #require(world.dimensions().first)
        let border = try saved("world_border", ["size": .double(100), "center_x": .double(20)], at: dimension.url)
        let first = WorldInfoSnapshot.read(world, dimensions: [dimension]).value
        #expect(first.borders[dimension.id]?.size == 100)
        try Data([1, 2, 3]).write(to: border)
        _ = try saved("wandering_trader", ["spawn_delay": .int(45), "spawn_chance": .int(75)], at: root)
        let partial = WorldInfoSnapshot.read(world, dimensions: [dimension], retaining: first)
        #expect(!partial.isComplete && partial.value.borders == first.borders)
        #expect(partial.value.wanderingTrader?.spawnDelay == 45)
        try FileManager.default.removeItem(at: border)
        let cleared = WorldInfoSnapshot.read(world, dimensions: [dimension], retaining: partial.value)
        #expect(cleared.isComplete && cleared.value.borders.isEmpty)
        let next = try World(contentsOf: other)
        let replacement = WorldInfoSnapshot.read(next, dimensions: next.dimensions(), retaining: partial.value)
        #expect(replacement.value.borders.isEmpty && replacement.value.wanderingTrader == nil)
    }
}
