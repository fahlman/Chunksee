import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldDefinitionLoaderTests {
    private final class Fixture {
        let root: URL
        let world: World
        let work = BackgroundWork()
        let generation = UUID()
        let initial: WorldResources.DefinitionSnapshot
        let loader: WorldDefinitionLoader

        init(library: GameDataLibrary? = nil) throws {
            root = try TestWorld.make(chunks: [], dimensionSettings: [
                "minecraft:overworld": TestWorld.noiseDimension(type: .string("minecraft:overworld"),
                                                               noise: .string("minecraft:overworld"))
            ])
            world = try World(contentsOf: root)
            initial = .init(definitions: try WorldDefinitions.read(world, assets: nil), borders: [:],
                            savedVersion: SavedMinecraftVersion(world.level))
            loader = WorldDefinitionLoader(world: world, work: work,
                gameSource: .init(generation: generation, selection: .loaded(library)),
                dimensions: world.dimensions(), definitions: initial.definitions, borders: initial.borders,
                players: [], savedVersion: initial.savedVersion)
        }

        func close() {
            loader.close()
            work.close()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func player(_ x: Double) -> PlayerInfo {
        PlayerInfo(uuid: UUID(uuidString: "00000001-0000-0002-0000-000300000004")!, nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(x), .double(64), .double(0)])
        ]))
    }

    @Test func savesPublishCurrentProgressThenReadTheNewestMergedDefinitions() async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<WorldResources.DefinitionSnapshot>()
        let players = AsyncReadGate<[PlayerInfo]?>(), numbers = ReadNumbers()
        loader.readDefinitions = { _, _ in await definitions.read("definitions") }
        loader.readPlayers = { _, _ in await players.read(String(await numbers.next())) }
        loader.refreshPlayers()
        await players.waitForRequest("0")
        loader.refreshPlayers()
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        loader.refreshPlayers()
        #expect(loader.value.facts?.definitions == fixture.initial.definitions)
        await players.finish("0", with: [player(10)])
        await definitions.waitForRequest("definitions")
        #expect(loader.snapshot.players.first?.position?.x == 10)
        #expect(loader.value.facts?.definitions == fixture.initial.definitions)
        var updated = fixture.initial.definitions
        updated.possibleBiomes = ["minecraft:overworld": ["example:changed"]]
        await definitions.finish("definitions", with: .init(definitions: updated, borders: [:],
                                                            savedVersion: fixture.initial.savedVersion))
        await players.waitForRequest("1")
        // The player interpretation is still in flight: neither half of the next pair is visible.
        #expect(loader.snapshot.players.first?.position?.x == 10)
        #expect(loader.value.facts?.definitions == fixture.initial.definitions)
        await players.finish("1", with: [player(20)])
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot.players.first?.position?.x == 20)
        #expect(loader.value.facts?.definitions == updated)
        #expect(await definitions.requested == ["definitions"])
        #expect(await players.requested == ["0", "1"])
        loader.refreshPlayers()
        await players.waitForRequest("2"); await players.finish("2", with: [])
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot.players.isEmpty && loader.value.facts?.definitions == updated)
        #expect(await definitions.requested == ["definitions"])
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func aFailedPlayerReadPublishesSavedVersionAndRetainsDefinitionRetryStrength() async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let newerRoot = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: newerRoot) }
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "DataVersion": .int(9000), "Version": .compound(["Name": .string("Newer Save")])
        ])]), to: newerRoot.appendingPathComponent("level.dat"))
        let newerVersion = SavedMinecraftVersion(try World(contentsOf: newerRoot).level)
        var changed = fixture.initial.definitions
        changed.possibleBiomes = ["minecraft:overworld": ["example:newer"]]
        let update = WorldResources.DefinitionSnapshot(definitions: changed, borders: [:], savedVersion: newerVersion)
        let definitions = AsyncReadGate<Result<WorldResources.DefinitionSnapshot, CocoaError>>()
        let players = AsyncReadGate<[PlayerInfo]?>()
        loader.readDefinitions = { _, _ in try await definitions.read("definitions").get() }
        loader.readPlayers = { _, _ in await players.read("players") }
        let original = loader.snapshot
        let initialSource = loader.value.facts?.source, generation = UUID()
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(nil)))
        await definitions.waitForRequest("definitions")
        await definitions.finish("definitions", with: .success(update))
        await players.waitForRequest("players"); await players.finish("players", with: nil)
        await loader.work.waitUntilFinished()
        #expect(loader.value.savedVersion == newerVersion)
        #expect(loader.snapshot === original && loader.value.facts?.definitions == fixture.initial.definitions)
        #expect(loader.value.facts?.source == initialSource)
        #expect(await definitions.requested.count == 1)
        #expect(await players.requested.count == 1)

        loader.refreshPlayers() // A weaker external request must retry the failed definition pair.
        await definitions.waitForRequest("definitions", count: 2)
        await definitions.finish("definitions", with: .failure(CocoaError(.fileReadUnknown)))
        await loader.work.waitUntilFinished()
        #expect(loader.value.savedVersion == newerVersion && loader.snapshot === original)
        #expect(await definitions.requested.count == 2)
        #expect(await players.requested.count == 1)
        loader.refreshPlayers()
        await definitions.waitForRequest("definitions", count: 3)
        await definitions.finish("definitions", with: .success(update))
        await players.waitForRequest("players", count: 2)
        await players.finish("players", with: [player(30)])
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot.players.first?.position?.x == 30)
        #expect(loader.value.facts?.definitions == changed)
        #expect(loader.value.savedVersion == newerVersion)
        #expect(loader.value.facts?.source.generation == generation)
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func returningToAnEarlierGameSourceRejectsBothRetiredReadsAndCloseDrainsTheLastRead() async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let gate = AsyncReadGate<WorldResources.DefinitionSnapshot>(), numbers = ReadNumbers()
        loader.readDefinitions = { _, _ in await gate.read(String(await numbers.next())) }
        loader.readPlayers = { _, _ in [] }
        let initialPlayers = loader.snapshot, initialSource = loader.value.facts?.source
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForRequest("0")
        loader.refreshDefinitions(gameSource: .init(generation: UUID(), selection: .loaded(nil)))
        #expect(loader.value.facts?.source == initialSource && loader.snapshot === initialPlayers)
        #expect(loader.value.facts?.definitions == fixture.initial.definitions)
        #expect(loader.value.savedVersion == fixture.initial.savedVersion)
        await gate.waitForCancellation("0"); await gate.waitForRequest("1")
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        let beforeAcceptance = loader.snapshot
        await gate.waitForCancellation("1"); await gate.waitForRequest("2")
        await gate.finish("2", with: fixture.initial)
        for await value in Observations({ loader.snapshot }) where value !== beforeAcceptance { break }
        let accepted = loader.snapshot
        var stale = fixture.initial.definitions
        stale.possibleBiomes = ["minecraft:overworld": ["example:retired"]]
        let late = WorldResources.DefinitionSnapshot(definitions: stale, borders: [:], savedVersion: fixture.initial.savedVersion)
        await gate.finish("1", with: late); await gate.finish("0", with: late)
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot === accepted && loader.value.facts?.definitions == fixture.initial.definitions)
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForRequest("3")
        fixture.close()
        let closed = loader.snapshot
        await gate.waitForCancellation("3"); await gate.finish("3", with: late)
        await fixture.work.waitUntilFinished()
        #expect(loader.value.facts == nil && loader.snapshot === closed && closed.players.isEmpty)
        #expect(await gate.requested == ["0", "1", "2", "3"])
    }

    @Test(arguments: [false, true])
    func replacementRetainsCompletedProvenanceUntilBothNewReadsFinish(replacingGeneration: Bool) async throws {
        let assets = try #require(GameAssets(data: Data(TestZIP.zip([
            .init(path: "version.json", text: #"{"id":"fixture","world_version":5023}"#)
        ]))))
        let first = GameDataLibrary(assets: assets, sourceKey: "first")
        let second = GameDataLibrary(assets: assets, sourceKey: "second")
        let fixture = try Fixture(library: first), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<WorldResources.DefinitionSnapshot>(), players = AsyncReadGate<[PlayerInfo]?>()
        loader.readDefinitions = { _, library in await definitions.read(library?.sourceKey ?? "none") }
        loader.readPlayers = { _, _ in await players.read("players") }
        let original = loader.snapshot
        let initialSource = WorldGameDataSource(generation: fixture.generation, selection: .loaded(first)).identity
        let generation = replacingGeneration ? UUID() : fixture.generation
        let nextSource = WorldGameDataSource(generation: generation, selection: .loaded(second)).identity
        #expect(loader.value.facts?.source == initialSource)
        var publishedDefinitions: [WorldDefinitions?] = []
        loader.published = { current in publishedDefinitions.append(current.facts?.definitions) }
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(first)))
        await definitions.waitForRequest("first")
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(second)))
        #expect(loader.value.facts?.source == initialSource && loader.snapshot === original)
        await definitions.waitForCancellation("first"); await definitions.waitForRequest("second")
        var updated = fixture.initial.definitions
        updated.possibleBiomes = ["minecraft:overworld": ["example:current"]]
        await definitions.finish("second", with: .init(definitions: updated, borders: [:],
                                                       savedVersion: fixture.initial.savedVersion))
        await players.waitForRequest("players")
        #expect(loader.value.facts?.source == initialSource && loader.snapshot === original)
        #expect(loader.value.facts?.definitions == fixture.initial.definitions)
        var retired = fixture.initial.definitions
        retired.possibleBiomes = ["minecraft:overworld": ["example:retired"]]
        await definitions.finish("first", with: .init(definitions: retired, borders: [:],
                                                      savedVersion: fixture.initial.savedVersion))
        await players.finish("players", with: [player(40)])
        await loader.work.waitUntilFinished()
        #expect(loader.value.facts?.source == nextSource && loader.value.facts?.definitions == updated)
        #expect(loader.snapshot.players.first?.position?.x == 40)
        #expect(!publishedDefinitions.contains(nil) && !publishedDefinitions.contains(retired))
        loader.refreshPlayers()
        await players.waitForRequest("players", count: 2); await players.finish("players", with: [player(41)])
        await loader.work.waitUntilFinished()
        #expect(loader.value.facts?.source == nextSource && loader.value.facts?.definitions == updated)
        #expect(loader.snapshot.players.first?.position?.x == 41)
        fixture.close(); await fixture.work.waitUntilFinished()
        #expect(loader.value.facts == nil)
    }

    @Test(arguments: [false, true])
    func unreadGameSelectionCancelsOldReadsAndWaitsForCompletedSelection(replacingGeneration: Bool) async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<WorldResources.DefinitionSnapshot>()
        loader.readDefinitions = { _, _ in await definitions.read("definitions") }
        loader.readPlayers = { _, _ in [] }
        let original = loader.snapshot, initial = loader.value.facts
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await definitions.waitForRequest("definitions")
        let generation = replacingGeneration ? UUID() : fixture.generation
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loading))
        await definitions.waitForCancellation("definitions")
        loader.refreshPlayers()
        var retired = fixture.initial.definitions
        retired.possibleBiomes = ["minecraft:overworld": ["example:retired"]]
        await definitions.finish("definitions", with: .init(definitions: retired, borders: [:],
                                                              savedVersion: fixture.initial.savedVersion))
        await loader.work.waitUntilFinished()
        #expect(await definitions.requested == ["definitions"])
        #expect(loader.snapshot === original && loader.value.facts?.definitions == initial?.definitions)
        #expect(loader.value.facts?.source == initial?.source)

        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(nil)))
        await definitions.waitForRequest("definitions", count: 2)
        await definitions.finish("definitions", with: .init(definitions: WorldDefinitions(), borders: [:],
                                                              savedVersion: fixture.initial.savedVersion))
        await loader.work.waitUntilFinished()
        #expect(await definitions.requested == ["definitions", "definitions"])
        #expect(loader.value.facts?.definitions == WorldDefinitions())
        #expect(loader.value.facts?.source == WorldGameDataSource(generation: generation, selection: .loaded(nil)).identity)
        #expect(loader.snapshot !== original)
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test(arguments: [false, true])
    func preparedDimensionsExtendCurrentSettingsWithoutRestoringObsoleteOpeningValues(replacingGame: Bool) async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let addedRoot = try TestWorld.make(chunks: [], dimensionSettings: [
            "example:added": TestWorld.noiseDimension(type: .string("minecraft:the_nether"),
                                                     noise: .string("minecraft:nether"))
        ])
        defer { try? FileManager.default.removeItem(at: addedRoot) }
        try FileManager.default.createDirectory(at: addedRoot.appendingPathComponent("dimensions/example/added/region"),
                                                withIntermediateDirectories: true)
        let addedWorld = try World(contentsOf: addedRoot)
        let dimension = try #require(addedWorld.dimension("example:added"))
        let opening = try #require(fixture.initial.definitions.dimensionSettings["minecraft:overworld"])
        let different = try #require(try WorldDefinitions.read(addedWorld, assets: nil).dimensionSettings["example:added"])
        let gate = AsyncReadGate<WorldResources.DefinitionSnapshot>(), numbers = ReadNumbers()
        loader.readDefinitions = { _, _ in await gate.read(String(await numbers.next())) }
        loader.readPlayers = { _, _ in [] }
        var changed = fixture.initial.definitions
        changed.dimensionSettings["minecraft:overworld"] = different
        let updated = WorldResources.DefinitionSnapshot(definitions: changed, borders: [:], savedVersion: fixture.initial.savedVersion)
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForRequest("0"); await gate.finish("0", with: updated)
        await loader.work.waitUntilFinished()
        let previousPlayers = loader.snapshot
        let source = loader.value.facts?.source
        let generation = replacingGame ? UUID() : fixture.generation
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(nil)))
        await gate.waitForRequest("1")
        loader.include([dimension], settings: ["minecraft:overworld": opening, "example:added": opening])
        #expect(loader.value.facts?.definitions.dimensionSettings["minecraft:overworld"] == different)
        #expect(loader.value.facts?.definitions.dimensionSettings["example:added"] == opening)
        #expect(loader.snapshot === previousPlayers)
        #expect(loader.value.facts?.source == source)
        await gate.waitForCancellation("1"); await gate.waitForRequest("2")
        changed.dimensionSettings["example:added"] = different
        await gate.finish("2", with: .init(definitions: changed, borders: [:], savedVersion: fixture.initial.savedVersion))
        await gate.finish("1", with: fixture.initial)
        await loader.work.waitUntilFinished()
        #expect(loader.value.facts?.definitions == changed)
        #expect(loader.value.facts?.source.generation == generation)
        fixture.close(); await fixture.work.waitUntilFinished()
    }
}
