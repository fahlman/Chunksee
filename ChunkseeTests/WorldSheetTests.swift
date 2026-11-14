import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import SwiftUI
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

    @Test func inspectorBindingCannotChangeSelectionBehindAnySheet() async throws {
        let root = try TestWorld.make(chunks: []), player = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.writeGzippedNBT(.compound([
            "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(0), .double(64), .double(0)])
        ]), to: root.appendingPathComponent("players/data/\(player.uuidString.lowercased()).dat"))
        let resources = try await resources(root)
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        defer { first.close(); second.close() }
        await first.search.waitForIndex(); await second.search.waitForIndex()
        let inspector = WorldView.inspectorBinding(for: first) { true }
        let otherInspector = WorldView.inspectorBinding(for: second) { true }
        let presentations: [(WorldSession) -> Void] = [
            { $0.presentSheet(.coordinates) },
            { $0.presentSheet(.imageExport) },
            { $0.presentSheet(.blockFilter) },
            { $0.annotations.savePlace(at: CGPoint(x: -9, y: 14)) },
            { $0.annotations.planPortal(at: CGPoint(x: -9, y: 14), y: 64) },
            { $0.showStatistics(for: player) }
        ]
        for present in presentations {
            first.selection.choose(nil)
            present(first)
            let active = try #require(first.sheet?.id)
            inspector.wrappedValue = true
            #expect(!inspector.wrappedValue && first.selection.sidebarSelection == nil)
            #expect(first.sheet?.id == active)
            first.sheet = nil
            inspector.wrappedValue = true
            #expect(inspector.wrappedValue && first.selection.sidebarSelection == .worldInfo)

            first.selection.choose(.player(player))
            try #require(first.selection.inspector == .player(player))
            present(first)
            inspector.wrappedValue = false
            #expect(inspector.wrappedValue && first.selection.inspector == .player(player))
            #expect(first.selection.sidebarSelection == .player(player))
            otherInspector.wrappedValue = true
            #expect(otherInspector.wrappedValue && second.selection.sidebarSelection == .worldInfo)
            otherInspector.wrappedValue = false
            #expect(!otherInspector.wrappedValue && first.selection.inspector == .player(player))
            first.sheet = nil
            inspector.wrappedValue = false
            #expect(!inspector.wrappedValue)
        }
        first.selection.choose(nil)
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed()
        inspector.wrappedValue = true
        #expect(!inspector.wrappedValue && first.selection.sidebarSelection == nil)
    }

    @Test(arguments: [true, false])
    func retainedInspectorBindingChecksTheCurrentWindowAtEachWrite(sharedWorld: Bool) async throws {
        let roots = try (0..<(sharedWorld ? 1 : 2)).map { _ in try TestWorld.make(chunks: []) }
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        let firstResources = try await resources(roots[0])
        var secondResources = firstResources
        if !sharedWorld { secondResources = try await resources(roots[1]) }
        let first = WorldSession(resources: firstResources), second = WorldSession(resources: secondResources)
        defer { first.close(); second.close() }
        try #require(first.viewID != second.viewID && first.selectedDimensionID == second.selectedDimensionID)
        try #require((first.resources === second.resources) == sharedWorld)
        var currentWindow: UUID? = first.viewID
        let firstBinding = WorldView.inspectorBinding(for: first) { currentWindow == first.viewID }
        let secondBinding = WorldView.inspectorBinding(for: second) { currentWindow == second.viewID }

        first.selection.choose(.storage)
        try #require(firstBinding.wrappedValue && !secondBinding.wrappedValue)
        // Both bindings were created while the first window was current. They must
        // use subsequent activity, including an inactive app, without being rebuilt.
        currentWindow = nil
        firstBinding.wrappedValue = false
        secondBinding.wrappedValue = true
        #expect(firstBinding.wrappedValue && first.selection.sidebarSelection == .storage)
        #expect(!secondBinding.wrappedValue && second.selection.sidebarSelection == nil)
        #expect(second.selection.sidebarRevealRequest == nil)

        // Deliberate Hide retains the selected identity; an inactive Show cannot override it.
        currentWindow = first.viewID
        firstBinding.wrappedValue = false
        currentWindow = second.viewID
        firstBinding.wrappedValue = true
        #expect(!firstBinding.wrappedValue && first.selection.sidebarSelection == .storage)
        secondBinding.wrappedValue = true
        #expect(secondBinding.wrappedValue && second.selection.sidebarSelection == .worldInfo)
        let previousReveal = try #require(second.selection.sidebarRevealRequest)
        secondBinding.wrappedValue = true
        #expect(second.selection.sidebarRevealRequest != previousReveal)
        currentWindow = first.viewID
        secondBinding.wrappedValue = false
        #expect(secondBinding.wrappedValue && second.selection.sidebarSelection == .worldInfo)

        firstBinding.wrappedValue = true
        #expect(first.selection.inspector == .storage && first.selection.sidebarSelection == .storage)
        firstBinding.wrappedValue = false
        currentWindow = nil
        first.selection.choose(.storage)
        #expect(firstBinding.wrappedValue && first.selection.sidebarSelection == .storage)
        #expect(secondBinding.wrappedValue && second.selection.sidebarSelection == .worldInfo)

        first.close()
        await first.waitUntilClosed()
        let closedVisibility = firstBinding.wrappedValue
        let closedSelection = first.selection.sidebarSelection
        currentWindow = first.viewID
        for shown in [true, false] { firstBinding.wrappedValue = shown }
        #expect(firstBinding.wrappedValue == closedVisibility && first.selection.sidebarSelection == closedSelection)
        #expect(secondBinding.wrappedValue && second.selection.sidebarSelection == .worldInfo)
        second.close()
        await second.waitUntilClosed()
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
