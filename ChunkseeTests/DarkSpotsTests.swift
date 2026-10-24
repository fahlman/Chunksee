import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import ImageIO
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
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, darkSpots: overlay))
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
        let lower = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, cutawayY: 6, darkSpots: overlay))
        #expect(lower.allSatisfy { $0?.y == 6 && $0?.nightLight == .dark })
        #expect(try await renderer.pixels(for: region) != pixels)
    }

    @Test func unavailableOrStaleLightIsStripedAndNeverCalledDark() async throws {
        for (valid, malformed, sky) in [(false, false, true), (true, true, true), (true, false, false)] {
            let root = try world([chunk(valid: valid, sky: sky, malformedBlock: malformed) { _, _, _ in 0 }])
            defer { try? FileManager.default.removeItem(at: root) }
            let (dimension, overlay) = try inputs(root)
            let file = try #require(try dimension.region(x: 0, z: 0))
            let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, darkSpots: overlay))
            #expect(blocks.allSatisfy { $0?.nightLight == .unknown })
            let image = try #require(try await RegionTileRenderer(dimension: dimension, darkSpots: overlay).image(for: region))
            let pixels = try ItemPictureFixture.pixels(image)
            #expect(pixels.color(0, 0) != pixels.color(2, 0))
            let ordinary = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
            #expect(ordinary.allSatisfy { $0?.nightLight == nil && $0?.y == 7 })
        }
    }

    @Test func omittedValidBlockLightUsesTheSharedSavedLayerRule() async throws {
        let root = try world([chunk(block: false) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, darkSpots: overlay))
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
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, darkSpots: overlay))
        for x in 0..<16 { #expect(blocks[x]?.nightLight == (x <= 7 ? .dark : .bright)) }
        let unknown = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, darkSpots: DarkSpots(rule: nil)))
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
        #expect(try ItemPictureFixture.pixels(tinted.full).bytes != ItemPictureFixture.pixels(ordinary.full).bytes)
        let cached = try #require(try await renderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(tinted.full).bytes == ItemPictureFixture.pixels(cached.full).bytes)
        renderer.darkSpots = nil
        let restored = try #require(try await renderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(restored.full).bytes == ItemPictureFixture.pixels(ordinary.full).bytes)
        var bad = try (Data(contentsOf: cache.directory.appendingPathComponent(litKey.fileName)) as NSData).decompressed(using: .lzfse) as Data
        bad[512 * 512 * 9] = 3
        try ((bad as NSData).compressed(using: .lzfse) as Data).write(to: cache.directory.appendingPathComponent(litKey.fileName))
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
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, _ in
            await gate.read(renderer.darkSpots == nil ? "off" : "on")
        })
        map.setNightLighting(overlay.rule)
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        await gate.waitForRequest("off")
        map.setDarkSpots(true)
        await gate.waitForCancellation("off")
        await gate.waitForRequest("on")
        await gate.finish("on", with: after)
        await map.waitUntilIdle()
        await gate.finish("off", with: before)
        await map.waitForRenders()
        #expect(map.tiles[region] === after?.full)
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
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero,
                           readTopBlocks: { _, _, _ in await gate.read("coordinate") })
        var copiedHeight: Int?
        map.readTopBlock(at: CGPoint(x: 3, y: 4)) { copiedHeight = $0?.y }
        await gate.waitForRequest("coordinate")
        map.setDarkSpots(true)
        map.setNightLighting(overlay.rule)
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
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
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

    @Test func mapAndAreaExportsUseTheSameLightPixelsAndLegendInBothAppearances() async throws {
        let root = try world([chunk { x, _, _ in x }])
        defer { try? FileManager.default.removeItem(at: root) }
        let (dimension, overlay) = try inputs(root)
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, regionConcurrency: 1, chunkConcurrency: 1)
        defer { map.close() }
        let plan = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 512, height: 512), blocksPerPixel: 1)
        map.viewport = plan.viewport
        map.setNightLighting(overlay.rule)
        map.setDarkSpots(true)
        map.requestTiles(visibleIn: plan.size, displayScale: 1)
        await map.waitUntilIdle()
        var content = MapContent()
        content.showsDarkSpots = true
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

    private func pngPixels(_ value: MapImage) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(value.data as CFData, nil))
        return try ItemPictureFixture.pixels(#require(CGImageSourceCreateImageAtIndex(source, 0, nil))).bytes
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

    private func chunk(valid: Bool = true, block: Bool = true, sky: Bool = true, malformedBlock: Bool = false,
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
        return .init(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3,
            sections: [.compound(section)], extra: ["isLightOn": .byte(valid ? 1 : 0), "yPos": .int(0)]))
    }
}
