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
        let initial: WorldDefinitions
        let loader: WorldDefinitionLoader

        init(library: GameDataLibrary? = nil) throws {
            root = try TestWorld.make(chunks: [], dimensionSettings: [
                "minecraft:overworld": TestWorld.noiseDimension(type: .string("minecraft:overworld"),
                                                               noise: .string("minecraft:overworld"))
            ])
            world = try World(contentsOf: root)
            initial = try WorldDefinitions.read(world, assets: nil)
            loader = WorldDefinitionLoader(world: WorldReadSource(world), work: work,
                gameSource: .init(generation: generation, selection: .loaded(library)),
                dimensions: world.dimensions(), definitions: initial)
        }

        func close() {
            loader.close()
            work.close()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func savesPublishCurrentProgressThenReadTheNewestMergedDefinitions() async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<WorldDefinitions>(), numbers = ReadNumbers()
        loader.readDefinitions = { _, _, _ in .complete(await definitions.read(String(await numbers.next()))) }
        let source = WorldGameDataSource(generation: fixture.generation, selection: .loaded(nil))
        loader.refreshDefinitions(gameSource: source)
        await definitions.waitForRequest("0")
        loader.refreshDefinitions(gameSource: source)
        loader.refreshDefinitions(gameSource: source)
        var progress = fixture.initial
        progress.possibleBiomes = ["minecraft:overworld": ["example:progress"]]
        await definitions.finish("0", with: progress)
        await definitions.waitForRequest("1")
        #expect(loader.value?.definitions == progress)
        var updated = progress
        updated.possibleBiomes = ["minecraft:overworld": ["example:changed"]]
        await definitions.finish("1", with: updated)
        await loader.work.waitUntilFinished()
        #expect(loader.value?.definitions == updated)
        #expect(await definitions.requested == ["0", "1"])
        loader.refreshDefinitions(gameSource: source)
        await definitions.waitForRequest("2")
        await definitions.finish("2", with: WorldDefinitions())
        await loader.work.waitUntilFinished()
        #expect(loader.value?.definitions == WorldDefinitions())
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func failedDefinitionsKeepTheirProvenanceUntilTheNextSuccessfulSave() async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<Result<WorldDefinitions, CocoaError>>()
        loader.readDefinitions = { _, _, _ in .complete(try await definitions.read("definitions").get()) }
        let initialSource = loader.value?.source, generation = UUID()
        let source = WorldGameDataSource(generation: generation, selection: .loaded(nil))
        loader.refreshDefinitions(gameSource: source)
        await definitions.waitForRequest("definitions")
        await definitions.finish("definitions", with: .failure(CocoaError(.fileReadUnknown)))
        await loader.work.waitUntilFinished()
        #expect(loader.value?.definitions == fixture.initial && loader.value?.source == initialSource)
        #expect(await definitions.requested == ["definitions"])
        loader.refreshDefinitions(gameSource: source)
        await definitions.waitForRequest("definitions", count: 2)
        var changed = fixture.initial
        changed.possibleBiomes = ["minecraft:overworld": ["example:newer"]]
        await definitions.finish("definitions", with: .success(changed))
        await loader.work.waitUntilFinished()
        #expect(loader.value?.definitions == changed && loader.value?.source == source.identity)
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test(arguments: [false, true])
    func returningToAnEarlierGameSourceRejectsBothRetiredReadsAndCloseDrainsTheLastRead(partial: Bool) async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let gate = AsyncReadGate<WorldDefinitions>(), numbers = ReadNumbers()
        loader.readDefinitions = { _, _, _ in
            let value = await gate.read(String(await numbers.next()))
            return partial ? .partial(value) : .complete(value)
        }
        let initialSource = loader.value?.source
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForRequest("0")
        loader.refreshDefinitions(gameSource: .init(generation: UUID(), selection: .loaded(nil)))
        #expect(loader.value?.source == initialSource)
        #expect(loader.value?.definitions == fixture.initial)
        await gate.waitForCancellation("0"); await gate.waitForRequest("1")
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForCancellation("1"); await gate.waitForRequest("2")
        var accepted = fixture.initial
        accepted.possibleBiomes = ["minecraft:overworld": ["example:accepted"]]
        await gate.finish("2", with: accepted)
        for await value in Observations({ loader.value?.definitions }) where value == accepted { break }
        var stale = fixture.initial
        stale.possibleBiomes = ["minecraft:overworld": ["example:retired"]]
        let late = stale
        await gate.finish("1", with: late); await gate.finish("0", with: late)
        await loader.work.waitUntilFinished()
        #expect(loader.value?.definitions == accepted)
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForRequest("3")
        fixture.close()
        await gate.waitForCancellation("3"); await gate.finish("3", with: late)
        await fixture.work.waitUntilFinished()
        #expect(loader.value == nil)
        #expect(await gate.requested == ["0", "1", "2", "3"])
    }

    @Test(arguments: [false, true])
    func replacementRetainsCompletedProvenanceUntilTheNewReadFinishes(replacingGeneration: Bool) async throws {
        let assets = try #require(GameAssets(data: Data(TestZIP.zip([
            .init(path: "version.json", text: #"{"id":"fixture","world_version":5023}"#)
        ]))))
        let first = GameDataLibrary(assets: assets, sourceKey: "first")
        let second = GameDataLibrary(assets: assets, sourceKey: "second")
        let fixture = try Fixture(library: first), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<WorldDefinitions>()
        loader.readDefinitions = { _, library, _ in .complete(await definitions.read(library?.sourceKey ?? "none")) }
        let initialSource = WorldGameDataSource(generation: fixture.generation, selection: .loaded(first)).identity
        let generation = replacingGeneration ? UUID() : fixture.generation
        let nextSource = WorldGameDataSource(generation: generation, selection: .loaded(second)).identity
        #expect(loader.value?.source == initialSource)
        var publishedDefinitions: [WorldDefinitions?] = []
        loader.published = { current in publishedDefinitions.append(current?.definitions) }
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(first)))
        await definitions.waitForRequest("first")
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(second)))
        #expect(loader.value?.source == initialSource)
        await definitions.waitForCancellation("first"); await definitions.waitForRequest("second")
        var updated = fixture.initial
        updated.possibleBiomes = ["minecraft:overworld": ["example:current"]]
        #expect(loader.value?.source == initialSource)
        #expect(loader.value?.definitions == fixture.initial)
        await definitions.finish("second", with: updated)
        for await value in Observations({ loader.value?.source }) where value == nextSource { break }
        var retired = fixture.initial
        retired.possibleBiomes = ["minecraft:overworld": ["example:retired"]]
        await definitions.finish("first", with: retired)
        await loader.work.waitUntilFinished()
        #expect(loader.value?.source == nextSource && loader.value?.definitions == updated)
        #expect(!publishedDefinitions.contains(nil) && !publishedDefinitions.contains(retired))
        fixture.close(); await fixture.work.waitUntilFinished()
        #expect(loader.value == nil)
    }

    @Test(arguments: [false, true])
    func unreadGameSelectionCancelsOldReadsAndWaitsForCompletedSelection(replacingGeneration: Bool) async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let definitions = AsyncReadGate<WorldDefinitions>()
        loader.readDefinitions = { _, _, _ in .complete(await definitions.read("definitions")) }
        let initial = loader.value
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await definitions.waitForRequest("definitions")
        let generation = replacingGeneration ? UUID() : fixture.generation
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loading))
        await definitions.waitForCancellation("definitions")
        var retired = fixture.initial
        retired.possibleBiomes = ["minecraft:overworld": ["example:retired"]]
        await definitions.finish("definitions", with: retired)
        await loader.work.waitUntilFinished()
        #expect(await definitions.requested == ["definitions"])
        #expect(loader.value?.definitions == initial?.definitions)
        #expect(loader.value?.source == initial?.source)

        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(nil)))
        await definitions.waitForRequest("definitions", count: 2)
        await definitions.finish("definitions", with: WorldDefinitions())
        await loader.work.waitUntilFinished()
        #expect(await definitions.requested == ["definitions", "definitions"])
        #expect(loader.value?.definitions == WorldDefinitions())
        #expect(loader.value?.source == WorldGameDataSource(generation: generation, selection: .loaded(nil)).identity)
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
        let opening = try #require(fixture.initial.dimensionSettings["minecraft:overworld"])
        let different = try #require(try WorldDefinitions.read(addedWorld, assets: nil).dimensionSettings["example:added"])
        let gate = AsyncReadGate<WorldDefinitions>(), numbers = ReadNumbers()
        loader.readDefinitions = { _, _, _ in .complete(await gate.read(String(await numbers.next()))) }
        var changed = fixture.initial
        changed.dimensionSettings["minecraft:overworld"] = different
        let updated = changed
        loader.refreshDefinitions(gameSource: .init(generation: fixture.generation, selection: .loaded(nil)))
        await gate.waitForRequest("0"); await gate.finish("0", with: updated)
        await loader.work.waitUntilFinished()
        let source = loader.value?.source
        let generation = replacingGame ? UUID() : fixture.generation
        loader.refreshDefinitions(gameSource: .init(generation: generation, selection: .loaded(nil)))
        await gate.waitForRequest("1")
        loader.include([dimension], settings: ["minecraft:overworld": opening, "example:added": opening])
        #expect(loader.value?.definitions.dimensionSettings["minecraft:overworld"] == different)
        #expect(loader.value?.definitions.dimensionSettings["example:added"] == opening)
        #expect(loader.value?.source == source)
        await gate.waitForCancellation("1"); await gate.waitForRequest("2")
        changed.dimensionSettings["example:added"] = different
        await gate.finish("2", with: changed)
        await gate.finish("1", with: fixture.initial)
        await loader.work.waitUntilFinished()
        #expect(loader.value?.definitions == changed)
        #expect(loader.value?.source.generation == generation)
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func aPartialReplacementKeepsThePreviousFactsAndTheirSourceUntilACompleteRead() async throws {
        let fixture = try Fixture(), loader = fixture.loader
        defer { fixture.close(); fixture.remove() }
        let original = try #require(loader.value)
        let tag = fixture.root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/block/diamond_ores.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tag.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tag.path) }
        let source = WorldGameDataSource(generation: UUID(), selection: .loaded(nil))
        let reads = ReadNumbers()
        loader.readDefinitions = { world, library, previous in
            #expect(previous == nil)
            let pass = await reads.next()
            let result = try await WorldResources.readDefinitions(world, library: library, retaining: previous)
            #expect(result.isComplete == (pass > 0))
            return result
        }
        loader.refreshDefinitions(gameSource: source)
        await loader.work.waitUntilFinished()
        #expect(loader.value?.source == original.source)
        #expect(loader.value?.definitions == original.definitions)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tag.path)
        try Data(#"{"replace":true,"values":[]}"#.utf8).write(to: tag)
        loader.refreshDefinitions(gameSource: source)
        await loader.work.waitUntilFinished()
        #expect(loader.value?.source == source.identity)
        #expect(loader.value?.definitions.notableBlocks.blockIDs.contains("minecraft:diamond_ore") == false)
        fixture.close(); await fixture.work.waitUntilFinished()
    }
}
