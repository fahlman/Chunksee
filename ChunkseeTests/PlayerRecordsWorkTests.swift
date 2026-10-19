import Foundation
import ChunkseeKit
@testable import ChunkseeTestHost
import Testing

@Suite(.isolatedStores)
struct PlayerRecordsWorkTests {
    func records(deaths: Int) -> PlayerRecords {
        PlayerRecords(statistics: PlayerStatistics(values: ["minecraft:custom": ["minecraft:deaths": deaths]]))
    }

    @Test(.timeLimit(.minutes(1))) func closingOneInspectorDoesNotCancelOrWaitForItsSibling() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), work = BackgroundWork(), gate = AsyncReadGate<PlayerRecords>()
        let firstID = UUID(), secondID = UUID()
        let first = PlayerRecordsModel(world: world, work: work, read: { id, _ in await gate.read(id.uuidString) })
        let second = PlayerRecordsModel(world: world, work: work, read: { id, _ in await gate.read(id.uuidString) })
        let firstCall = Task { await first.load(firstID, name: nil) }
        let secondCall = Task { await second.load(secondID, name: nil) }
        await gate.waitForRequest(firstID.uuidString)
        await gate.waitForRequest(secondID.uuidString)
        first.close()
        await gate.waitForCancellation(firstID.uuidString)
        await gate.finish(firstID.uuidString, with: records(deaths: 1))
        await first.waitForReads() // Must return while the other inspector is still held.
        await firstCall.value
        #expect(first.records == nil && !work.isClosed)
        await first.load(firstID, name: nil)
        #expect(await gate.requested.count == 2)
        await gate.finish(secondID.uuidString, with: records(deaths: 2))
        await secondCall.value
        #expect(second.records?.statistics?.value("minecraft:deaths") == 2)
        second.close()
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingDrainsCancelledReplacementsAsWellAsTheCurrentRead() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let work = BackgroundWork(), gate = AsyncReadGate<PlayerRecords>()
        let model = PlayerRecordsModel(world: try World(contentsOf: url), work: work,
                                       read: { id, _ in await gate.read(id.uuidString) })
        let first = UUID(), second = UUID()
        let oldCall = Task { await model.load(first, name: nil) }
        await gate.waitForRequest(first.uuidString)
        let currentCall = Task { await model.load(second, name: nil) }
        await gate.waitForRequest(second.uuidString)
        await gate.waitForCancellation(first.uuidString)
        model.close()
        await gate.waitForCancellation(second.uuidString)
        var drained = false
        var waiting: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiting = Task {
                started.resume()
                await model.waitForReads()
                drained = true
            }
        }
        await gate.finish(second.uuidString, with: records(deaths: 2))
        await currentCall.value
        #expect(!drained)
        await gate.finish(first.uuidString, with: records(deaths: 1))
        await oldCall.value
        await waiting?.value
        #expect(drained && model.records == nil && model.uuid == nil)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func worldCloseCancelsEveryScopeAndRefusesAnotherRead() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), work = BackgroundWork(), gate = AsyncReadGate<PlayerRecords>()
        let firstID = UUID(), secondID = UUID()
        let first = PlayerRecordsModel(world: world, work: work, read: { id, _ in await gate.read(id.uuidString) })
        let second = PlayerRecordsModel(world: world, work: work, read: { id, _ in await gate.read(id.uuidString) })
        let firstCall = Task { await first.load(firstID, name: nil) }
        let secondCall = Task { await second.load(secondID, name: nil) }
        await gate.waitForRequest(firstID.uuidString)
        await gate.waitForRequest(secondID.uuidString)
        work.close()
        await gate.waitForCancellation(firstID.uuidString)
        await gate.waitForCancellation(secondID.uuidString)
        await gate.finish(firstID.uuidString, with: records(deaths: 1))
        await gate.finish(secondID.uuidString, with: records(deaths: 2))
        await firstCall.value
        await secondCall.value
        await work.waitUntilFinished()
        #expect(first.records == nil && second.records == nil)
        await first.load(firstID, name: nil)
        #expect(await gate.requested.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func droppingAScopeCancelsItsStillOwnedRead() async {
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
