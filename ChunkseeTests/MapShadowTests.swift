import ChunkseeKit
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) @MainActor struct MapShadowTests {
    private let region = RegionPosition(x: 0, z: 0)
    private let side = RegionTileRenderer.side

    private func flat(_ y: Int32 = 0) -> [Int32] { Array(repeating: y, count: side * side) }
    private func light(x: Int = -1, rise: Double = 1) -> MapShadow.Light { .init(x: x, z: 0, rise: rise) }

    @Test func pillarLengthFollowsLightElevationAndFlatGroundHasNoShadow() throws {
        #expect(try MapShadow.mask(for: region, heights: [region: flat()], light: .daylight).allSatisfy { $0 == 0 })
        var heights = flat()
        heights[20 * side + 20] = 10
        let mask = try MapShadow.mask(for: region, heights: [region: heights], light: light())
        #expect(mask.filter { $0 != 0 }.count == 9)
        #expect(mask[20 * side + 20] == 0 && mask[20 * side + 21] == 255)
        #expect(mask[20 * side + 29] == 255 && mask[20 * side + 30] == 0)
        let low = try MapShadow.mask(for: region, heights: [region: heights], light: light(rise: 0.5))
        #expect(low.filter { $0 != 0 }.count == 19)
    }

    @Test func negativeRegionBordersAndCornerShadowsMatchInteriorColumns() throws {
        let west = RegionPosition(x: -1, z: 0), northWest = RegionPosition(x: -1, z: -1)
        var adjacent = flat(), interior = flat()
        adjacent[20 * side + side - 1] = 10
        interior[20 * side + 100] = 10
        let border = try MapShadow.mask(for: region, heights: [region: flat(), west: adjacent], light: light())
        let middle = try MapShadow.mask(for: region, heights: [region: interior], light: light())
        for x in 0..<15 { #expect(border[20 * side + x] == middle[20 * side + 101 + x]) }
        var corner = flat()
        corner[side * side - 1] = 10
        let diagonal = try MapShadow.mask(for: region, heights: [region: flat(), northWest: corner], light: .daylight)
        #expect(diagonal.filter { $0 != 0 }.count == 9)
        for offset in 0..<9 { #expect(diagonal[offset * side + offset] == 255) }
        #expect(diagonal[9 * side + 9] == 0)
    }

    @Test func unknownColumnsDoNotReceiveOrCreateShadowsAndExtremeHeightsStayChecked() throws {
        var heights = flat(Int32.min + 1)
        heights[0] = Int32.max
        heights[1] = RegionTileRenderer.Canvas.noHeight
        let mask = try MapShadow.mask(for: region, heights: [region: heights], light: light())
        #expect(mask[0] == 0 && mask[1] == 0 && mask[2] == 255)
        let malformed = try MapShadow.mask(for: region, heights: [region: [1, 2, 3]], light: light())
        #expect(malformed.allSatisfy { $0 == 0 })
        let edge = RegionPosition(x: Int.min, z: Int.max)
        #expect(MapShadow.sources(for: edge, light: .daylight).allSatisfy { $0.x == Int.min && $0.z >= Int.max - 1 })
    }

    @Test func rayReachIsMeasuredFromEachReceiverRatherThanItsRegionEdge() throws {
        let west = RegionPosition(x: -1, z: 0)
        var adjacent = flat()
        adjacent[0] = 1000
        let mask = try MapShadow.mask(for: region, heights: [region: flat(), west: adjacent], light: light())
        #expect(mask[0] == 255 && mask[1] == 0)
    }

    @Test func savedSunOrMoonUsesTheExistingLightDirectionWithoutInventingOne() throws {
        let morning = try #require(MapShadow.Light.saved(SIMD3(1, 1, 0)))
        let evening = try #require(MapShadow.Light.saved(SIMD3(-1, 0.5, 0)))
        #expect(morning.x == 1 && morning.rise == 1)
        #expect(evening.x == -1 && evening.rise == 0.5)
        for direction: SIMD3<Float> in [SIMD3(0, 1, 0), SIMD3(1, -1, 0), SIMD3(.nan, 1, 0), SIMD3(1, .infinity, 0)] {
            #expect(MapShadow.Light.saved(direction) == nil)
        }
        #expect(MapShadow.retainedSources(for: region, savedTime: true) == [
            .init(x: -1, z: 0), region, .init(x: 1, z: 0)])
        #expect(MapShadow.retainedSources(for: region, savedTime: false) == [
            .init(x: -1, z: -1), .init(x: 0, z: -1), .init(x: -1, z: 0), region])
    }

    @Test func cancellationStopsTheSameBackgroundMaskWork() async throws {
        let task = Task { try await MapShadow.image(for: region, heights: [region: flat()], light: .daylight) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled shadow work must throw") }
        catch is CancellationError { }
    }

    @Test func eachDimensionRemembersItsOwnShadowChoice() throws {
        let defaults = TestDefaults.make(), id = UUID(), view = MapViewport(center: .zero, scale: 1)
        let settings = WorldSettings(id: id, defaults: defaults)
        #expect(settings.castsShadows(for: "minecraft:overworld"))
        settings.save(view, for: "minecraft:overworld", selected: nil, castsShadows: false)
        settings.save(view, for: "minecraft:the_nether", selected: nil, castsShadows: true)
        let restored = WorldSettings(id: id, defaults: defaults)
        #expect(!restored.castsShadows(for: "minecraft:overworld"))
        #expect(restored.castsShadows(for: "minecraft:the_nether"))
    }

    @Test func waterAndLandUseTheSameMaskWhileIncreasedContrastStaysLighter() async throws {
        var heights = flat()
        heights[8 * side + 7] = 2
        let shadow = try #require(try await MapShadow.image(for: region, heights: [region: heights], light: light()))
        let image = try #require(CGImage.rgba(Array(repeating: [UInt8(180), 200, 230, 255], count: side * side).flatMap { $0 },
                                             width: side, height: side))
        let tile = MapTileImage(image), viewport = MapViewport(center: CGPoint(x: 8.5, y: 8.5), scale: 16)
        func draw(contrast: Bool, water: Bool) throws -> [UInt8] {
            let view = Canvas { context, size in
                MapView.drawTerrain(viewport: viewport, regions: [region], image: { _ in tile }, shadow: { _ in shadow },
                                    protectsWater: water, increasedContrast: contrast, in: context, size: size)
            }.frame(width: 16, height: 16)
            let renderer = ImageRenderer(content: view)
            let output = try #require(renderer.cgImage)
            return try ItemPictureFixture.pixels(output).color(8, 8)
        }
        let land = try draw(contrast: false, water: false), water = try draw(contrast: false, water: true)
        let contrast = try draw(contrast: true, water: true)
        #expect(land == water && land[0] < 180 && land[3] == 255)
        #expect(contrast[0] > water[0] && contrast[0] < 180)
    }

    @Test(.timeLimit(.minutes(1))) func movingAnOverheadSunReusesNeighborHeightsAndTintOnlyChangesKeepTheMask() async throws {
        let url = try borderWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld")), reads = ReadNumbers()
        let work = BackgroundWork()
        let savedLighting = TestSavedLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: work, dimension: dimension, center: CGPoint(x: 4, y: 8),
                           maxTiles: 1, maxPreviews: 1,
                           renderTile: { renderer, region in
                               _ = await reads.next()
                               return try await renderer.tile(for: region)
                           })
        savedLighting.value = try lighting(sun: 0)
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8))
        await map.waitUntilIdle()
        #expect(map.shadowImages.isEmpty)
        #expect(await reads.next() == 2) // The visible tile and the offscreen caster, once each.
        let tile = try #require(map.tiles[region])
        savedLighting.value = try lighting(sun: 60)
        await map.waitUntilIdle()
        let mask = try #require(map.shadowImages[region])
        #expect(try ItemPictureFixture.pixels(mask).color(4, 8)[3] == 255)
        #expect(map.tiles[region] === tile)
        #expect(await reads.next() == 3)
        // Evicting an offscreen color image must not cause another terrain read when its
        // heights are still retained. Changing resolution alone also keeps the same mask.
        map.viewport = MapViewport(center: CGPoint(x: 4, y: 8), scale: 0.25)
        map.requestTiles(visibleIn: CGSize(width: 2, height: 2), displayScale: 1)
        await map.waitUntilIdle()
        #expect(map.shadowImages[region] === mask && map.previews.count == 1)
        #expect(await reads.next() == 4)
        savedLighting.value = try lighting(sun: 60, factor: 0.5)
        #expect(!map.isLoading && map.shadowImages[region] === mask)
        #expect(await reads.next() == 5)
        savedLighting.value = try lighting(sun: 300)
        #expect(map.isLoading)
        work.close() // Cancel before the background result can return to this actor.
        await map.waitForRenders()
        #expect(!map.isLoading && map.shadowImages[region] === mask)
        map.close()
        #expect(map.shadowImages.isEmpty)
    }

    @Test func regionEditsAndRemovalReplaceTheOffscreenCastersWithoutMovingTheView() async throws {
        let url = try borderWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let savedLighting = TestSavedLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 4, y: 8))
        savedLighting.value = try lighting(sun: 60)
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8))
        await map.waitUntilIdle()
        #expect(map.shadowImages[region] != nil)
        let west = RegionPosition(x: -1, z: 0), file = dimension.regionURL(at: west)
        // A changed but temporarily unreadable region must not retain its old caster heights.
        try Data([0]).write(to: file)
        map.regionsChanged([west])
        await map.waitUntilIdle()
        #expect(map.shadowImages[region] == nil)
        try FileManager.default.removeItem(at: file)
        map.regionsChanged([west])
        await map.waitUntilIdle()
        #expect(!map.availableRegions.contains(west) && map.shadowImages[region] == nil)
        map.close(); await map.waitForRenders()
    }

    @Test func cutawaysAndHiddenBlocksReplaceTheSurfaceUsedForShadows() async throws {
        let url = try borderWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let savedLighting = TestSavedLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 4, y: 8))
        savedLighting.value = try lighting(sun: 60)
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8))
        await map.waitUntilIdle()
        #expect(map.shadowImages[region] != nil)
        map.setDepth(MapDepth(y: 0, isSurface: false))
        await map.waitUntilIdle()
        #expect(map.shadowImages.isEmpty)
        map.setDepth(MapDepth())
        await map.waitUntilIdle()
        #expect(map.shadowImages[region] != nil)
        map.setBlockFilter(MapBlockFilter(hiddenIDs: ["minecraft:stone"]))
        await map.waitUntilIdle()
        #expect(map.shadowImages.isEmpty)
        map.close(); await map.waitForRenders()
    }

    @Test(.timeLimit(.minutes(1))) func hidingShadowsRejectsALateNeighborReadAndShowingThemRestoresTheBorder() async throws {
        let url = try borderWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let west = RegionPosition(x: -1, z: 0), gate = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        var neighborRenderer = RegionTileRenderer(dimension: dimension)
        neighborRenderer.usesSavedLighting = true
        let neighbor = try #require(try await neighborRenderer.tile(for: west))
        let savedLighting = TestSavedLighting()
        let map = MapModel(gameResources: { .unavailable }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 4, y: 8),
                           renderTile: { renderer, region in
                               if region == west { return await gate.read("neighbor") }
                               return try await renderer.tile(for: region)
                           })
        savedLighting.value = try lighting(sun: 60)
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8))
        await gate.waitForRequest("neighbor")
        map.setCastsShadows(false)
        await gate.waitForCancellation("neighbor")
        await gate.finish("neighbor", with: neighbor)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.shadowImages.isEmpty)
        await gate.releaseAllAndFuture(with: neighbor)
        map.setCastsShadows(true)
        await map.waitUntilIdle()
        #expect(map.shadowImages[region] != nil)
        map.close(); await map.waitForRenders()
    }

    @Test func borderShadowsMatchCurrentViewAndAreaExportsInBothAppearances() async throws {
        let url = try borderWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let session = WorldSession(resources: resources)
        await resources.waitForRefresh()
        let map = try #require(session.map)
        for saved in [false, true] {
            let lights = saved ? ["minecraft:overworld": try lighting(sun: 60)] : [:]
            resources.readLighting = { _, _ in lights }
            resources.worldChanged([url.appendingPathComponent("data/world_clocks.dat")])
            await resources.waitForRefresh()
            for downsample in [1, 2] {
                let plan = try MapExportPlan(bounds: CGRect(x: -4, y: 4, width: 16, height: 8), blocksPerPixel: downsample)
                map.viewport = plan.viewport; map.requestTiles(visibleIn: plan.size, displayScale: 1)
                await map.waitUntilIdle()
                #expect(map.shadowImages[region] != nil)
                let content = MapContent(session: session)
                for appearance in [ColorScheme.light, .dark] {
                    for contrast in [ColorSchemeContrast.standard, .increased] {
                        let copy = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: plan.size,
                            scale: 1, colorScheme: appearance, locale: .current, contrast: contrast))
                        let export = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: map.currentRenderer,
                            content: content, portalStatus: { _ in nil }, colorScheme: appearance, locale: .current,
                            contrast: contrast, progress: { _, _ in })
                        #expect(try pixels(copy) == pixels(export))
                    }
                }
            }
        }
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func drawingAdjacentShadowTilesDoesNotAddADarkerJoin() throws {
        let image = try #require(CGImage.rgba([200, 200, 200, 255], width: 1, height: 1))
        let mask = try #require(CGImage.rgba([0, 0, 0, 255], width: 1, height: 1))
        for scale in [0.125, 0.5, 1, 4] {
            let view = Canvas { context, size in
                MapView.drawTerrain(viewport: MapViewport(center: CGPoint(x: 0, y: 8), scale: scale),
                    regions: [.init(x: -1, z: 0), region], image: { _ in MapTileImage(image) },
                    shadow: { _ in mask }, in: context, size: size)
            }.frame(width: 16, height: 8)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let output = try ItemPictureFixture.pixels(#require(renderer.cgImage))
            for x in 0..<32 { #expect(output.color(x, 8) == output.color(2, 8)) }
        }
    }

    private func borderWorld() throws -> URL {
        try TestWorld.make(chunks: [-1, 0].map { chunkX in
            TestWorld.chunk(x: chunkX, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { x, y, z in
                y == 0 || (chunkX == -1 && x == 15 && z == 8 && y <= 10) ? 1 : 0
            }
        })
    }

    private func lighting(sun: Float, factor: Float = 1) throws -> MapLighting {
        let time = try JSONDecoder().decode(DimensionTime.self, from: Data(#"{"has_skylight":true}"#.utf8))
        let saved = try #require(SkyLighting(sunAngle: sun, moonAngle: 0, skyLightFactor: factor,
                                            skyLightColor: SIMD3(repeating: 1), moonPhase: .fullMoon))
        return try #require(MapLighting(saved: saved, time: time))
    }

    private func pixels(_ image: MapImage) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        return try ItemPictureFixture.pixels(#require(CGImageSourceCreateImageAtIndex(source, 0, nil))).bytes
    }
}
