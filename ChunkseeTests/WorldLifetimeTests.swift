import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(3))) struct WorldLifetimeTests {
    private final class ReleasedObject {
        let name: String
        weak var value: AnyObject?

        init(_ name: String, _ value: AnyObject) {
            self.name = name
            self.value = value
        }
    }

    @Test(arguments: [false, true]) func closingWorldsReleasesTheirOwners(artwork: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        let copiedWorld = environment["CHUNKSEE_LIFETIME_WORLD"].map { URL(filePath: $0) }
        let root: URL
        if let copiedWorld { root = copiedWorld }
        else {
            root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
            try Fixtures.writeGzippedNBT(.compound(["data": .compound(["seed": .long(42)])]),
                                        to: root.appendingPathComponent("data/minecraft/world_gen_settings.dat"))
        }
        defer { if copiedWorld == nil { try? FileManager.default.removeItem(at: root) } }
        let dimension = try #require(try World(contentsOf: root).dimension("minecraft:overworld"))
        let document = dimension.documentURL(inWorldAt: root)
        let model = AppModel(defaults: TestDefaults.make(), cacheRoot: nil)
        if let game = environment["CHUNKSEE_LIFETIME_GAME"] { model.names.minecraft.choose(URL(filePath: game)) }
        model.names.minecraft.usesGameArtwork = artwork
        try model.worldFolders.remember(root)

        do {
            for cycle in 0..<3 {
                // The helper's strong references have left scope before examining these weak ones.
                // Keep the app owner alive so registrations cannot hide a closed-world cycle.
                let objects = try await openAndClose(document, in: model)
                for object in objects {
                    #expect(object.value == nil, "\(object.name) survived close in cycle \(cycle), artwork \(artwork)")
                }
                print("World lifetime: artwork=\(artwork) cycle=\(cycle) retained=\(objects.filter { $0.value != nil }.map(\.name))")
            }
        } catch {
            model.names.minecraft.forget()
            await model.names.minecraft.waitUntilIdle()
            throw error
        }
        model.names.minecraft.forget()
        await model.names.minecraft.waitUntilIdle()
    }

    private func openAndClose(_ document: URL, in model: AppModel) async throws -> [ReleasedObject] {
        let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
        guard case .dimension(let snapshot) = try await reader.readFolder(document) else { throw WorldOpenError.notADimension }
        let session = try await snapshot.makeSession(in: model)
        let resources = session.resources
        let objects = [
            ReleasedObject("WorldResources", resources),
            ReleasedObject("WorldSession", session),
            ReleasedObject("SlimeChunkLayer", session.slimeChunks),
            ReleasedObject("SearchModel", session.search),
            ReleasedObject("WorldInfo loader", resources.infoLoader)
        ]
        await resources.waitForRefresh()
        await session.search.waitForIndex()
        session.visibility.showsSlimeChunks = true
        await session.slimeChunks.waitForImages()
        session.search.text = "stone"
        await session.search.waitForSearch()
        resources.refreshDelay = .zero
        resources.worldChanged([resources.url.appendingPathComponent("level.dat")])
        await resources.waitForRefresh()
        session.close()
        await session.waitUntilClosed()
        await resources.backgroundWork.waitUntilFinished()
        #expect(session.isClosed && resources.isClosed && resources.backgroundWork.isClosed)
        return objects
    }
}
