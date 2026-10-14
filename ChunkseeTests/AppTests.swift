import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct WorldDocumentTests {
    @Test func readsOpeningMetadataAndRejectsOtherFolders() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try await WorldSnapshot.read(url)
        #expect(snapshot.world.level.name == "Test")
        #expect(snapshot.dimensions.map(\.id) == ["minecraft:overworld"])
        #expect(snapshot.access.url == url)
        await #expect(throws: WorldOpenError.notAWorld) {
            try await WorldSnapshot.read(url.appendingPathComponent("dimensions"))
        }
    }

    @Test func rejectedFoldersCarryTheReasonAndRecoveryForNativeAlerts() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await WorldSnapshot.read(url.appendingPathComponent("dimensions"))
            Issue.record("A folder without a world must be rejected")
        } catch {
            let presented = error as NSError
            #expect(presented.localizedFailureReason == "That folder isn’t a Minecraft world.")
            #expect(presented.localizedRecoverySuggestion == "Choose a world’s folder inside your saves folder.")
        }
    }

    @Test func aWorldSavedBeforeMinecraft118IsRecognized() async throws {
        func session(dataVersion: Int32?) async throws -> (URL, WorldSession) {
            let url = try TestWorld.make(chunks: [])
            var data: [String: NBT] = ["LevelName": .string("Old")]
            if let dataVersion { data["DataVersion"] = .int(dataVersion) }
            try Data(Compression.deflate(NBT.compound(["Data": .compound(data)]).serialized(), gzip: true))
                .write(to: url.appendingPathComponent("level.dat"))
            let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
            return (url, try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil))
        }
        for (dataVersion, isOld) in [(nil, true), (Int32(2730), true), (Int32(2844), false), (Int32(5023), false)] as [(Int32?, Bool)] {
            let (url, opened) = try await session(dataVersion: dataVersion)
            #expect(opened.isSavedBeforeReadableFormat == isOld, "data version \(String(describing: dataVersion))")
            await opened.search.waitForIndex()
            #expect(opened.possibleBiomes.isEmpty == isOld)   // no "(0)" rows for a world that can't be read
            opened.close()
            await opened.waitUntilClosed()
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func manyOpenWorldsHaveIndependentLifetimes() async throws {
        let urls = try (0..<12).map { _ in try TestWorld.make(chunks: []) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let model = AppModel(defaults: UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!)
        var sessions: [WorldSession] = []
        for url in urls {
            let snapshot = try await WorldSnapshot.read(url)
            sessions.append(WorldSession(snapshot: snapshot, names: model.names, savedSearches: model.savedSearches,
                                         defaults: UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!, cacheRoot: nil))
        }
        let first = sessions[0]
        sessions[1].close()
        sessions[1].close() // closing twice cannot end another world's access
        await sessions[1].waitUntilClosed()
        #expect(!first.isClosed && sessions[1].isClosed)
        await first.search.waitForIndex()
        #expect(first.search.index.dimensions["minecraft:overworld"] != nil)
        for session in sessions { session.close() }
        for session in sessions { await session.waitUntilClosed() }
    }
}

@Suite struct RegionReadLifetimeTests {
    @Test func theDocumentSessionDoesNotFinishClosingUntilItsRegionReadReturns() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let gate = AsyncReadGate<RegionData>()
        let session = WorldSession(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                   savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                   readRegion: { _, _ in await gate.read("region") })
        await gate.waitForRequest("region")
        var finishedClosing = false
        let closing = Task {
            session.close()
            await session.waitUntilClosed()
            finishedClosing = true
        }
        await gate.waitForCancellation("region")
        #expect(session.isClosed && !finishedClosing)
        await gate.finish("region", with: RegionData())
        await closing.value
        #expect(finishedClosing)
    }

    @Test func closingCancelsDrainsAndDoesNotCacheAnUnfinishedRead() async throws {
        let url = try TestWorld.make(chunks: [])
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseeReadCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: cacheURL) }
        let dimension = try #require(try World(contentsOf: url).dimensions().first)
        let gate = AsyncReadGate<RegionData>()
        let reader = RegionReader(dimension: dimension, cache: ScanCache(directory: cacheURL)) { _, _ in
            await gate.read("region")
        }
        let read = Task { await reader.contents(.init(x: 0, z: 0)) }
        await gate.waitForRequest("region")
        let closing = Task { await reader.close() }
        await gate.waitForCancellation("region")
        // A queued read after shutdown never starts another pass.
        #expect(await reader.contents(.init(x: 1, z: 0)).containers.isEmpty)
        #expect(await gate.requested == ["region"])
        await gate.finish("region", with: RegionData())
        _ = await read.value
        await closing.value
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
