import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct QuitPersistenceTests {
    @Test func terminationFlushesEveryLiveDimensionWithoutChangingTheFrontOne() async throws {
        let defaults = TestDefaults.make(), model = AppModel(defaults: defaults, cacheRoot: nil)
        let menus = ReadOnlyDocumentMenus()
        menus.prepareForTermination = { [weak model] in model?.saveViews() }
        var worlds: [URL] = [], resources: [WorldResources] = [], sessions: [WorldSession] = []
        defer {
            resources.forEach { $0.close() }
            for url in worlds { try? FileManager.default.removeItem(at: url) }
        }
        for i in 0..<2 {
            let url = try TestWorld.make(chunks: [])
            worlds.append(url)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
            let world = model.resources(for: try await WorldSnapshot.read(url))
            resources.append(world)
            let overworld = WorldSession(resources: world, dimensionID: "minecraft:overworld")
            let nether = WorldSession(resources: world, dimensionID: "minecraft:the_nether")
            sessions += [overworld, nether]
            (i == 0 ? nether : overworld).becameActive()
            // These are the latest values, before a SwiftUI debounce task has saved them.
            overworld.map?.viewport = MapViewport(center: CGPoint(x: 123 + i, y: -456), scale: 2)
            nether.map?.viewport = MapViewport(center: CGPoint(x: -12, y: 34 + i), scale: 8)
            nether.map?.setDepth(MapDepth(y: 48, isSurface: false))
            #expect(world.views.viewport(for: "minecraft:overworld") != overworld.map?.viewport)
        }
        #expect(menus.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(menus.isTerminating)
        for (i, world) in resources.enumerated() {
            let saved = RememberedViews(world: worlds[i], defaults: defaults)
            #expect(saved.viewport(for: "minecraft:overworld") == sessions[i * 2].map?.viewport)
            #expect(saved.viewport(for: "minecraft:the_nether") == sessions[i * 2 + 1].map?.viewport)
            #expect(saved.depth(for: "minecraft:the_nether") == MapDepth(y: 48, isSurface: false))
            let front = i == 0 ? "minecraft:the_nether" : "minecraft:overworld"
            #expect(saved.lastDimension == front)
            sessions[i * 2 + (i == 0 ? 0 : 1)].becameActive(isTerminating: menus.isTerminating)
            #expect(world.activeDimensionID == front && saved.lastDimension == front)
        }
        let closed = sessions[0], saved = try #require(closed.map?.viewport)
        closed.close()
        await closed.waitUntilClosed()
        closed.map?.viewport = MapViewport(center: .zero, scale: 1)
        #expect(menus.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(resources[0].views.viewport(for: "minecraft:overworld") == saved)
        for world in resources { world.close(); await world.waitUntilClosed() }
    }
}
