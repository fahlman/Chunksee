import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldSheetTests {
    private func resources(_ root: URL) async throws -> WorldResources {
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        resources.refreshDelay = .zero
        return resources
    }

    @Test func everySheetRemovesOnlyItsOwnWindowsCommandTargetAndDismissalRestoresIt() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        defer { first.close(); second.close() }
        let viewport = try #require(first.map?.viewport)
        let player = UUID()
        let presentations: [(WorldSession) -> Void] = [
            { $0.presentSheet(.coordinates) },
            { $0.presentSheet(.imageExport) },
            { $0.presentSheet(.blockFilter) },
            { $0.annotations.savePlace(at: CGPoint(x: -9, y: 14)) },
            { $0.annotations.planPortal(at: CGPoint(x: -9, y: 14), y: 64) },
            { $0.showStatistics(for: player) }
        ]
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        defer { changed.finish() }
        var iterator = changes.makeAsyncIterator()
        for present in presentations {
            let target = withObservationTracking { first.commandTarget } onChange: { changed.yield(()) }
            #expect(target === first)
            present(first)
            try #require(await iterator.next() != nil)
            let active = try #require(first.sheet)
            #expect(first.commandTarget == nil && second.commandTarget === second)
            first.commandTarget?.map?.zoom(by: 2)
            first.commandTarget?.annotations.savePlace()
            #expect(first.sheet?.id == active.id && first.map?.viewport == viewport)
            second.commandTarget?.presentSheet(.coordinates)
            #expect(second.sheet?.id == .coordinates && first.sheet?.id == active.id)
            second.sheet = nil
            first.sheet = nil
            #expect(first.commandTarget === first && second.commandTarget === second)
        }
        #expect(first.savedPlaces.all.isEmpty)
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed()
        first.presentSheet(.coordinates)
        first.showStatistics(for: player)
        #expect(first.sheet == nil && first.commandTarget == nil)
    }

    private func writeStatistics(_ deaths: Int, for player: UUID, in root: URL) throws -> URL {
        let file = root.appendingPathComponent("players/stats/\(player.uuidString.lowercased()).json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["stats": ["minecraft:custom": ["minecraft:deaths": deaths]]]).write(to: file)
        return file
    }

    private func deaths(_ handle: PlayerRecordStore.Handle?) -> Int? {
        handle?.records?.statistics?.values["minecraft:custom"]?["minecraft:deaths"]
    }

    @Test func statisticsKeepLiveSharedRecordsWhenTheInspectorChangesAndReleaseOnlyTheirOwnDemand() async throws {
        let root = try TestWorld.make(chunks: []), player = UUID(), other = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        for uuid in [player, other] {
            try Fixtures.writeGzippedNBT(.compound([
                "Dimension": .string("minecraft:overworld"),
                "Pos": .list([.double(0), .double(64), .double(0)])
            ]), to: root.appendingPathComponent("players/data/\(uuid.uuidString.lowercased()).dat"))
        }
        let file = try writeStatistics(4, for: player, in: root)
        _ = try writeStatistics(8, for: other, in: root)
        let resources = try await resources(root), gate = AsyncReadGate<Void>()
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        defer { first.close(); second.close() }
        await first.search.waitForIndex(); await second.search.waitForIndex()
        let read = resources.playerRecords.read
        resources.playerRecords.read = { world, uuid, name, library, previous in
            await gate.read(uuid.uuidString)
            return try await read(world, uuid, name, library, previous)
        }
        do {
            first.selection.choose(.player(player))
            first.showStatistics(for: player)
            second.showStatistics(for: player)
            let firstRecords = try #require(first.sheet?.playerRecords)
            let secondRecords = try #require(second.sheet?.playerRecords)
            await gate.waitForRequest(player.uuidString)
            await gate.releaseAllAndFuture(with: ())
            await resources.playerRecords.waitUntilFinished()
            #expect(await gate.requested == [player.uuidString])
            #expect(deaths(firstRecords) == 4 && deaths(secondRecords) == 4)
            #expect(deaths(first.selection.playerRecords) == 4)

            first.selection.choose(.worldInfo)
            #expect(first.selection.playerRecords == nil && deaths(firstRecords) == 4)
            let (changes, changed) = AsyncStream.makeStream(of: Void.self)
            defer { changed.finish() }
            var iterator = changes.makeAsyncIterator()
            _ = withObservationTracking { first.sheet?.playerRecords?.records?.rows } onChange: { changed.yield(()) }
            _ = try writeStatistics(5, for: player, in: root)
            resources.worldChanged([file])
            try #require(await iterator.next() != nil)
            await resources.waitForRefresh()
            await resources.playerRecords.waitUntilFinished()
            #expect(deaths(firstRecords) == 5 && deaths(secondRecords) == 5)

            second.showStatistics(for: other)
            let otherRecords = try #require(second.sheet?.playerRecords)
            #expect(secondRecords.records == nil && otherRecords.records == nil && deaths(firstRecords) == 5)
            await resources.playerRecords.waitUntilFinished()
            #expect(deaths(otherRecords) == 8 && deaths(firstRecords) == 5)
            second.sheet = nil
            #expect(otherRecords.records == nil && second.commandTarget === second)
            second.showStatistics(for: player)
            let surviving = try #require(second.sheet?.playerRecords)
            #expect(deaths(surviving) == 5)
            first.close(); await first.waitUntilClosed()
            #expect(firstRecords.records == nil && first.sheet == nil && !resources.isClosed)
            #expect(deaths(surviving) == 5)
            second.presentSheet(.coordinates)
            #expect(surviving.records == nil && second.sheet?.id == .coordinates)
            second.close(); await second.waitUntilClosed()
            #expect(second.sheet == nil && second.commandTarget == nil)
        } catch {
            await gate.releaseAllAndFuture(with: ())
            first.close(); second.close()
            await first.waitUntilClosed(); await second.waitUntilClosed()
            throw error
        }
    }

    @Test func dismissedAndClosedStatisticsCannotPublishTheirLateReadsIntoAReplacement() async throws {
        let root = try TestWorld.make(chunks: []), player = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root), gate = AsyncReadGate<PlayerRecords>(), numbers = ReadNumbers()
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        defer { first.close(); second.close() }
        resources.playerRecords.read = { _, _, _, _, _ in .complete(await gate.read(String(await numbers.next()))) }
        do {
            first.showStatistics(for: player)
            let dismissed = try #require(first.sheet?.playerRecords)
            await gate.waitForRequest("0")
            first.sheet = nil
            await gate.waitForCancellation("0")
            first.showStatistics(for: player)
            let closing = try #require(first.sheet?.playerRecords)
            await gate.waitForRequest("1")
            first.close(); await first.waitUntilClosed()
            await gate.waitForCancellation("1")
            second.presentSheet(.coordinates)
            await gate.finish("0", with: PlayerRecords())
            await gate.finish("1", with: PlayerRecords())
            await resources.backgroundWork.waitUntilFinished()
            #expect(dismissed.records == nil && closing.records == nil && first.sheet == nil)
            #expect(second.sheet?.id == .coordinates && !resources.isClosed)
            first.showStatistics(for: player)
            #expect(await gate.requested == ["0", "1"])
            second.close(); await second.waitUntilClosed()
        } catch {
            await gate.releaseAllAndFuture(with: PlayerRecords())
            first.close(); second.close()
            await first.waitUntilClosed(); await second.waitUntilClosed()
            throw error
        }
    }
}
