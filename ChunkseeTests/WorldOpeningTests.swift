import ChunkseeKit
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldOpeningTests {
    private final class Fixture {
        let url: URL
        let defaults: UserDefaults
        let model: AppModel
        let probe: Reads
        let documents: [URL]
        var sessions: [WorldSession] = []
        var resources: [WorldResources] = []
        var tasks: [Task<DimensionSnapshot, any Error>] = []

        init(probe: Reads) throws {
            self.probe = probe
            let worldURL = try TestWorld.make(chunks: [])
            url = worldURL
            for name in ["the_nether", "the_end"] {
                try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/\(name)/region"), withIntermediateDirectories: true)
            }

            defaults = TestDefaults.make()
            documents = try World(contentsOf: worldURL).dimensions().map { $0.documentURL(inWorldAt: worldURL) }
            model = AppModel(defaults: defaults, cacheRoot: nil, readWorld: { try await probe.read($0) })
            try model.worldFolders.remember(url)
            try writePlayer(health: 20)
            let folder = url.appendingPathComponent("data/minecraft/maps")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let map = InGameMapTests().mapNBT(dimension: .string("minecraft:overworld"))
            try Data(Compression.deflate(map.serialized(), gzip: true)).write(to: folder.appendingPathComponent("3.dat"))
        }

        func writePlayer(health: Float) throws {
            let player = NBT.compound(["DataVersion": .int(5023), "UUID": .intArray([0, 0, 0, 66]),
                "Dimension": .string("minecraft:overworld"), "Pos": .list([.double(1), .double(64), .double(3)]), "Health": .float(health)])
            let folder = url.appendingPathComponent("players/data")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(Compression.deflate(player.serialized(), gzip: true)).write(to: folder.appendingPathComponent("00000000-0000-0000-0000-000000000042.dat"))
        }

        var reader: WorldDocument.Reader { WorldDocument.Reader(folders: model.worldFolders, model: model) }

        func start(_ document: URL) -> Task<DimensionSnapshot, any Error> {
            let reader = reader
            let task = Task {
                guard case .dimension(let snapshot) = try await reader.readFolder(document) else { throw WorldOpenError.notADimension }
                return snapshot
            }
            tasks.append(task)
            return task
        }

        func read(_ document: URL) async throws -> DimensionSnapshot {
            let snapshot = try await start(document).value
            if case .opening(let opening) = snapshot.source, let resource = opening.resources { resources.append(resource) }
            return snapshot
        }

        func attach(_ snapshot: DimensionSnapshot) async throws -> WorldSession {
            let session = try await snapshot.makeSession(in: model)
            sessions.append(session)
            resources.append(session.resources)
            return session
        }

        func close() async {
            tasks.forEach { $0.cancel() }
            await probe.releaseAll()
            for task in tasks {
                if case .success(let snapshot) = await task.result,
                   case .opening(let opening) = snapshot.source {
                    if let resource = opening.resources { resources.append(resource) }
                    opening.finish()
                }
            }
            sessions.forEach { $0.close() }
            resources.forEach { $0.close() }
            for session in sessions { await session.waitUntilClosed() }
            for resource in resources { await resource.waitUntilClosed() }
            tasks = []

            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(paused: Bool = false, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(probe: Reads(paused: paused))
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    /// Observe the actual owner transition, never a sleep or a fixed yield count.
    private func waitUntil(_ predicate: @escaping @MainActor @Sendable () -> Bool) async {
        let changes = Observations<Void, Never>.untilFinished { predicate() ? .finish : .next(()) }
        for await _ in changes {}
    }

    @Test func threeSequentialDocumentsAndALaterReaderShareOneWorldReadThenReopenFresh() async throws {
        try await withFixture { f in
            #expect(f.documents.count == 3)
            var snapshots: [DimensionSnapshot] = []
            for url in f.documents {
                let snapshot = try await f.read(url)
                let session = try await f.attach(snapshot)
                snapshots.append(snapshot)
                #expect(session.players.count == 1 && session.resources.details.maps.map(\.id) == [3])
                #expect(session.resources.dimensions.count == 3 && session.selectedDimensionID == snapshot.dimensionID)
            }
            #expect(Set(f.sessions.map { ObjectIdentifier($0.resources) }).count == 1)
            let resource = try #require(f.sessions.first?.resources)
            let later = try await f.read(f.documents[0])
            if case .opening(let opening) = later.source { #expect(opening.resources === resource) }
            else { Issue.record("Initial read did not use the shared owner") }
            later.discardUnused()
            #expect(await f.probe.count == 1)
            print("Shared world opening full reads: 1; documents: 3 plus later reader; canonical world resources: 1; players/maps: 1/1")
            f.sessions.forEach { $0.close() }
            for session in f.sessions { await session.waitUntilClosed() }
            #expect(resource.isClosed)
            for snapshot in snapshots {
                if case .opening(let opening) = snapshot.source { #expect(opening.resources == nil) }
            }
            try f.writePlayer(health: 9)
            let reopened = try await f.read(f.documents[0])
            let next = try await f.attach(reopened)
            #expect(next.resources !== resource && next.players.first?.health == 9)
            #expect(await f.probe.count == 2)
        }
    }

    @Test func simultaneousReadersSharePendingWorkAndOneCancellationDoesNotEndSiblings() async throws {
        try await withFixture(paused: true) { f in
            let tasks = f.documents.map { f.start($0) }
            await f.probe.waitForStarts(1)
            await waitUntil { f.model.openingRequestCount == 3 }
            tasks[0].cancel()
            await waitUntil { f.model.openingRequestCount == 2 }
            await f.probe.release(1)
            await #expect(throws: CancellationError.self) { try await tasks[0].value }
            for task in tasks.dropFirst() {
                let session = try await f.attach(try await task.value)
                #expect(session.players.count == 1 && session.resources.details.maps.count == 1)
            }
            #expect(await f.probe.count == 1)
            #expect(Set(f.sessions.map { ObjectIdentifier($0.resources) }).count == 1)
        }
    }

    @Test func allCanceledWorkDrainsWithoutRemovingAReplacementOpening() async throws {
        try await withFixture(paused: true) { f in
            let old = f.start(f.documents[0])
            await f.probe.waitForStarts(1)
            old.cancel()
            await f.probe.waitForCancellation(1)
            await waitUntil { f.model.openingRequestCount == 0 }
            let replacement = f.start(f.documents[1])
            await f.probe.waitForStarts(2)
            await waitUntil { f.model.openingRequestCount == 1 }
            await f.probe.release(1)
            await #expect(throws: CancellationError.self) { try await old.value }
            #expect(f.model.openingRequestCount == 1)
            await f.probe.release(2)
            let session = try await f.attach(try await replacement.value)
            #expect(!session.resources.isClosed && session.players.count == 1)
            #expect(await f.probe.count == 2)
        }
    }

    @Test func aPendingDocumentKeepsAccessWhenThePreviousLastSessionCloses() async throws {
        try await withFixture { f in
            let first = try await f.attach(try await f.read(f.documents[0]))
            let pending = try await f.read(f.documents[1])
            let resource = first.resources
            first.close()
            await first.waitUntilClosed()
            #expect(!resource.isClosed)
            let second = try await f.attach(pending)
            #expect(second.resources === resource && second.map != nil)
            second.close()
            await second.waitUntilClosed()
            #expect(resource.isClosed)
            #expect(await f.probe.count == 1)
        }
    }

    @Test func unusedAndDroppedSnapshotsCloseWithoutKeepingACompletedMetadataCache() async throws {
        try await withFixture { f in
            let unused = try await f.read(f.documents[0])
            guard case .opening(let opening) = unused.source, let resource = opening.resources else { Issue.record("Missing opening"); return }
            unused.discardUnused()
            unused.discardUnused()
            #expect(resource.isClosed)
            await resource.waitUntilClosed()
            @MainActor func readAndDrop() async throws -> WorldResources {
                guard case .dimension(let snapshot) = try await f.reader.readFolder(f.documents[1]),
                      case .opening(let opening) = snapshot.source, let resource = opening.resources else { throw WorldOpenError.unreadable }
                return resource
            }
            let dropped = try await readAndDrop()
            f.resources.append(dropped)
            await waitUntil { dropped.isClosed }
            await dropped.waitUntilClosed()
            #expect(await f.probe.count == 2)
        }
    }

    @Test func invalidDimensionsFailAndExplicitRereadsUpdateTheSharedSnapshot() async throws {
        try await withFixture { f in
            let invalid = f.start(f.url.appendingPathComponent("dimensions"))
            await #expect(throws: WorldOpenError.notADimension) { try await invalid.value }
            // Reuse the same reader across the phase change, as well as the same document owner.
            let reader = WorldDocument.Reader(folders: f.model.worldFolders, model: f.model,
                                               reuseOpenWorld: { f.sessions.isEmpty })
            guard case .dimension(let initial) = try await reader.readFolder(f.documents[0]) else { Issue.record("Missing dimension"); return }
            let session = try await f.attach(initial)
            #expect(await f.probe.count == 2)
            let originalAccess = session.resources.access
            try f.writePlayer(health: 9)
            guard case .dimension(let fresh) = try await reader.readFolder(f.documents[0]),
                  case .opening(let opening) = fresh.source else { Issue.record("Reread did not use the shared owner"); return }
            #expect(opening.resources === session.resources && session.players.first?.health == 9)
            #expect(originalAccess !== session.resources.access && await f.probe.count == 3)
            fresh.discardUnused()
            #expect(!session.resources.isClosed)
            let coordinated = try await DimensionSnapshot.read(f.documents[1], folders: f.model.worldFolders, coordinator: NSFileCoordinator())
            if case .snapshot(let snapshot) = coordinated.source { #expect(snapshot.players.first?.health == 9) }
            else { Issue.record("Coordinated read reused initial resources") }
            coordinated.discardUnused()
        }
    }

    @Test func restoredReadersCanRetryAfterAWorldFolderSuppliesMissingAccess() async throws {
        let game = try ItemPictureFixture()
        defer { game.remove() }
        try await withFixture(paused: true) { f in
            f.model.names.minecraft.choose(game.root)
            f.defaults.removeObject(forKey: "worldFolderBookmarks")
            for document in f.documents {
                let failed = f.start(document)
                await #expect(throws: WorldOpenError.notAWorld) { try await failed.value }
            }
            #expect(await f.probe.count == 0)
            guard case .world(let urls) = try await f.reader.readFolder(f.url) else {
                Issue.record("Opening the world did not supply its dimension URLs"); return
            }
            #expect(Set(urls) == Set(f.documents))
            // Model boundary for #484: restoration and the folder redirect can both request
            // the same dimensions. Native document restoration itself needs a separate check.
            let waiting = (urls + urls).map { f.start($0) }
            await f.probe.waitForStarts(1)
            await waitUntil { f.model.openingRequestCount == waiting.count }
            guard case .world(let repeated) = try await f.reader.readFolder(f.url) else {
                Issue.record("A repeated folder opening did not redirect"); return
            }
            #expect(Set(repeated) == Set(urls))
            #expect(await f.probe.count == 1)
            await f.probe.release(1)
            for request in waiting { _ = try await f.attach(request.value) }
            #expect(f.sessions.count == waiting.count)
            #expect(Set(f.sessions.map { ObjectIdentifier($0.resources) }).count == 1)
            #expect(f.model.openingRequestCount == 0)
            await f.model.names.minecraft.waitUntilIdle()
        }
    }

    @Test func aWorldFolderStillRedirectsToItsNativeDocumentsWithoutStartingAFullWorldRead() async throws {
        try await withFixture { f in
            guard case .world(let urls) = try await f.reader.readFolder(f.url) else { Issue.record("World did not redirect"); return }
            #expect(Set(urls) == Set(f.documents))
            #expect(await f.probe.count == 0 && f.model.openingRequestCount == 0)
        }
    }

    @Test func differentWorldFoldersKeepSeparateOpeningReadsAndPlayerData() async throws {
        let first = try Fixture(probe: Reads(paused: false)), second = try Fixture(probe: Reads(paused: false))
        do {
            try second.writePlayer(health: 7)
            try first.model.worldFolders.remember(second.url)
            let one = try await first.attach(try await first.read(first.documents[0]))
            let two = try await first.attach(try await first.read(second.documents[0]))
            #expect(one.resources !== two.resources)
            #expect(one.players.first?.health == 20 && two.players.first?.health == 7)
            let late = try await first.read(first.documents[1])
            let sibling = try await first.attach(late)
            #expect(sibling.resources === one.resources)
            #expect(await first.probe.count == 2)
        } catch {
            await first.close(); await second.close()
            throw error
        }
        await first.close(); await second.close()
    }

    @Test func aliasesUseResolvedIdentityAndUnknownLiveCatalogPathsStillGetFreshValidation() async throws {
        try await withFixture { f in
            let session = try await f.attach(try await f.read(f.documents[0]))
            let alias = f.url.appendingPathComponent("Dimension Shortcut")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.documents[1])
            let aliased = try await f.read(alias)
            if case .opening(let opening) = aliased.source { #expect(opening.resources === session.resources) }
            else { Issue.record("Alias did not reuse resolved dimension identity") }
            aliased.discardUnused()
            #expect(await f.probe.count == 1)
            let newDimension = f.url.appendingPathComponent("dimensions/example/new_dimension")
            try FileManager.default.createDirectory(at: newDimension.appendingPathComponent("region"), withIntermediateDirectories: true)
            guard case .dimension(let value) = try await f.reader.readFolder(newDimension),
                  case .opening(let fresh) = value.source else { Issue.record("Unknown catalog path was not freshly validated"); return }
            #expect(value.dimensionID == "example:new_dimension" && fresh.resources === session.resources)
            #expect(session.resources.dimensions.contains { $0.id == value.dimensionID })
            #expect(await f.probe.count == 2)
            value.discardUnused()
            #expect(!session.resources.isClosed)
        }
    }

    private actor Reads {
        private(set) var count = 0
        private var paused: Bool
        private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        private var starts: [(Int, CheckedContinuation<Void, Never>)] = []
        private var cancellations: Set<Int> = []
        private var canceled: [Int: [CheckedContinuation<Void, Never>]] = [:]

        init(paused: Bool) { self.paused = paused }

        func read(_ url: URL) async throws -> WorldSnapshot {
            count += 1
            let id = count
            return try await withTaskCancellationHandler {
                if paused { await withCheckedContinuation { gates[id] = $0; announceStart() } }
                else { announceStart() }
                try Task.checkCancellation()
                return try await WorldSnapshot.read(url)
            } onCancel: {
                Task { await self.recordCancellation(id) }
            }
        }

        private func announceStart() {
            let ready = starts.filter { count >= $0.0 }
            starts.removeAll { count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }

        func waitForStarts(_ count: Int) async {
            if self.count >= count { return }
            await withCheckedContinuation { starts.append((count, $0)) }
        }

        private func recordCancellation(_ id: Int) {
            cancellations.insert(id)
            canceled.removeValue(forKey: id)?.forEach { $0.resume() }
        }

        func waitForCancellation(_ id: Int) async {
            if cancellations.contains(id) { return }
            await withCheckedContinuation { canceled[id, default: []].append($0) }
        }

        func release(_ id: Int) { gates.removeValue(forKey: id)?.resume() }
        func releaseAll() {
            paused = false
            let held = gates.values
            gates = [:]
            held.forEach { $0.resume() }
        }
    }
}
