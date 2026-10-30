import Foundation
import ChunkseeKit
import Observation
@testable import ChunkseeTestHost
import Testing

@Suite(.isolatedStores, .timeLimit(.minutes(1)))
struct PlayerRecordsWorkTests {
    @Observable final class Input {
        var value: PlayerRecordStore.GameSource? = .init(generation: UUID(), selection: .loaded(nil))
    }

    private final class Fixture {
        let root: URL
        let work = BackgroundWork()
        let input = Input()
        let store: PlayerRecordStore
        init() throws {
            root = try TestWorld.make(chunks: [])
            let input = input
            store = PlayerRecordStore(world: try World(contentsOf: root), work: work,
                names: PlayerNames(defaults: TestDefaults.make()), gameSource: { input.value })
        }
        func close() { store.close(); work.close() }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    nonisolated private func records(deaths: Int) -> PlayerRecords {
        PlayerRecords(statistics: PlayerStatistics(values: ["minecraft:custom": ["minecraft:deaths": deaths]]))
    }

    @Test func sharedRequestsCoalesceSavesAndKeepTheCompletedValueOnFailure() async throws {
        let fixture = try Fixture(), gate = AsyncReadGate<Result<PlayerRecords, CocoaError>>(), numbers = ReadNumbers()
        defer { fixture.close(); fixture.remove() }
        let store = fixture.store, player = UUID()
        store.read = { _, _, _, _, _ in .complete(try await gate.read(String(await numbers.next())).get()) }
        let first = try #require(store.acquire(player)), second = try #require(store.acquire(player))
        await gate.waitForRequest("0")
        store.refresh(); store.refresh(); store.refresh()
        await gate.finish("0", with: .success(records(deaths: 4)))
        await gate.waitForRequest("1")
        #expect(first.records == records(deaths: 4) && second.records == first.records)
        await gate.finish("1", with: .failure(CocoaError(.fileReadUnknown)))
        await store.waitUntilFinished()
        #expect(first.records == records(deaths: 4) && second.records == first.records)
        #expect(await gate.requested == ["0", "1"])
        store.refresh()
        await gate.waitForRequest("2"); await gate.finish("2", with: .success(PlayerRecords()))
        await store.waitUntilFinished()
        #expect(first.records == PlayerRecords() && second.records == first.records)
        first.close(); second.close()
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func closingOneHandleCannotCancelAnotherWindowsSharedRead() async throws {
        let fixture = try Fixture(), gate = AsyncReadGate<Void>(), player = UUID()
        defer { fixture.close(); fixture.remove() }
        fixture.store.read = { _, _, _, _, _ in
            await gate.read("shared")
            return .complete(records(deaths: Task.isCancelled ? -1 : 2))
        }
        let first = try #require(fixture.store.acquire(player)), second = try #require(fixture.store.acquire(player))
        await gate.waitForRequest("shared")
        first.close()
        #expect(first.records == nil)
        await gate.finish("shared", with: ())
        await fixture.store.waitUntilFinished()
        #expect(second.records == records(deaths: 2))
        #expect(await gate.requested == ["shared"])
        second.close()
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func differentPlayersRemainIndependentAndReleasedReadsCannotReplaceNewOnes() async throws {
        let fixture = try Fixture(), gate = AsyncReadGate<PlayerRecords>(), firstID = UUID(), secondID = UUID()
        defer { fixture.close(); fixture.remove() }
        fixture.store.read = { _, uuid, _, _, _ in .complete(await gate.read(uuid.uuidString)) }
        let first = try #require(fixture.store.acquire(firstID)), second = try #require(fixture.store.acquire(secondID))
        await gate.waitForRequest(firstID.uuidString); await gate.waitForRequest(secondID.uuidString)
        first.close()
        await gate.waitForCancellation(firstID.uuidString)
        let replacement = try #require(fixture.store.acquire(firstID))
        await gate.waitForRequest(firstID.uuidString, count: 2)
        #expect(first.records == nil && replacement.records == nil)
        await gate.finish(firstID.uuidString, with: records(deaths: 1))
        await gate.finish(firstID.uuidString, with: records(deaths: 3))
        await gate.finish(secondID.uuidString, with: records(deaths: 2))
        await fixture.store.waitUntilFinished()
        #expect(first.records == nil && replacement.records == records(deaths: 3))
        #expect(second.records == records(deaths: 2))
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func sourceReplacementRejectsRetiredResultsEvenWhenReturningToTheSameSource() async throws {
        let fixture = try Fixture(), gate = AsyncReadGate<PlayerRecords>(), numbers = ReadNumbers()
        defer { fixture.close(); fixture.remove() }
        fixture.store.read = { _, _, _, _, _ in .complete(await gate.read(String(await numbers.next()))) }
        let originalSource = fixture.input.value
        let handle = try #require(fixture.store.acquire(UUID()))
        await gate.waitForRequest("0")
        fixture.input.value = .init(generation: UUID(), selection: .loaded(nil))
        await gate.waitForCancellation("0"); await gate.waitForRequest("1")
        fixture.input.value = originalSource
        await gate.waitForCancellation("1"); await gate.waitForRequest("2")
        await gate.finish("2", with: records(deaths: 3))
        for await value in Observations({ handle.records }) where value == records(deaths: 3) { break }
        await gate.finish("1", with: records(deaths: 2)); await gate.finish("0", with: records(deaths: 1))
        await fixture.store.waitUntilFinished()
        #expect(handle.records == records(deaths: 3))
        fixture.close(); await fixture.work.waitUntilFinished()
    }

    @Test func closingTheWorldCancelsAllPlayersClearsValuesAndRefusesNewDemand() async throws {
        let fixture = try Fixture(), gate = AsyncReadGate<PlayerRecords>(), firstID = UUID(), secondID = UUID()
        defer { fixture.close(); fixture.remove() }
        fixture.store.read = { _, uuid, _, _, _ in .complete(await gate.read(uuid.uuidString)) }
        let first = try #require(fixture.store.acquire(firstID)), second = try #require(fixture.store.acquire(secondID))
        await gate.waitForRequest(firstID.uuidString); await gate.waitForRequest(secondID.uuidString)
        fixture.close()
        await gate.waitForCancellation(firstID.uuidString); await gate.waitForCancellation(secondID.uuidString)
        await gate.finish(firstID.uuidString, with: records(deaths: 1))
        await gate.finish(secondID.uuidString, with: records(deaths: 2))
        await fixture.work.waitUntilFinished()
        #expect(first.records == nil && second.records == nil && fixture.store.acquire(firstID) == nil)
        #expect(await gate.requested.count == 2)
    }

    @Test func droppingTheLastHandleCancelsItsReadButKeepsTheWorldOpen() async throws {
        let fixture = try Fixture(), gate = AsyncReadGate<PlayerRecords>(), player = UUID()
        defer { fixture.close(); fixture.remove() }
        fixture.store.read = { _, _, _, _, _ in .complete(await gate.read("pending")) }
        var handle = fixture.store.acquire(player)
        #expect(handle != nil)
        await gate.waitForRequest("pending")
        handle = nil
        await gate.waitForCancellation("pending")
        await gate.finish("pending", with: records(deaths: 1))
        await fixture.work.waitUntilFinished()
        #expect(!fixture.work.isClosed)
    }

    @Test func droppingAScopeCancelsItsStillOwnedRead() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Void>()
        var scope: BackgroundWork.Scope? = work.makeScope()
        scope?.start(priority: .utility) { await gate.read("pending") }
        await gate.waitForRequest("pending")
        scope = nil
        await gate.waitForCancellation("pending")
        await gate.finish("pending", with: ())
        await work.waitUntilFinished()
        work.close()
    }
}
