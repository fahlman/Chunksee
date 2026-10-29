import ChunkseeKit
import ChunkseeKitTestSupport
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) @MainActor struct MapLightingTests {
    private let region = RegionPosition(x: 0, z: 0)

    @Test func savedAnglesDriveEastWestLightAndTheDimensionsOwnMoon() throws {
        let morning = try lighting(sun: 300), evening = try lighting(sun: 60), midnight = try lighting(sun: 180, moon: 0)
        #expect(morning.direction.x > 0.8 && morning.direction.y > 0.49)
        #expect(evening.direction.x < -0.8 && evening.direction.y > 0.49)
        #expect(midnight.direction == SIMD3(0, 1, 0))
        let custom = try lighting(sun: 180, moon: 60)
        #expect(custom.direction == evening.direction)
        let night = try lighting(sun: 180, factor: 0.24, color: SIMD3(0.48, 0.48, 1))
        let usual = night.tint(increasedContrast: false), contrast = night.tint(increasedContrast: true)
        #expect(usual.z > usual.x && usual.x > 0.4)
        #expect(contrast.x > usual.x && contrast.z > usual.z)
        #expect(try lighting(factor: 10, color: SIMD3(-100, 4, 1)).tint(increasedContrast: true) == SIMD3(0.75, 1, 1))
    }

    @Test func savedDefinitionsChooseSkySupportWithoutDimensionIDOrFixedTimeGuesses() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try await WorldResources.readLighting(World(contentsOf: url), library: nil)
        #expect(read["minecraft:overworld"]?.saved.sunAngle == 30)
        #expect(read["test:fixed_sky"]?.saved.sunAngle == 60)
        #expect(read["test:no_sky"] == nil)
        #expect(read["test:missing_sky"] == nil)
    }

    @Test func matchingAssetsAndRealSavedClockFilesRefreshEveryAttachedTab() async throws {
        let assetReads = TestGameAssets()
        let timeline = try ItemPictureFixture.json(["clock": "test:light", "period_ticks": 100,
            "tracks": ["minecraft:visual/sun_angle": ["modifier": "override", "keyframes": [
                ["ticks": 0, "value": 0], ["ticks": 50, "value": 180]]]]])
        let fixture = try ItemPictureFixture(extraFiles: ["data/test/timeline/day.json": timeline])
        defer { fixture.remove() }
        let type: NBT = .compound(["type": .compound(["min_y": .int(0), "height": .int(256), "logical_height": .int(256),
            "has_ceiling": .byte(0), "has_skylight": .byte(1), "timelines": .string("test:day")])])
        let url = try TestWorld.make(chunks: [], dimensionSettings: ["minecraft:overworld": type])
        defer { try? FileManager.default.removeItem(at: url) }
        let clockFile = url.appendingPathComponent("data/minecraft/world_clocks.dat")
        func saveClock(_ ticks: Int64) throws {
            try Fixtures.writeGzippedNBT(.compound(["data": .compound(["test:light": .compound(["total_ticks": .long(ticks)])])]), to: clockFile)
        }
        try saveClock(0)
        let resources = try await resources(url, defaults: TestDefaults.make(), assetReads: assetReads)
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        let game = try fixture.resources(), library = try #require(resources.names.minecraft.artwork(for: game))
        await assetReads.publish(game, to: resources)
        await resources.waitForRefresh()
        #expect(first.map?.savedLighting?.saved.sunAngle == 0 && second.map?.savedLighting?.saved.sunAngle == 0)
        try saveClock(50); resources.worldChanged([clockFile]); await resources.waitForRefresh()
        #expect(first.map?.savedLighting?.saved.sunAngle == 180 && second.map?.savedLighting?.saved.sunAngle == 180)
        try Data([0]).write(to: clockFile); resources.worldChanged([clockFile]); await resources.waitForRefresh()
        #expect(first.map?.savedLighting?.saved.sunAngle == 180) // Failed read retains the last good clock.
        resources.close(); await resources.waitUntilClosed(); await library.close()
    }

    @Test func daylightKeepsTheExistingPixelsAndSavedLightingPreparesSafeNormals() throws {
        var surface = RegionTileRenderer.Canvas()
        for z in 0..<4 { for x in 0..<4 {
            surface.set(x: x, z: z, column: column(y: x))
        } }
        surface.set(x: 10, z: 10, column: column(y: Int(Int32.max)))
        surface.set(x: 9, z: 10, column: column(y: Int(Int32.min) + 1))
        surface.set(x: 20, z: 20, column: column(y: 12, water: 8))
        let daylight = surface.drawingPixels(heightScale: nil, includesNormals: false)
        #expect(daylight.normals == nil && daylight.pixels == surface.litPixels(heightScale: nil))
        let saved = surface.drawingPixels(heightScale: nil, includesNormals: true)
        let normals = try #require(saved.normals)
        #expect(pixel(normals, x: 2, z: 2) == [37, 218, 128, 255])
        #expect(pixel(normals, x: 0, z: 0) == pixel(normals, x: 2, z: 2))
        #expect(pixel(normals, x: 10, z: 10) == [0, 128, 128, 255])
        #expect(pixel(normals, x: 20, z: 20) == [0, 0, 0, 255])
        #expect(pixel(saved.pixels, x: 20, z: 20) == pixel(surface.pixels, x: 20, z: 20))
        #expect(pixel(saved.pixels, x: 2, z: 2)[0] > 200) // Some fixed relief remains at noon.
        let previews = RegionTileRenderer.halfSizeNormals(normals, colors: saved.pixels)
        #expect(pixel(previews, x: 1, z: 1, side: 256) == pixel(normals, x: 2, z: 2))
        #expect(pixel(previews, x: 10, z: 10, side: 256) == [0, 0, 0, 255])
    }

    @Test func switchingLightingReusesTheUnlitDiskCacheWithoutDecodingChunks() async throws {
        let url = try TestWorld.make(chunks: [chunk()])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = dimension.regionURL(at: region), date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let cache = TileCache(directory: url.appendingPathComponent("tiles"))
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        let daylight = try #require(try await renderer.tile(for: region))
        let key = try #require(TileCache.key(for: region, regionFile: file))
        let bytes = try Data(contentsOf: cache.directory.appendingPathComponent(try #require(key.fileName)))
        try Data(repeating: 0, count: key.file.size).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        renderer.usesSavedLighting = true
        let saved = try #require(try await renderer.tile(for: region))
        #expect(saved.cacheWrite == nil && saved.full.normals != nil && saved.preview.normals != nil)
        #expect(try Data(contentsOf: cache.directory.appendingPathComponent(try #require(key.fileName))) == bytes)
        #expect(try ItemPictureFixture.pixels(saved.full.image).color(8, 8)[3] == 255)
        renderer.usesSavedLighting = false
        let restored = try #require(try await renderer.tile(for: region))
        #expect(restored.full.normals == nil)
        #expect(try ItemPictureFixture.pixels(restored.full.image).bytes == ItemPictureFixture.pixels(daylight.full.image).bytes)
    }

    @Test func clockOnlyChangesRetainImagesHoverAndViewportAndDaylightIsRemembered() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let resources = try await resources(url, defaults: defaults)
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources, dimensionID: "test:fixed_sky")
        await resources.waitForRefresh()
        let map = try #require(first.map), other = try #require(second.map)
        #expect(map.lighting?.saved.sunAngle == 30 && other.lighting?.saved.sunAngle == 60)
        map.viewport = MapViewport(center: CGPoint(x: 8, y: 8), scale: 2)
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        map.loadTopBlocks(at: CGPoint(x: 8, y: 8))
        await map.waitUntilIdle(); await map.waitForTopBlocks()
        let tile = try #require(map.tiles[region]), viewport = map.viewport, top = map.topBlock(at: CGPoint(x: 8, y: 8))
        resources.readPlayers = { _, _ in Issue.record("Clock-only saves must not read players"); return nil }
        resources.readBiomeColors = { _, _, _, _, _ in Issue.record("Clock-only saves must not read biomes"); throw CancellationError() }
        let updated = try lighting(sun: 60)
        resources.readLighting = { _, _ in ["minecraft:overworld": updated] }
        resources.worldChanged([url.appendingPathComponent("data/minecraft/world_clocks.dat")])
        await resources.waitForRefresh()
        #expect(map.lighting == updated && map.tiles[region] === tile && map.viewport == viewport)
        #expect(map.topBlock(at: CGPoint(x: 8, y: 8))?.y == top?.y)
        #expect(other.lighting == nil)
        map.setLightingMode(.daylight); first.saveView()
        #expect(map.lighting == nil && map.savedLighting == updated)
        #expect(resources.settings.lightingMode(for: "minecraft:overworld") == .daylight)
        #expect(resources.settings.lightingMode(for: "test:fixed_sky") == .savedTime)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func savesCoalesceAndFailureEmptyAndCloseRemainDistinct() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = try await resources(url, defaults: TestDefaults.make()), session = WorldSession(resources: resources)
        await resources.waitForRefresh()
        let gate = AsyncReadGate<[String: MapLighting]>(), numbers = ReadNumbers()
        let playerGate = AsyncReadGate<[PlayerInfo]?>()
        resources.readLighting = { _, _ in await gate.read(String(await numbers.next())) }
        resources.readPlayers = { _, _ in await playerGate.read("players") }
        let file = url.appendingPathComponent("data/world_clocks.dat")
        resources.worldChanged([file]); await gate.waitForRequest("0")
        // Player entry is after refreshLighting in the actual file-change pass, proving each
        // request reached the lighting loader while its first read was held. Release each
        // player read so the definition loader can start the next sequential pass.
        resources.worldChanged([file, resources.world.playerDataDirectory])
        await playerGate.waitForRequest("players")
        await playerGate.finish("players", with: nil)
        resources.worldChanged([file, resources.world.playerDataDirectory])
        await playerGate.waitForRequest("players", count: 2)
        await playerGate.finishAll(with: nil)
        let first = try lighting(sun: 300), newest = try lighting(sun: 60)
        await gate.finish("0", with: ["minecraft:overworld": first])
        await gate.waitForRequest("1")
        #expect(session.map?.savedLighting == first)
        await gate.finish("1", with: ["minecraft:overworld": newest])
        await resources.waitForRefresh()
        #expect(await gate.requested == ["0", "1"])
        #expect(session.map?.savedLighting == newest)
        resources.readLighting = { _, _ in throw CocoaError(.fileReadUnknown) }
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(session.map?.savedLighting == newest)
        resources.readLighting = { _, _ in [:] }
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(session.map?.savedLighting == nil)
        resources.readLighting = { _, _ in await gate.read("closing") }
        resources.worldChanged([file]); await gate.waitForRequest("closing")
        resources.close(); await gate.waitForCancellation("closing")
        await gate.finish("closing", with: ["minecraft:overworld": newest]); await resources.waitUntilClosed()
        #expect(session.map?.savedLighting == nil && session.isClosed)
    }

    @Test(.timeLimit(.minutes(1))) func replacementLibraryRetiresLightingForExistingAndNewDimensions() async throws {
        let assetReads = TestGameAssets()
        let url = try world(), fixture = try ItemPictureFixture()
        defer { try? FileManager.default.removeItem(at: url); fixture.remove() }
        let resources = try await resources(url, defaults: TestDefaults.make(), assetReads: assetReads), first = WorldSession(resources: resources)
        await resources.waitForRefresh()
        let a = try fixture.resources(), b = try fixture.resources(), c = try fixture.resources()
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let old = try lighting(sun: 300), updated = try lighting(sun: 60)
        let oldValues = ["minecraft:overworld": old, "test:fixed_sky": old]
        let newValues = ["minecraft:overworld": updated, "test:fixed_sky": updated]
        resources.readLighting = { _, _ in oldValues }
        await assetReads.publish(a, to: resources); await resources.waitForRefresh()
        #expect(first.map?.savedLighting == old)
        resources.names.minecraft.usesGameArtwork = false
        await resources.waitForRefresh()
        #expect(first.map?.savedLighting == old)

        let gate = AsyncReadGate<Result<[String: MapLighting], CocoaError>>()
        resources.readLighting = { _, library in
            try await gate.read(library?.identity.uuidString ?? "none").get()
        }
        await assetReads.publish(b, to: resources)
        #expect(first.map?.savedLighting == nil)
        let second = WorldSession(resources: resources, dimensionID: "test:fixed_sky")
        #expect(second.map?.savedLighting == nil)
        await gate.waitForRequest(b.identity.uuidString)
        await gate.finish(b.identity.uuidString, with: .failure(CocoaError(.fileReadUnknown)))
        await resources.waitForRefresh()
        #expect(first.map?.savedLighting == nil && second.map?.savedLighting == nil)
        let file = url.appendingPathComponent("data/world_clocks.dat")
        resources.worldChanged([file]); await gate.waitForRequest(b.identity.uuidString, count: 2)
        await gate.finish(b.identity.uuidString, with: .success(newValues))
        await resources.waitForRefresh()
        #expect(first.map?.savedLighting == updated && second.map?.savedLighting == updated)

        resources.worldChanged([file]); await gate.waitForRequest(b.identity.uuidString, count: 3)
        #expect(first.map?.savedLighting == updated)
        await assetReads.publish(c, to: resources)
        await gate.waitForCancellation(b.identity.uuidString)
        await gate.waitForRequest(c.identity.uuidString)
        #expect(first.map?.savedLighting == nil && second.map?.savedLighting == nil)
        first.close() // A sibling still owns the world's shared replacement read.
        #expect(!resources.isClosed)
        await gate.finish(b.identity.uuidString, with: .success(oldValues))
        await gate.finish(c.identity.uuidString, with: .success(newValues))
        await resources.waitForRefresh()
        #expect(second.map?.savedLighting == updated)
        await assetReads.publish(nil, to: resources)
        #expect(second.map?.savedLighting == nil)
        await gate.waitForRequest("none")
        let saveOnly = try await WorldResources.readLighting(resources.world, library: nil)
        await gate.finish("none", with: .success(saveOnly))
        await resources.waitForRefresh()
        #expect(second.map?.savedLighting == saveOnly["test:fixed_sky"])
        #expect(resources.names.minecraft.generation == source.generation)
        resources.close(); await resources.waitUntilClosed()
        for library in [a, b, c] {
            if let artwork = resources.names.minecraft.artwork(for: library) { await artwork.close() }
            await library.data.close()
        }
    }

    @Test func normalImagesShareTheExistingEvictionBudgetAndHeightBypassesThem() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let neighbor = RegionPosition(x: 1, z: 0)
        try Data(TestWorld.regionFile([TestWorld.chunk(x: 32, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }]))
            .write(to: dimension.regionURL(at: neighbor))
        let scale = try #require(MapHeightScale(settings: WorldDetails.read(world).dimensionSettings[dimension.id]))
        let savedLighting = TestSavedLighting()
        let work = BackgroundWork(), map = MapModel(definitions: { .init(context: .unknown, heightScale: scale) }, gameResources: { .unavailable }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: work, dimension: dimension, center: CGPoint(x: 8, y: 8),
            maxTiles: 3, maxPreviews: 3)
        savedLighting.value = try lighting()
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8)); await map.waitUntilIdle()
        #expect(map.tiles[region]?.storageUnits == 2 && map.previews[region]?.storageUnits == 2)
        map.viewport.center.x = 520
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8)); await map.waitUntilIdle()
        #expect(Set(map.tiles.keys) == [neighbor] && Set(map.previews.keys) == [neighbor])
        map.setStyle(.height); await map.waitUntilIdle()
        #expect(map.lighting == nil && !map.currentRenderer.usesSavedLighting)
        #expect(map.tiles[neighbor]?.normals == nil && map.tiles[neighbor]?.storageUnits == 1)
        map.setStyle(.normal); await map.waitUntilIdle()
        #expect(map.lighting != nil && map.tiles[neighbor]?.normals != nil)
        map.close(); await work.waitUntilFinished()
    }

    @Test func nativeShaderChangesDirectionAndNightTintAndProtectsTheWaterPalette() throws {
        let size = CGSize(width: 64, height: 32), viewport = MapViewport(center: CGPoint(x: 256, y: 256), scale: 0.125)
        let tile = try testTile()
        func draw(_ light: MapLighting, water: Bool = false, contrast: ColorSchemeContrast = .standard) throws -> [UInt8] {
            let context = try #require(MapImage.imageContext(width: 64, height: 32))
            #expect(MapImage.drawTerrainLayer(tile, region: region, viewport: viewport, size: size, scale: 1,
                                              lighting: light, protectsWater: water, contrast: contrast, into: context))
            return try rgba(#require(context.makeImage()))
        }
        let morning = try draw(lighting(sun: 300)), evening = try draw(lighting(sun: 60))
        #expect(pixel(morning, x: 8, z: 16, side: 64)[0] < pixel(evening, x: 8, z: 16, side: 64)[0])
        #expect(pixel(morning, x: 24, z: 16, side: 64)[0] > pixel(evening, x: 24, z: 16, side: 64)[0])
        let night = try lighting(sun: 180, factor: 0.24, color: SIMD3(0.48, 0.48, 1))
        let dim = try draw(night), bright = try draw(night, contrast: .increased), protected = try draw(night, water: true)
        #expect(pixel(dim, x: 56, z: 16, side: 64)[2] > pixel(dim, x: 56, z: 16, side: 64)[0])
        #expect(pixel(bright, x: 56, z: 16, side: 64)[0] > pixel(dim, x: 56, z: 16, side: 64)[0])
        #expect(pixel(protected, x: 56, z: 16, side: 64) == [200, 200, 200, 255])
    }

    @Test(arguments: [1.0, 2.0]) func croppedShaderExportMatchesNativeCanvasAcrossRasterPieces(scale: Double) throws {
        let size = CGSize(width: 1301, height: 129), viewport = MapViewport(center: CGPoint(x: -140, y: 8), scale: 4)
        let tile = try testTile(), region = RegionPosition(x: -1, z: 0), light = try lighting(sun: 300)
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, actualSize in
            MapView.drawTerrain(viewport: viewport, regions: [region], image: { _ in tile }, lighting: light,
                                increasedContrast: true, in: context, size: actualSize)
        }.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas); renderer.scale = scale
        let expected = try rgba(#require(renderer.cgImage))
        let destination = try #require(MapImage.imageContext(width: Int(size.width * scale), height: Int(size.height * scale)))
        #expect(MapImage.drawTerrainLayer(tile, region: region, viewport: viewport, size: size, scale: scale,
                                          lighting: light, protectsWater: false, contrast: .increased, into: destination))
        let actual = try rgba(#require(destination.makeImage()))
        #expect(actual == expected)
    }

    @Test func exportedAreaAndCopiedViewShareLightingAndUnlitOverlays() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = try await resources(url, defaults: TestDefaults.make()), session = WorldSession(resources: resources)
        await resources.waitForRefresh()
        let map = try #require(session.map)
        let light = try lighting(sun: 180, factor: 0.24, color: SIMD3(0.48, 0.48, 1))
        resources.readLighting = { _, _ in ["minecraft:overworld": light] }
        resources.worldChanged([url.appendingPathComponent("data/world_clocks.dat")])
        await resources.waitForRefresh()
        for downsample in [1, 2] {
            let plan = try MapExportPlan(bounds: CGRect(x: -8, y: -8, width: 32, height: 32), blocksPerPixel: downsample)
            map.viewport = plan.viewport; map.requestTiles(visibleIn: plan.size, displayScale: 1); await map.waitUntilIdle()
            var content = MapContent(session: session); content.showsGrid = true
            for scheme in [ColorScheme.light, .dark] {
                let copy = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: plan.size,
                    scale: 1, colorScheme: scheme, locale: .current, contrast: .increased))
                let export = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: map.currentRenderer,
                    content: content, portalStatus: { _ in nil }, colorScheme: scheme, locale: .current,
                    contrast: .increased, progress: { _, _ in })
                #expect(try pngPixels(copy) == pngPixels(export))
            }
        }
        resources.close(); await resources.waitUntilClosed()
    }

    private func lighting(sun: Float = 0, moon: Float = 0, factor: Float = 1,
                          color: SIMD3<Float> = SIMD3(repeating: 1)) throws -> MapLighting {
        let time = try JSONDecoder().decode(DimensionTime.self, from: Data(#"{"has_skylight":true}"#.utf8))
        let saved = try #require(SkyLighting(sunAngle: sun, moonAngle: moon, skyLightFactor: factor, skyLightColor: color, moonPhase: .fullMoon))
        return try #require(MapLighting(saved: saved, time: time))
    }

    private func chunk() -> TestWorld.ChunkSpec {
        TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { x, y, _ in y <= x / 2 ? 1 : 0 }
    }

    private func world() throws -> URL {
        func definition(angle: Float, sky: NBT?, fixed: Bool = false) -> NBT {
            var value: [String: NBT] = ["min_y": .int(0), "height": .int(256), "logical_height": .int(256),
                "has_ceiling": .byte(0), "has_fixed_time": .byte(fixed ? 1 : 0),
                "attributes": .compound(["minecraft:visual/sun_angle": .float(angle)])]
            value["has_skylight"] = sky
            return .compound(["type": .compound(value)])
        }
        let url = try TestWorld.make(chunks: [chunk()], dimensionSettings: [
            "minecraft:overworld": definition(angle: 30, sky: .byte(1)),
            "test:fixed_sky": definition(angle: 60, sky: .byte(1), fixed: true),
            "test:no_sky": definition(angle: 90, sky: .byte(0)),
            "test:missing_sky": definition(angle: 120, sky: nil)])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/test/fixed_sky/region"), withIntermediateDirectories: true)
        return url
    }

    private func resources(_ url: URL, defaults: UserDefaults, assetReads: TestGameAssets? = nil) async throws -> WorldResources {
        let value = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil }, readGameAssets: { minecraft in
                if let assetReads { return try await assetReads.read(minecraft) }
                return try await minecraft.readLibrary()
            })
        value.refreshDelay = .zero
        return value
    }

    private func column(y: Int, water: Int = 0) -> RegionTileRenderer.Column {
        .init(y: y, color: MapColor(0xc8c8c8), waterDepth: water, section: 0, palette: 0)
    }

    private func testTile() throws -> MapTileImage {
        let image = try #require(CGImage.rgba(Array(repeating: [UInt8(200), 200, 200, 255], count: 4).flatMap { $0 }, width: 4, height: 1))
        let normals = try #require(CGImage.rgba([37, 218, 128, 255, 218, 218, 128, 255, 128, 255, 128, 255, 0, 0, 0, 255],
                                               width: 4, height: 1, colorSpace: CGColorSpace.linearSRGB))
        return MapTileImage(image, normals: normals)
    }

    private func pixel(_ pixels: [UInt8], x: Int, z: Int, side: Int = 512) -> [UInt8] {
        let i = (z * side + x) * 4
        return Array(pixels[i..<i + 4])
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(MapImage.imageContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func pngPixels(_ png: MapImage) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(png.data as CFData, nil))
        return try rgba(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }
}
