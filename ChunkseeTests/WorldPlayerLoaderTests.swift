import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldPlayerLoaderTests {
    private func player(_ x: Double) -> PlayerInfo {
        PlayerInfo(uuid: UUID(uuidString: "00000001-0000-0002-0000-000300000004")!, nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(x), .double(64), .double(0)])
        ]))
    }

    @Test func savesCoalesceAndFailedReadsRetainPlayersWhileSuccessfulEmptyReadsClearThem() async throws {
        let root = try TestWorld.make(chunks: []), work = BackgroundWork()
        let loader = WorldPlayerLoader(world: WorldReadSource(try World(contentsOf: root)), work: work, players: [player(1)])
        defer { loader.close(); work.close(); try? FileManager.default.removeItem(at: root) }
        let gate = AsyncReadGate<[PlayerInfo]?>(), numbers = ReadNumbers()
        loader.readPlayers = { _ in await gate.read(String(await numbers.next())) }
        loader.refresh()
        await gate.waitForRequest("0")
        loader.refresh(); loader.refresh()
        await gate.finish("0", with: [player(10)])
        await gate.waitForRequest("1")
        #expect(loader.snapshot.players.first?.position?.x == 10)
        await gate.finish("1", with: [player(20)])
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot.players.first?.position?.x == 20)
        #expect(await gate.requested == ["0", "1"])
        let previous = loader.snapshot
        loader.refresh()
        await gate.waitForRequest("2"); await gate.finish("2", with: nil)
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot === previous)
        #expect(await gate.requested == ["0", "1", "2"])
        loader.refresh()
        await gate.waitForRequest("3"); await gate.finish("3", with: [])
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot !== previous && loader.snapshot.players.isEmpty)
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test func replacingTheWorldAndClosingRejectRetiredReadsAndDrainThem() async throws {
        let root = try TestWorld.make(chunks: []), work = BackgroundWork()
        let world = try World(contentsOf: root)
        let loader = WorldPlayerLoader(world: WorldReadSource(world), work: work, players: [player(1)])
        defer { loader.close(); work.close(); try? FileManager.default.removeItem(at: root) }
        let gate = AsyncReadGate<[PlayerInfo]?>(), numbers = ReadNumbers()
        loader.readPlayers = { _ in await gate.read(String(await numbers.next())) }
        loader.refresh()
        await gate.waitForRequest("0")
        loader.replaceWorld(WorldReadSource(world), players: [player(30)])
        let replacement = loader.snapshot
        await gate.waitForCancellation("0")
        await gate.finish("0", with: [player(10)])
        await loader.work.waitUntilFinished()
        #expect(loader.snapshot === replacement && loader.snapshot.players.first?.position?.x == 30)
        loader.refresh()
        await gate.waitForRequest("1")
        loader.refresh()
        loader.close()
        let closed = loader.snapshot
        await gate.waitForCancellation("1")
        await gate.finish("1", with: [player(40)])
        work.close(); await work.waitUntilFinished()
        #expect(loader.snapshot === closed && closed.players.isEmpty)
        loader.refresh()
        #expect(await gate.requested == ["0", "1"])
    }
}
