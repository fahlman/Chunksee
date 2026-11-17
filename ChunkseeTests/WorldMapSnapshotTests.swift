import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldMapSnapshotTests {
    @discardableResult
    private func write(_ id: Int, at root: URL, center: Int32 = 0, color: Int8 = 4, legacy: Bool = false) throws -> URL {
        let file = root.appendingPathComponent(legacy ? "data/map_\(id).dat" : "data/minecraft/maps/\(id).dat")
        try Fixtures.writeGzippedNBT(.compound(["data": .compound([
            "dimension": .string("minecraft:overworld"), "scale": .byte(0),
            "xCenter": .int(center), "zCenter": .int(0),
            "colors": .byteArray([Int8](repeating: color, count: MapItem.size * MapItem.size)),
        ])]), to: file)
        return file
    }

    private func open(_ root: URL) async throws -> WorldResources {
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root),
            names: PlayerNames(defaults: defaults), savedSearches: SavedSearches(defaults: defaults),
            defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.waitForRefresh(); await resources.index.waitForIndex()
        resources.refreshDelay = .zero
        return resources
    }

    @Test(arguments: [false, true])
    func unavailableWorldRetainsSavedMapsAndQueuedDeletionRefresh(lostDuringRead: Bool) async throws {
        let root = try TestWorld.make(chunks: []), parked = root.appendingPathExtension("unavailable")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: parked) }
        let file = try write(1, at: root), resources = try await open(root)
        let session = WorldSession(resources: resources), gate = AsyncReadGate<Void>()
        do {
            let map = try #require(resources.details.maps.first)
            session.selection.show(map)
            let image = try #require(MapContent(session: session).inGameMap?.image)
            if lostDuringRead {
                resources.readMaps = { source, previous in
                    await gate.read("held")
                    return try await source.read(retaining: previous)
                }
                resources.worldChanged([file]); await gate.waitForRequest("held")
            }
            try FileManager.default.moveItem(at: root, to: parked)
            await gate.releaseAllAndFuture(with: ())
            resources.worldChanged([root]); await resources.waitForRefresh()
            #expect(resources.details.maps == [map])
            #expect(session.selection.sidebarSelection == .inGameMap(1))
            #expect(MapContent(session: session).inGameMap?.image === image)

            try FileManager.default.moveItem(at: parked, to: root)
            try FileManager.default.removeItem(at: file)
            resources.readMaps = { try await $0.read(retaining: $1) }
            // This event normally refreshes terrain only. The broad invalidation from the
            // unavailable interval must still reconcile saved maps when access returns.
            let dimension = try #require(resources.dimensions.first)
            resources.worldChanged([dimension.regionURL(at: .init(x: 0, z: 0))])
            await resources.waitForRefresh()
            #expect(resources.details.maps.isEmpty)
            #expect(session.selection.sidebarSelection == nil)
        } catch {
            session.close(); resources.close(); await gate.releaseAllAndFuture(with: ())
            await resources.waitUntilClosed(); throw error
        }
        session.close(); resources.close(); await resources.waitUntilClosed()
    }

    @Test(arguments: [false, true])
    func savedChangesReachSiblingSelectionsAndPicturesWithoutChangingTheirChoices(hideBeforeRemoval: Bool) async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try write(1, at: root), two = try write(2, at: root, center: 20)
        let resources = try await open(root)
        defer { resources.close() }
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        let oldOne = try #require(resources.details.maps.first { $0.id == 1 })
        let oldTwo = try #require(resources.details.maps.first { $0.id == 2 })
        first.selection.show(oldOne); second.selection.show(oldTwo)
        first.selection.inGameMapOpacity = 0.25; second.selection.inGameMapOpacity = 0.75
        let firstView = first.map?.viewport, secondView = second.map?.viewport
        let firstImage = try #require(MapContent(session: first).inGameMap?.image)
        let secondImage = try #require(MapContent(session: second).inGameMap?.image)
        let originalKey = resources.details.mapImageSource(for: 1)?.key

        resources.worldChanged([one]); await resources.waitForRefresh()
        #expect(resources.details.mapImageSource(for: 1)?.key == originalKey)
        #expect(MapContent(session: first).inGameMap?.image === firstImage)
        try write(1, at: root, center: 100, color: 8)
        resources.worldChanged([one]); await resources.waitForRefresh()
        let changed = try #require(MapContent(session: first).inGameMap)
        #expect(changed.map.centerX == 100 && changed.opacity == 0.25)
        #expect(changed.image !== firstImage)
        #expect(changed.image.dataProvider?.data as Data? != firstImage.dataProvider?.data as Data?)
        #expect(resources.details.mapImageSource(for: 1)?.key != originalKey)
        guard case .inGameMap(let inspected)? = first.selection.inspectorItem else {
            Issue.record("The selected map lost its inspector"); return
        }
        #expect(inspected == changed.map && first.selection.sidebarSelection == .inGameMap(1))
        #expect(first.map?.viewport == firstView && second.map?.viewport == secondView)
        #expect(second.selection.sidebarSelection == .inGameMap(2) && second.selection.inGameMapOpacity == 0.75)
        #expect(MapContent(session: second).inGameMap?.image === secondImage)
        resources.worldChanged([one]); await resources.waitForRefresh()
        #expect(MapContent(session: first).inGameMap?.image === changed.image)

        if hideBeforeRemoval {
            first.selection.isInspectorShown = false
            #expect(MapContent(session: first).inGameMap?.image === changed.image)
        }
        try FileManager.default.removeItem(at: one)
        resources.worldChanged([one]); await resources.waitForRefresh()
        #expect(resources.details.maps.map(\.id) == [2])
        #expect(first.selection.sidebarSelection == nil && first.selection.inspectorItem == nil)
        #expect(first.selection.inspector == nil)
        #expect(MapContent(session: first).inGameMap == nil)
        #expect(MapContent(session: second).inGameMap?.image === secondImage)
        // SwiftUI dismisses the now-empty inspector through ContentView's binding.
        first.selection.isInspectorShown = false
        try write(1, at: root, center: 150, color: 12)
        resources.worldChanged([one]); await resources.waitForRefresh()
        #expect(resources.details.maps.map(\.id) == [1, 2])
        #expect(first.selection.sidebarSelection == nil && first.selection.inspector == nil)
        #expect(MapContent(session: first).inGameMap == nil)
        first.selection.choose(.inGameMap(1))
        #expect(first.selection.sidebarSelection == .inGameMap(1) && first.selection.inspector == .selection)
        #expect(MapContent(session: first).inGameMap?.map.centerX == 150)
        #expect(first.selection.inGameMapOpacity == 0.25)
        #expect(second.selection.sidebarSelection == .inGameMap(2) && second.map?.viewport == secondView)
        #expect(MapContent(session: second).inGameMap?.image === secondImage)
        first.close(); await first.waitUntilClosed()
        #expect(!resources.isClosed)
        try write(2, at: root, center: 200, color: 12)
        resources.worldChanged([two]); await resources.waitForRefresh()
        #expect(MapContent(session: second).inGameMap?.map.centerX == 200)
        #expect(second.selection.inGameMapOpacity == 0.75 && second.map?.viewport == secondView)
        second.close(); await second.waitUntilClosed()
    }

    @Test(arguments: [false, true])
    func removingAKeptMapPreservesTheOtherSelectedLocationWithoutRestoringTheOverlay(inspectorShown: Bool) async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(1, at: root)
        let resources = try await open(root)
        let session = WorldSession(resources: resources)
        defer { session.close() }
        session.selection.choose(.inGameMap(1))
        let dimension = try #require(session.selectedDimensionID)
        let place = try #require(session.savedPlaces.add(name: "Location", dimension: dimension, at: .zero))
        session.selection.choose(.savedPlace(place.id))
        session.selection.isInspectorShown = inspectorShown
        #expect(MapContent(session: session).inGameMap?.map.id == 1)
        let view = session.map?.viewport

        try FileManager.default.removeItem(at: file)
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(session.selection.sidebarSelection == .savedPlace(place.id) && session.selection.isInspectorShown == inspectorShown)
        #expect(session.selection.highlighted == [.row(.savedPlace(place.id))])
        #expect(MapContent(session: session).inGameMap == nil)
        try write(1, at: root, center: 200)
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(session.selection.sidebarSelection == .savedPlace(place.id) && session.selection.isInspectorShown == inspectorShown)
        #expect(MapContent(session: session).inGameMap == nil && session.map?.viewport == view)
        session.selection.isInspectorShown = true
        guard case .savedPlace(let selected)? = session.selection.inspectorItem else { Issue.record("Missing kept location details"); return }
        #expect(selected == place && MapContent(session: session).inGameMap == nil)
        session.selection.choose(.inGameMap(1))
        #expect(session.selection.sidebarSelection == .inGameMap(1) && session.selection.inspector == .selection)
        #expect(MapContent(session: session).inGameMap?.map.centerX == 200)
        session.close(); await session.waitUntilClosed()
    }

    @Test(arguments: [false, true])
    func removingTheSelectedLocationClearsItsRetainedMapEvenWhenDetailsAreHidden(inspectorShown: Bool) async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try write(1, at: root)
        let resources = try await open(root)
        let session = WorldSession(resources: resources)
        defer { session.close() }
        session.selection.choose(.inGameMap(1))
        let place = try #require(session.savedPlaces.add(name: "Location", dimension: "minecraft:overworld", at: .zero))
        session.selection.choose(.savedPlace(place.id))
        session.selection.isInspectorShown = inspectorShown
        #expect(MapContent(session: session).inGameMap?.map.id == 1)
        #expect(session.selection.highlighted == [.row(.savedPlace(place.id))])
        session.savedPlaces.remove(place.id)
        #expect(session.selection.sidebarSelection == nil && !session.selection.isInspectorShown)
        #expect(session.selection.highlighted.isEmpty && MapContent(session: session).inGameMap == nil)
        #expect(resources.details.maps.map(\.id) == [1])
        session.selection.isInspectorShown = true
        #expect(session.selection.inspector == .world && MapContent(session: session).inGameMap == nil)
        session.close(); await session.waitUntilClosed()
    }

    @Test func unreadableMapsAndListingsRetainPriorValuesWhileReadableMapsAdvanceAndRemovalClears() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try write(1, at: root, center: 10), two = try write(2, at: root, center: 20)
        let legacyOne = try write(1, at: root, center: 999, legacy: true)
        let resources = try await open(root)
        defer { resources.close() }
        let original = try #require(resources.details.maps.first { $0.id == 1 })
        let originalKey = resources.details.mapImageSource(for: 1)?.key
        try Data([1, 2, 3]).write(to: one)
        try write(2, at: root, center: 22)
        resources.worldChanged([one, two]); await resources.waitForRefresh()
        #expect(resources.details.maps.first { $0.id == 1 } == original)
        #expect(resources.details.mapImageSource(for: 1)?.key == originalKey)
        #expect(resources.details.maps.first { $0.id == 2 }?.centerX == 22)
        // Opening has no prior value to retain, so its readable fallback remains useful.
        #expect(WorldMapSnapshot.read(resources.world).value.sources.first { $0.map.id == 1 }?.map.centerX == 999)
        try FileManager.default.removeItem(at: two)
        resources.worldChanged([two]); await resources.waitForRefresh()
        #expect(resources.details.maps.map(\.id) == [1])

        let folder = root.appendingPathComponent("data/minecraft/maps"), held = root.appendingPathComponent("held-maps")
        try FileManager.default.moveItem(at: folder, to: held)
        try Data([1]).write(to: folder)
        let legacyThree = try write(3, at: root, center: 30, legacy: true)
        resources.worldChanged([folder, legacyThree]); await resources.waitForRefresh()
        #expect(resources.details.maps.map(\.id) == [1, 3])
        #expect(resources.details.maps.first { $0.id == 1 } == original)
        #expect(resources.details.maps.first { $0.id == 3 }?.centerX == 30)
        try FileManager.default.removeItem(at: legacyOne)
        resources.worldChanged([legacyOne]); await resources.waitForRefresh()
        #expect(resources.details.maps.first { $0.id == 1 } == original)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: held, to: folder)
        try write(1, at: root, center: 101, color: 8)
        try FileManager.default.removeItem(at: legacyThree)
        // Saved maps remain readable when unrelated level metadata is temporarily corrupt.
        let level = root.appendingPathComponent("level.dat")
        try Data([1, 2, 3]).write(to: level)
        resources.worldChanged([folder, legacyThree, level]); await resources.waitForRefresh()
        #expect(resources.details.maps.map(\.id) == [1] && resources.details.maps.first?.centerX == 101)
        #expect(resources.details.mapImageSource(for: 1)?.key != originalKey)
        try FileManager.default.removeItem(at: one)
        resources.worldChanged([one]); await resources.waitForRefresh()
        #expect(resources.details.maps.isEmpty)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func overlappingSavesPublishProgressAndClosingCannotUpdateAReplacementWorld() async throws {
        let root = try TestWorld.make(chunks: []), nextRoot = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: nextRoot) }
        try write(1, at: root); try write(1, at: nextRoot, center: 999)
        let resources = try await open(root), replacement = try await open(nextRoot)
        defer { resources.close(); replacement.close() }
        var map = try #require(resources.details.maps.first)
        let reads = AsyncReadGate<RefreshRead<WorldMapSnapshot>>(), schedules = AsyncReadGate<Void>(), numbers = ReadNumbers()
        let lighting = AsyncReadGate<[String: MapLighting]>()
        resources.readMaps = { _, _ in await reads.read(String(await numbers.next())) }
        resources.readLighting = { _, _ in await lighting.read("save") }
        resources.waitBeforeRefresh = { _ in await schedules.read("save") }
        let file = root.appendingPathComponent("data/minecraft/world_clocks.dat")
        resources.worldChanged([file])
        await schedules.waitForRequest("save"); await schedules.finish("save", with: ())
        await reads.waitForRequest("0")
        await lighting.waitForRequest("save"); await lighting.finish("save", with: [:])
        for _ in 0..<3 { resources.worldChanged([file]) }
        await schedules.waitForRequest("save", count: 2); await schedules.finish("save", with: ())
        // This handshake proves the scheduled refresh reached its producers and queued maps.
        await lighting.waitForRequest("save", count: 2); await lighting.releaseAllAndFuture(with: [:])
        map.centerX = 100
        await reads.finish("0", with: .complete(WorldMapSnapshot(sources: [.init(map)])))
        await reads.waitForRequest("1")
        #expect(resources.details.maps.first?.centerX == 100)
        map.centerX = 200
        await reads.finish("1", with: .complete(WorldMapSnapshot(sources: [.init(map)])))
        await resources.waitForRefresh()
        #expect(resources.details.maps.first?.centerX == 200 && replacement.details.maps.first?.centerX == 999)
        #expect(await reads.requested == ["0", "1"])
        resources.worldChanged([file])
        await schedules.waitForRequest("save", count: 3); await schedules.finish("save", with: ())
        await reads.waitForRequest("2")
        resources.close()
        await reads.waitForCancellation("2")
        map.centerX = 300
        await reads.finish("2", with: .complete(WorldMapSnapshot(sources: [.init(map)])))
        await resources.waitUntilClosed()
        #expect(resources.details.maps.isEmpty && replacement.details.maps.first?.centerX == 999)
        replacement.close(); await replacement.waitUntilClosed()
    }

    @Test func regionWritesAndGameResourceChangesDoNotReadSavedMaps() async throws {
        let root = try TestWorld.make(chunks: []), game = try ItemPictureFixture(extraFiles: [:])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        try write(1, at: root)
        let resources = try await open(root)
        defer { resources.close() }
        let dimension = try #require(resources.dimensions.first), original = resources.details.maps
        resources.readMaps = { _, _ in Issue.record("Unrelated input reread saved maps"); throw CancellationError() }
        resources.worldChanged([dimension.regionDirectory.appendingPathComponent("r.0.0.mca")])
        await resources.waitForRefresh()
        resources.names.minecraft.usesGameArtwork.toggle(); await resources.waitForRefresh()
        resources.names.minecraft.choose(game.root); await resources.waitForRefresh()
        resources.names.minecraft.forget(); await resources.waitForRefresh()
        #expect(resources.details.maps == original)
        resources.close(); await resources.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
    }
}
