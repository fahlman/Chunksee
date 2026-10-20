import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct PortalAvailabilityTests {
    private final class Fixture {
        let url: URL
        let defaults: UserDefaults
        let names: PlayerNames
        let searches: SavedSearches
        var sessions: [WorldSession] = []
        var resources: [WorldResources] = []
        var gates: [AsyncReadGate<RegionFacts>] = []
        let emptyFacts: RegionFacts

        init() throws {
            emptyFacts = try TestWorld.facts()
            let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            url = try TestWorld.make(chunks: [chunk])
            defaults = TestDefaults.make()
            names = PlayerNames(defaults: defaults)
            searches = SavedSearches(defaults: defaults)
            let poi = NBT.compound(["Sections": .compound(["0": .compound([
                "Valid": .byte(1), "Records": .list([.compound([
                    "type": .string("minecraft:nether_portal"), "pos": .intArray([8, 2, 8]), "free_tickets": .int(0),
                ])]),
            ])])])
            let folder = url.appendingPathComponent("dimensions/minecraft/overworld/poi")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(TestWorld.regionFile([TestWorld.ChunkSpec(x: 0, z: 0, nbt: poi)])).write(to: folder.appendingPathComponent("r.0.0.mca"))
        }

        func open() async throws -> WorldSession {
            let session = WorldSession(snapshot: try await WorldSnapshot.read(url), names: names,
                                       savedSearches: searches, defaults: defaults, cacheRoot: nil)
            sessions.append(session)
            return session
        }

        func addTarget() throws {
            let folder = url.appendingPathComponent("dimensions/minecraft/the_nether/region")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            try Data(TestWorld.regionFile([chunk])).write(to: folder.appendingPathComponent("r.0.0.mca"))
        }

        func controlled() async throws -> (WorldSession, AsyncReadGate<RegionFacts>) {
            let gate = AsyncReadGate<RegionFacts>(), first = FirstRead()
            let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: names,
                savedSearches: searches, defaults: defaults, cacheRoot: nil, readRegion: { dimension, region in
                    if dimension.id == "minecraft:the_nether", await first.take() { return await gate.read("nether") }
                    return try await RegionReader.scan(dimension, region: region)
                })
            self.resources.append(resources)
            gates.append(gate)
            let session = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
            sessions.append(session)
            return (session, gate)
        }

        func close() async {
            sessions.forEach { $0.close() }
            resources.forEach { $0.close() }
            for gate in gates { await gate.finishAll(with: emptyFacts) }
            for session in sessions { await session.waitUntilClosed() }
            for resource in resources { await resource.waitUntilClosed() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func completedMissingTargetIsUnavailableAfterIndexFinishes() async throws {
        try await withFixture { f in
            let session = try await f.open()
            await session.resources.index.waitForIndex()
            let portal = try #require(session.presentation.portalsByDimension["minecraft:overworld"]?.first)
            #expect(session.dimensions.map(\.id) == ["minecraft:overworld"])
            #expect(!session.resources.index.isIndexing && session.presentation.roundTrip(for: portal) == nil)
            #expect(!session.presentation.isWaitingForPortalLink(portal))
            #expect(session.presentation.portalsByDimension["minecraft:the_nether"] == nil)
        }
    }

    @Test func anActualTargetReadShowsLoadingThenKeepsTheKnownEmptyPrediction() async throws {
        try await withFixture { f in
            try f.addTarget()
            let (session, gate) = try await f.controlled()
            await gate.waitForRequest("nether")
            let portal = try #require(session.presentation.portalsByDimension["minecraft:overworld"]?.first)
            #expect(session.presentation.isWaitingForPortalLink(portal) && session.presentation.roundTrip(for: portal) == nil)
            // A cross-dimension jump can select its destination before that dimension publishes.
            // The opposite side is known, but its return still needs the selected portal's scan.
            let arriving = NetherPortal(dimension: NetherPortal.nether, blocks: [.init(x: 1, y: 2, z: 1)])
            #expect(session.presentation.roundTrip(for: arriving) == nil)
            #expect(session.presentation.isWaitingForPortalLink(arriving))
            await gate.finish("nether", with: try TestWorld.facts(dimensionID: "minecraft:the_nether"))
            await session.resources.index.waitForIndex()
            #expect(!session.presentation.isWaitingForPortalLink(portal))
            #expect(session.presentation.portalsByDimension["minecraft:the_nether"]?.isEmpty == true)
            if case .wouldCreateNewPortal? = session.presentation.roundTrip(for: portal) {} else { Issue.record("Known-empty target lost its existing prediction") }
        }
    }

    @Test func aNewCatalogTargetMovesFromUnavailableThroughPendingToReady() async throws {
        try await withFixture { f in
            let (session, gate) = try await f.controlled()
            await session.resources.index.waitForIndex()
            let portal = try #require(session.presentation.portalsByDimension["minecraft:overworld"]?.first)
            #expect(session.presentation.roundTrip(for: portal) == nil && !session.presentation.isWaitingForPortalLink(portal))
            try f.addTarget()
            let snapshot = try await WorldSnapshot.read(f.url)
            session.resources.includeDimensions(from: snapshot)
            snapshot.access.release()
            await gate.waitForRequest("nether")
            #expect(session.presentation.roundTrip(for: portal) == nil && session.presentation.isWaitingForPortalLink(portal))
            await gate.finish("nether", with: try TestWorld.facts(dimensionID: "minecraft:the_nether"))
            await session.resources.index.waitForIndex()
            #expect(!session.presentation.isWaitingForPortalLink(portal) && session.presentation.roundTrip(for: portal) != nil)
        }
    }

    @Test func unsupportedAndClosedTargetsNeverRemainLoading() async throws {
        try await withFixture { f in
            try f.addTarget()
            let (session, gate) = try await f.controlled()
            await gate.waitForRequest("nether")
            let portal = try #require(session.presentation.portalsByDimension["minecraft:overworld"]?.first)
            let unsupported = NetherPortal(dimension: "example:sky", blocks: [.init(x: 8, y: 2, z: 8)])
            #expect(session.presentation.roundTrip(for: unsupported) == nil && !session.presentation.isWaitingForPortalLink(unsupported))
            #expect(session.presentation.isWaitingForPortalLink(portal))
            session.resources.close()
            await gate.waitForCancellation("nether")
            #expect(!session.presentation.isWaitingForPortalLink(portal))
            await gate.finish("nether", with: try TestWorld.facts(dimensionID: "minecraft:the_nether"))
            await session.resources.waitUntilClosed()
            #expect(!session.resources.index.isWaitingForPortals(in: "minecraft:the_nether"))
        }
    }

    private actor FirstRead {
        private var used = false
        func take() -> Bool { defer { used = true }; return !used }
    }
}
