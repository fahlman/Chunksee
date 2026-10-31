import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DarkSpotsTests {
    private let region = RegionPosition(x: 0, z: 0)

    @Test func torchLightUsesTheSpaceAboveTheDisplayedBlockAndMatchesHover() async throws {
        let spec = chunk { x, y, z in y == 8 ? max(0, 8 - abs(x - 7) - abs(z - 7)) : 0 }
        let root = try world([spec])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let baseline = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: region))
        var renderer = RegionTileRenderer(dimension: dimension, darkSpots: overlay)
        let pixels = try #require(try await renderer.pixels(for: region))
        let blocks = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0))
        for z in 0..<16 { for x in 0..<16 {
            let bright = abs(x - 7) + abs(z - 7) < 8
            #expect(blocks[z * 16 + x]?.y == 7)
            #expect(blocks[z * 16 + x]?.nightLight == (bright ? .bright : .dark))
            let offset = (z * 512 + x) * 4
            #expect((Array(pixels[offset..<(offset + 4)]) == Array(baseline[offset..<(offset + 4)])) == bright)
        } }
        #expect(pixels[16 * 4 + 3] == 0) // Never paint an ungenerated chunk.
        renderer.chunkConcurrency = 14
        #expect(try await renderer.pixels(for: region) == pixels)
        renderer.cutawayY = 6
        let lower = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(lower.allSatisfy { $0?.y == 6 && $0?.nightLight == .dark })
        #expect(try await renderer.pixels(for: region) != pixels)
    }

    @Test func unavailableOrStaleLightIsStripedAndNeverCalledDark() async throws {
        for (valid, malformed, sky) in [(false, false, true), (true, true, true), (true, false, false)] {
            let root = try world([chunk(valid: valid, sky: sky, malformedBlock: malformed) { _, _, _ in 0 }])
            defer { try? FileManager.default.removeItem(at: root) }
            let (dimension, overlay) = try inputs(root)
            let file = try #require(try dimension.region(x: 0, z: 0))
            let blocks = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).topBlocks(in: file, localX: 0, localZ: 0))
            #expect(blocks.allSatisfy { $0?.nightLight == .unknown })
            let image = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).image(for: region))
            let pixels = try ItemPictureFixture.pixels(image)
            #expect(pixels.color(0, 0) != pixels.color(2, 0))
            let ordinary = try #require(try await RegionTileRenderer(dimension: dimension).topBlocks(in: file, localX: 0, localZ: 0))
            #expect(ordinary.allSatisfy { $0?.nightLight == nil && $0?.y == 7 })
        }
    }

    @Test func omittedValidBlockLightUsesTheSharedSavedLayerRule() async throws {
        let root = try world([chunk(block: false) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).topBlocks(in: file, localX: 0, localZ: 0))
        #expect(blocks.allSatisfy { $0?.nightLight == .dark })
        let ordinary = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: region))
        let tinted = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).pixels(for: region))
        #expect(ordinary != tinted)
    }

    @Test func noSkyDimensionsUseTheirOwnLightRuleAndUnresolvedRulesStayUnknown() async throws {
        let root = try world([chunk(sky: false) { x, _, _ in x }], hasSky: false, blockLimit: 15)
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).topBlocks(in: file, localX: 0, localZ: 0))
        for x in 0..<16 { #expect(blocks[x]?.nightLight == (x <= 7 ? .dark : .bright)) }
        let unknown = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: DarkSpots(rule: nil)).topBlocks(in: file, localX: 0, localZ: 0))
        #expect(unknown.allSatisfy { $0?.nightLight == .unknown })
    }

    @Test func diskCacheKeepsOnAndOffSeparateAndRejectsBadLightBytes() async throws {
        let root = try world([chunk { x, _, _ in x }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let cache = TileCache(directory: root.appendingPathComponent("test-tiles"))
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        let ordinary = try #require(try await renderer.tile(for: region))
        let key = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(at: region)))
        #expect(cache.load(key)?.nightLight == nil)
        renderer.darkSpots = overlay
        let tinted = try #require(try await renderer.tile(for: region))
        let litKey = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(at: region), darkSpots: overlay))
        #expect(litKey != key && litKey.prefix != key.prefix)
        #expect(cache.load(litKey)?.nightLight?.count == 512 * 512)
        #expect(try ItemPictureFixture.pixels(tinted.full.image).bytes != ItemPictureFixture.pixels(ordinary.full.image).bytes)
        let cached = try #require(try await renderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(tinted.full.image).bytes == ItemPictureFixture.pixels(cached.full.image).bytes)
        renderer.darkSpots = nil
        let restored = try #require(try await renderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(restored.full.image).bytes == ItemPictureFixture.pixels(ordinary.full.image).bytes)
        var bad = try (Data(contentsOf: cache.directory.appendingPathComponent(try #require(litKey.fileName))) as NSData).decompressed(using: .lzfse) as Data
        bad[512 * 512 * 9] = 3
        try ((bad as NSData).compressed(using: .lzfse) as Data).write(to: cache.directory.appendingPathComponent(try #require(litKey.fileName)))
        #expect(cache.load(litKey) == nil)
        #expect(cache.load(key) != nil)
    }

    @Test(.timeLimit(.minutes(1))) func togglingRejectsLateTilesAndClosesPendingWork() async throws {
        let root = try world([chunk { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let before = try await RegionTileRenderer(dimension: dimension).tile(for: region)
        let after = try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).tile(for: region)
        let gate = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, _ in
            await gate.read(renderer.darkSpots == nil ? "off" : "on")
        })
        nightLighting.value = overlay.rule
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        await gate.waitForRequest("off")
        map.setDarkSpots(true)
        await gate.waitForCancellation("off")
        await gate.waitForRequest("on")
        await gate.finish("on", with: after)
        await map.waitUntilIdle()
        await gate.finish("off", with: before)
        await map.waitForRenders()
        #expect(map.tiles[region]?.picture === after?.full)
        map.regionsChanged([region])
        await gate.waitForRequest("on", count: 2)
        map.close()
        await gate.finish("on", with: after)
        await map.waitForRenders()
        map.setDarkSpots(false)
        #expect(map.showsDarkSpots && map.nightLighting == nil)
    }

    @Test(.timeLimit(.minutes(1))) func appearanceChangesPreserveAPendingCoordinateRead() async throws {
        let root = try world([chunk { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension).topBlocks(in: file, localX: 0, localZ: 0))
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: .zero,
                           readTopBlocks: { _, renderer, _ in
            // Center reads start with the layer; this gate holds only the original copy.
            renderer.darkSpots == nil ? await gate.read("coordinate") : nil
        })
        var copiedHeight: Int?
        map.readTopBlock(at: CGPoint(x: 3, y: 4)) { copiedHeight = $0?.y }
        await gate.waitForRequest("coordinate")
        map.setDarkSpots(true)
        nightLighting.value = overlay.rule
        map.setDarkSpots(false)
        await gate.finish("coordinate", with: (file, blocks))
        await map.waitForCoordinateReads()
        #expect(copiedHeight == 7)
        map.close()
        await map.waitForRenders()
    }

    @Test(.timeLimit(.minutes(1))) func tabsShareOptionalMetadataAndIgnoreLateResultsAfterHidingOrClosing() async throws {
        let root = try world([chunk { _, _, _ in 0 }]), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let gate = AsyncReadGate<[String: MonsterSpawnLight]>()
        resources.readNightLighting = { _, _ in await gate.read("initial") }
        let first = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let second = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(first.map != nil && second.map != nil)
        #expect(first.map?.showsDarkSpots == false && second.map?.showsDarkSpots == false)
        #expect(await gate.requested.isEmpty)
        first.setDarkSpots(true)
        await gate.waitForRequest("initial")
        second.setDarkSpots(true)
        #expect(await gate.requested == ["initial"])
        first.setDarkSpots(false)
        let rules = try resources.world.nightMonsterLighting(assets: nil)
        await gate.finish("initial", with: rules)
        await resources.waitForRefresh()
        #expect(second.map?.nightLighting == rules["minecraft:the_nether"])
        #expect(second.map?.nightLighting?.hasSkylight == false)
        #expect(first.map?.currentRenderer.darkSpots == nil)
        resources.refreshDelay = .zero
        resources.readNightLighting = { _, _ in await gate.read("late") }
        resources.worldChanged([root.appendingPathComponent("datapacks")])
        await gate.waitForRequest("late")
        second.setDarkSpots(false)
        await gate.waitForCancellation("late")
        await gate.finish("late", with: [:])
        await resources.waitForRefresh()
        #expect(second.map?.nightLighting == rules["minecraft:the_nether"])
        #expect(second.map?.nightLighting?.hasSkylight == false)
        resources.readNightLighting = { _, _ in await gate.read("close") }
        first.setDarkSpots(true)
        await gate.waitForRequest("close")
        resources.close()
        await gate.waitForCancellation("close")
        await gate.finish("close", with: rules)
        await resources.waitUntilClosed()
        #expect(first.map?.nightLighting == nil && second.map?.nightLighting == nil)
        let saved = LayerVisibility(settings: resources.settings, dimension: "minecraft:overworld")
        let another = LayerVisibility(settings: resources.settings, dimension: "minecraft:the_nether")
        #expect(saved.rememberedDarkSpots && !another.rememberedDarkSpots)
    }

    @Test(.timeLimit(.minutes(1))) func resumingDarkSpotsWhileAReadRetiresKeepsWorldDrainage() async throws {
        let root = try world([])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root), session = WorldSession(resources: resources)
        let rules = try resources.world.nightMonsterLighting(assets: nil)
        let gate = AsyncReadGate<[String: MonsterSpawnLight]>(), numbers = ReadNumbers()
        resources.readNightLighting = { _, _ in await gate.read(String(await numbers.next())) }
        session.setDarkSpots(true); await gate.waitForRequest("0")
        await gate.finish("0", with: rules); await resources.waitForRefresh()
        resources.worldChanged([root.appendingPathComponent("datapacks")])
        await gate.waitForRequest("1")
        session.setDarkSpots(false); await gate.waitForCancellation("1")
        #expect(session.map?.nightLighting == rules["minecraft:overworld"])
        session.setDarkSpots(true); await gate.waitForRequest("2")
        await gate.finish("2", with: [:])
        for await ready in Observations({ session.map?.nightLighting == nil }) where ready { break }
        var drained = false
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiter = Task { started.resume(); await resources.waitForRefresh(); drained = true }
        }
        #expect(!drained)
        await gate.finish("1", with: rules); await waiter?.value
        #expect(drained && session.map?.nightLighting == nil)
        #expect(await gate.requested == ["0", "1", "2"])
        resources.close(); await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func optionalRulesRetryFailuresAndRememberHiddenChanges() async throws {
        let root = try world([])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root), session = WorldSession(resources: resources)
        let rules = try resources.world.nightMonsterLighting(assets: nil)
        let gate = AsyncReadGate<Result<[String: MonsterSpawnLight], CocoaError>>()
        resources.readNightLighting = { _, _ in try await gate.read("rules").get() }
        resources.names.minecraft.usesGameArtwork = false
        resources.names.minecraft.usesGameArtwork = true
        await resources.waitForRefresh()
        #expect(await gate.requested.isEmpty)
        session.setDarkSpots(true)
        await gate.waitForRequest("rules"); await gate.finish("rules", with: .success(rules))
        await resources.waitForRefresh()
        session.setDarkSpots(false); session.setDarkSpots(true)
        await resources.waitForRefresh()
        #expect(await gate.requested.count == 1)

        let pack = root.appendingPathComponent("datapacks")
        resources.worldChanged([pack]); await gate.waitForRequest("rules", count: 2)
        await gate.finish("rules", with: .failure(CocoaError(.fileReadUnknown)))
        await resources.waitForRefresh()
        #expect(session.map?.nightLighting == rules["minecraft:overworld"])
        #expect(await gate.requested.count == 2) // Failure does not start a retry loop.
        session.setDarkSpots(false); session.setDarkSpots(true)
        await gate.waitForRequest("rules", count: 3)
        await gate.finish("rules", with: .success([:]))
        await resources.waitForRefresh()
        #expect(session.map?.nightLighting == nil)
        session.setDarkSpots(false); session.setDarkSpots(true)
        await resources.waitForRefresh()
        #expect(await gate.requested.count == 3) // Successful empty is a reusable publication.

        session.setDarkSpots(false)
        resources.worldChanged([pack]); await resources.waitForRefresh()
        #expect(await gate.requested.count == 3)
        session.setDarkSpots(true)
        await gate.waitForRequest("rules", count: 4)
        await gate.finish("rules", with: .success(rules)); await resources.waitForRefresh()
        #expect(session.map?.nightLighting == rules["minecraft:overworld"])
        resources.close(); await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func savesCoalesceWhileARuleReadRunsAndClosingASiblingKeepsItAlive() async throws {
        let root = try world([])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        let rules = try resources.world.nightMonsterLighting(assets: nil)
        let gate = AsyncReadGate<[String: MonsterSpawnLight]>(), changes = AsyncReadGate<Void>()
        await changes.releaseAllAndFuture(with: ())
        resources.readNightLighting = { _, _ in await gate.read("rules") }
        resources.readDefinitions = { world, library in
            await changes.read("pack")
            return try await WorldResources.readDefinitions(world, library: library)
        }
        first.setDarkSpots(true); await gate.waitForRequest("rules")
        second.setDarkSpots(true)
        for count in 1...3 {
            resources.worldChanged([root.appendingPathComponent("datapacks")])
            await changes.waitForRequest("pack", count: count)
        }
        first.close()
        #expect(first.map?.nightLighting == nil && !resources.isClosed)
        #expect(await gate.requested.count == 1)
        await gate.finish("rules", with: rules)
        await gate.waitForRequest("rules", count: 2)
        #expect(second.map?.nightLighting == rules["minecraft:overworld"])
        await gate.finish("rules", with: [:]); await resources.waitForRefresh()
        #expect(second.map?.nightLighting == nil)
        #expect(await gate.requested.count == 2)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func replacingTheNightSourceClearsRulesAndRejectsRetiredReads() async throws {
        let assetReads = TestGameAssets()
        let root = try world([]), changedRoot = try world([], hasSky: false, blockLimit: 15)
        let fixture = try ItemPictureFixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: changedRoot)
            fixture.remove()
        }
        for url in [root, changedRoot] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                   withIntermediateDirectories: true)
        }
        let resources = try await resources(root, assetReads: assetReads), first = WorldSession(resources: resources)
        let old = try resources.world.nightMonsterLighting(assets: nil)
        let updated = try World(contentsOf: changedRoot).nightMonsterLighting(assets: nil)
        #expect(old["minecraft:overworld"] != updated["minecraft:overworld"])
        let a = try fixture.resources(), b = try fixture.resources()
        let artwork = [a, b].compactMap { resources.names.minecraft.artwork(for: $0) }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        await assetReads.publish(a, to: resources); await resources.waitForRefresh()
        let gate = AsyncReadGate<Result<[String: MonsterSpawnLight], CocoaError>>()
        resources.readNightLighting = { _, library in try await gate.read(library?.identity.uuidString ?? "none").get() }
        first.setDarkSpots(true)
        await gate.waitForRequest(a.identity.uuidString)
        await gate.finish(a.identity.uuidString, with: .success(old)); await resources.waitForRefresh()
        #expect(first.map?.nightLighting == old["minecraft:overworld"])
        resources.names.minecraft.usesGameArtwork = false
        await resources.waitForRefresh()
        #expect(await gate.requested.count == 1)
        #expect(first.map?.nightLighting == old["minecraft:overworld"])

        await assetReads.publish(b, to: resources)
        #expect(first.map?.nightLighting == nil)
        let second = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(second.map?.nightLighting == nil)
        second.setDarkSpots(true)
        await gate.waitForRequest(b.identity.uuidString)
        await gate.finish(b.identity.uuidString, with: .failure(CocoaError(.fileReadUnknown)))
        await resources.waitForRefresh()
        #expect(first.map?.nightLighting == nil && second.map?.nightLighting == nil)
        resources.worldChanged([root.appendingPathComponent("datapacks")])
        await gate.waitForRequest(b.identity.uuidString, count: 2)
        await gate.finish(b.identity.uuidString, with: .success(updated)); await resources.waitForRefresh()
        #expect(first.map?.nightLighting == updated["minecraft:overworld"])
        #expect(second.map?.nightLighting == updated["minecraft:the_nether"])
        let third = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(third.map?.nightLighting == updated["minecraft:the_nether"])

        resources.worldChanged([root.appendingPathComponent("datapacks")])
        await gate.waitForRequest(b.identity.uuidString, count: 3)
        await assetReads.publish(a, to: resources)
        await gate.waitForCancellation(b.identity.uuidString)
        await gate.waitForRequest(a.identity.uuidString, count: 2)
        #expect(first.map?.nightLighting == nil && third.map?.nightLighting == nil)
        first.close()
        #expect(!resources.isClosed)
        await gate.finish(b.identity.uuidString, with: .success(updated))
        await gate.finish(a.identity.uuidString, with: .success(old)); await resources.waitForRefresh()
        #expect(first.map?.nightLighting == nil)
        #expect(second.map?.nightLighting == old["minecraft:the_nether"])
        await assetReads.publish(nil, to: resources)
        #expect(second.map?.nightLighting == nil && third.map?.nightLighting == nil)
        await gate.waitForRequest("none")
        let saveOnly = try resources.world.nightMonsterLighting(assets: nil)
        await gate.finish("none", with: .success(saveOnly)); await resources.waitForRefresh()
        #expect(second.map?.nightLighting == saveOnly["minecraft:the_nether"])
        #expect(resources.names.minecraft.generation == source.generation)
        resources.close(); await resources.waitUntilClosed()
        for library in artwork { await library.close() }
        for library in [a, b] { await library.data.close() }
    }

    @Test(.timeLimit(.minutes(1))) func addingADimensionInvalidatesTheSharedRulesWithoutStartingAHiddenRead() async throws {
        let root = try world([])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root), first = WorldSession(resources: resources)
        let gate = AsyncReadGate<[String: MonsterSpawnLight]>()
        resources.readNightLighting = { _, _ in await gate.read("rules") }
        first.setDarkSpots(true); await gate.waitForRequest("rules")
        await gate.finish("rules", with: try resources.world.nightMonsterLighting(assets: nil))
        await resources.waitForRefresh()
        first.setDarkSpots(false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                               withIntermediateDirectories: true)
        try await resources.includeDimensions(from: WorldSnapshot.read(root))
        await resources.waitForRefresh()
        let second = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(second.map != nil)
        #expect(await gate.requested.count == 1)
        second.setDarkSpots(true)
        await gate.waitForRequest("rules", count: 2)
        let rules = try resources.world.nightMonsterLighting(assets: nil)
        await gate.finish("rules", with: rules); await resources.waitForRefresh()
        #expect(second.map?.nightLighting == rules["minecraft:the_nether"])
        #expect(second.map?.nightLighting?.hasSkylight == false)
        first.setDarkSpots(true); await resources.waitForRefresh()
        #expect(await gate.requested.count == 2)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test(arguments: [false, true])
    func mapAndAreaExportsUseTheSameLightPixelsAndLegendInBothAppearances(savedTime: Bool) async throws {
        let root = try world([chunk { x, _, _ in x }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let savedLighting = TestSavedLighting()
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { savedLighting.value }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: .zero, regionConcurrency: 1, chunkConcurrency: 1)
        defer { map.close() }
        let plan = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 512, height: 512), blocksPerPixel: 1)
        map.viewport = plan.viewport
        if savedTime {
            let time = try JSONDecoder().decode(DimensionTime.self, from: Data(#"{"has_skylight":true}"#.utf8))
            let saved = try #require(SkyLighting(sunAngle: 180, moonAngle: 0, skyLightFactor: 0.24,
                skyLightColor: SIMD3(0.48, 0.48, 1), moonPhase: .fullMoon))
            savedLighting.value = MapLighting(saved: saved, time: time)
        }
        nightLighting.value = overlay.rule
        map.setDarkSpots(true)
        map.requestTiles(visibleIn: plan.size, displayScale: 1)
        await map.waitUntilIdle()
        let tile = try #require(map.tiles[region])
        #expect((tile.normals != nil) == savedTime)
        let color = try ItemPictureFixture.pixels(tile.image).color(0, 0)
        #expect(color[0] > color[1]) // The dark-column tint survives preparation of lighting inputs.
        var content = MapContent()
        content.showsDarkSpots = true
        content.lighting = map.lighting
        for scheme in [ColorScheme.light, .dark] {
            let exported = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: map.currentRenderer,
                content: content, portalStatus: { _ in nil }, colorScheme: scheme, locale: Locale(identifier: "en_US"), progress: { _, _ in })
            let view = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: plan.size,
                scale: 1, colorScheme: scheme, locale: Locale(identifier: "en_US")))
            #expect(try pngPixels(exported) == pngPixels(view))
            let bare = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil }, size: plan.size,
                scale: 1, colorScheme: scheme, locale: Locale(identifier: "en_US")))
            #expect(try pngPixels(view) != pngPixels(bare))
        }
        await map.waitForRenders()
    }

    @Test func accessibilityReportsTheCenteredColumnWithoutAPointer() async throws {
        let root = try world([
            chunk { x, _, _ in x == 0 ? 0 : 15 },
            chunk(x: 1, valid: false) { _, _, _ in 0 }
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: .zero)
        defer { map.close() }
        func readout() -> String { MapView.accessibilityReadout(map: map, content: MapContent()) }
        nightLighting.value = overlay.rule
        map.viewport.center = CGPoint(x: 0.5, y: 0.5)
        #expect(map.unfinishedTopBlockReads == 0 && map.topBlocks.isEmpty)
        #expect(!readout().contains("Dark Spots"))
        map.setDarkSpots(true)
        #expect(readout().contains(DarkSpots.Status.unknown.description))
        await map.waitForTopBlocks()
        #expect(readout().contains(DarkSpots.Status.dark.description))
        map.viewport.center.x = 1.5
        #expect(map.unfinishedTopBlockReads == 0) // Same chunk, another cached column.
        #expect(readout().contains(DarkSpots.Status.bright.description))
        map.viewport.center.x = 16.5
        await map.waitForTopBlocks()
        #expect(readout().contains(DarkSpots.Status.unknown.description))
        map.viewport.center.x = -0.5 // Ungenerated column, also unknown.
        await map.waitForTopBlocks()
        #expect(readout().contains(DarkSpots.Status.unknown.description))
        map.setDarkSpots(false)
        #expect(!readout().contains("Dark Spots") && !readout().contains("at night"))
    }

    @Test(.timeLimit(.minutes(1))) func centerAndPointerShareReadsAndMovingEitherKeepsTheOthersWork() async throws {
        let root = try world([chunk { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).topBlocks(in: file, localX: 0, localZ: 0))
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: .zero,
                           readTopBlocks: { chunk, _, _ in await gate.read(String(chunk.x)) })
        nightLighting.value = overlay.rule
        map.setDarkSpots(true)
        await gate.waitForRequest("0")
        map.loadTopBlocks(at: CGPoint(x: 1, y: 1))
        #expect(map.unfinishedTopBlockReads == 1)
        map.loadTopBlocks(at: CGPoint(x: 16, y: 0))
        await gate.waitForRequest("1")
        #expect(map.unfinishedTopBlockReads == 2)
        map.viewport.center.x = 16
        await gate.waitForCancellation("0")
        map.endHover() // Center still needs chunk 1.
        await gate.finish("0", with: (file, blocks))
        await gate.finish("1", with: (file, blocks))
        await map.waitForTopBlocks()
        #expect(await gate.requested == ["0", "1"])
        #expect(map.topBlock(at: .zero) == nil)
        #expect(map.topBlock(at: map.viewport.center)?.nightLight == .dark)

        map.viewport.center.x = 32
        await gate.waitForRequest("2")
        map.setDarkSpots(false)
        await gate.waitForCancellation("2")
        await gate.finish("2", with: (file, blocks))
        await map.waitForTopBlocks()
        #expect(map.topBlocks.isEmpty)
        map.close()
        await map.waitForRenders()
    }

    @Test(.timeLimit(.minutes(1))) func savingRereadsTheCenterAndClosingRejectsPendingResults() async throws {
        let root = try world([chunk { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).topBlocks(in: file, localX: 0, localZ: 0))
        let gate = AsyncReadGate<MapModel.TopBlockRead?>(), numbers = ReadNumbers()
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: .zero,
                           readTopBlocks: { _, _, _ in await gate.read(String(await numbers.next())) })
        nightLighting.value = overlay.rule
        map.setDarkSpots(true)
        await gate.waitForRequest("0")
        map.regionsChanged([RegionPosition(x: 1, z: 0)]) // Unrelated save keeps this read.
        #expect(map.unfinishedTopBlockReads == 1)
        map.regionsChanged([region])
        await gate.waitForCancellation("0")
        await gate.waitForRequest("1")
        await gate.finish("1", with: (file, blocks))
        await gate.finish("0", with: (file, Array(repeating: nil, count: 256)))
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: .zero)?.nightLight == .dark)
        map.regionsChanged([region])
        #expect(map.topBlock(at: .zero) == nil)
        await gate.waitForRequest("2")
        map.close()
        await gate.waitForCancellation("2")
        await gate.finish("2", with: (file, blocks))
        await map.waitForRenders()
        #expect(map.topBlocks.isEmpty && map.unfinishedTopBlockReads == 0)
    }

    @Test func movingThePointerCannotEvictTheCenteredResult() async throws {
        let root = try world([chunk { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).topBlocks(in: file, localX: 0, localZ: 0))
        let nightLighting = TestNightLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nightLighting.value }, work: BackgroundWork(), dimension: dimension, center: .zero,
                           readTopBlocks: { _, _, _ in (file, blocks) })
        defer { map.close() }
        nightLighting.value = overlay.rule
        map.setDarkSpots(true)
        await map.waitForTopBlocks()
        for x in 1...65 {
            map.loadTopBlocks(at: CGPoint(x: x * 16, y: 0))
            await map.waitForTopBlocks()
        }
        #expect(map.topBlocks.count == 64)
        #expect(map.topBlock(at: .zero)?.nightLight == .dark)
        #expect(map.topBlock(at: CGPoint(x: 65 * 16, y: 0))?.nightLight == .dark)
    }

    @Test func legendSamplesDistinguishDarkBrightAndUnknownWithoutColor() throws {
        let dark = try ItemPictureFixture.pixels(#require(DarkSpots.sample(.dark)))
        let bright = try ItemPictureFixture.pixels(#require(DarkSpots.sample(.bright)))
        let unknown = try ItemPictureFixture.pixels(#require(DarkSpots.sample(.unknown)))
        #expect(dark.color(1, 1) != dark.color(0, 1)) // Dots, not just a solid tint.
        #expect(dark.color(0, 0) == dark.color(2, 0))
        #expect(unknown.color(0, 0) != unknown.color(2, 0)) // Diagonal stripes.
        #expect(bright.color(0, 0) == bright.color(1, 1))
    }

    private func pngPixels(_ value: MapImage) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(value.data as CFData, nil))
        return try ItemPictureFixture.pixels(#require(CGImageSourceCreateImageAtIndex(source, 0, nil))).bytes
    }

    private func resources(_ root: URL, assetReads: TestGameAssets? = nil) async throws -> WorldResources {
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil }, readGameAssets: { minecraft in
                if let assetReads { return try await assetReads.read(minecraft) }
                return try await minecraft.readLibrary()
            })
        resources.refreshDelay = .zero
        await resources.waitForRefresh()
        return resources
    }

    private func inputs(_ root: URL) throws -> (ChunkseeKit.Dimension, DarkSpots) {
        let world = try World(contentsOf: root)
        return (try #require(world.dimension("overworld")), DarkSpots(rule: try #require(world.nightMonsterLighting(assets: nil)["minecraft:overworld"])))
    }

    private func world(_ chunks: [TestWorld.ChunkSpec], hasSky: Bool = true, blockLimit: Int32 = 0) throws -> URL {
        let type = NBT.compound([
            "min_y": .int(0), "height": .int(256), "logical_height": .int(256), "has_ceiling": .byte(0),
            "has_skylight": .byte(hasSky ? 1 : 0), "monster_spawn_block_light_limit": .int(blockLimit),
            "monster_spawn_light_level": .int(7), "attributes": .compound(["gameplay/sky_light_level": .float(4)])
        ])
        let otherType = NBT.compound([
            "min_y": .int(0), "height": .int(256), "logical_height": .int(256), "has_ceiling": .byte(0),
            "has_skylight": .byte(0), "monster_spawn_block_light_limit": .int(15), "monster_spawn_light_level": .int(7)
        ])
        return try TestWorld.make(chunks: chunks, dimensionSettings: [
            "minecraft:overworld": .compound(["type": type]),
            "minecraft:the_nether": .compound(["type": otherType])
        ])
    }

    private func chunk(x chunkX: Int = 0, valid: Bool = true, block: Bool = true, sky: Bool = true, malformedBlock: Bool = false,
                       light: (Int, Int, Int) -> Int) -> TestWorld.ChunkSpec {
        let indices = (0..<16).flatMap { y in (0..<256).map { _ in y <= 7 ? 1 : 0 } }
        guard case .compound(var section) = Fixtures.section(y: 0, palette: [.string("minecraft:air"), .string("minecraft:stone")], indices: indices) else {
            preconditionFailure("The section fixture must be a compound")
        }
        if block {
            let bytes = (0..<2048).map { i -> Int8 in
                let x = (i * 2) % 16, y = i / 128, z = (i / 8) % 16
                return Int8(bitPattern: UInt8(light(x, y, z)) | UInt8(light(x + 1, y, z) << 4))
            }
            section["BlockLight"] = .byteArray(bytes)
        }
        if malformedBlock { section["BlockLight"] = .byteArray([0]) }
        if sky { section["SkyLight"] = .byteArray(Array(repeating: -1, count: 2048)) }
        return .init(x: chunkX, z: 0, nbt: Fixtures.chunk(x: chunkX, z: 0, dataVersion: SaveVersion.java26_3,
            sections: [.compound(section)], extra: ["isLightOn": .byte(valid ? 1 : 0), "yPos": .int(0)]))
    }
}
