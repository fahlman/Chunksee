import AppKit
import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Observable @MainActor private final class MapStyleDefinitions {
    var value: MapDefinitions
    init(_ value: MapDefinitions) { self.value = value }
}

@Suite(.isolatedStores) struct MapStyleTests {
    @Test func heightScaleChangesPreparedPicturesWithoutRetiringUnlitNormalTiles() async throws {
        let root = try terrainWorld()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        var renderer = RegionTileRenderer(dimension: dimension, heightScale: try heightScale(sea: 40))
        let region = RegionPosition(x: 0, z: 0)
        let first = try #require(try await renderer.tile(for: region))
        renderer.heightScale = try heightScale(sea: 80)
        let second = try #require(try await renderer.tile(for: region))
        #expect(first.key.surface == second.key.surface && first.key != second.key)
        #expect(!renderer.accepts(first.key) && renderer.accepts(second.key))
        #expect(first.full.image.dataProvider?.data as Data? != second.full.image.dataProvider?.data as Data?)
    }

    @Test func savedBuildBoundsAndSeaLevelDefineOneStableHeightScale() throws {
        let scale = try heightScale(sea: 40)
        #expect(scale.bounds == -64...319)
        #expect(scale.level(at: -64) == 0 && scale.level(at: 319) == 1)
        #expect(scale.level(at: 40) == 0.5 && scale.level(at: -12) == 0.25)
        #expect(scale.level(at: Int.min) == 0 && scale.level(at: Int.max) == 1)
        let shifted = try heightScale(sea: 80)
        #expect(shifted.level(at: 80) == 0.5 && shifted.level(at: 40) < 0.5)
        let missing = try heightScale(sea: nil)
        #expect(missing.seaLevel == nil && missing.level(at: 127) < 0.5)
        #expect(missing.level(at: -64) == 0 && missing.level(at: 319) == 1)
        #expect(MapHeightScale(settings: nil) == nil)
    }

    @Test func seaLevelsOutsideOrAtTheBuildLimitsArePreservedWithoutInvalidColours() throws {
        for sea in [-200, -64, 319, 500] {
            let scale = try heightScale(sea: sea)
            #expect(scale.seaLevel == sea)
            let levels = stride(from: -64, through: 319, by: 1).map { scale.level(at: $0) }
            #expect(levels.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(levels == levels.sorted())
            if sea < -64 { #expect(levels.allSatisfy { $0 > 0.5 }) }
            if sea > 319 { #expect(levels.allSatisfy { $0 < 0.5 }) }
        }
    }

    @Test func aDataPacksSavedSeaLevelChangesTheMidpoint() throws {
        let url = try TestWorld.make(chunks: [], dimensionSettings: ["minecraft:overworld":
            TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("example:custom"))])
        defer { try? FileManager.default.removeItem(at: url) }
        let pack = url.appendingPathComponent("datapacks/custom")
        let settings = pack.appendingPathComponent("data/example/worldgen/noise_settings/custom.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"noise":{"min_y":-64,"height":384},"sea_level":100}"#.utf8).write(to: settings)
        try Data(#"{"pack":{"description":"Synthetic height scale","min_format":121,"max_format":121}}"#.utf8)
            .write(to: pack.appendingPathComponent("pack.mcmeta"))
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string("Height Scale"), "DataVersion": .int(Int32(SaveVersion.java26_3)),
            "DataPacks": .compound(["Enabled": .list([.string("vanilla"), .string(TestWorldResources.pack), .string("file/custom")])])
        ])]), to: url.appendingPathComponent("level.dat"))
        let details = WorldDetails.read(try World(contentsOf: url))
        let scale = try #require(MapHeightScale(settings: details.dimensionSettings["minecraft:overworld"]))
        #expect(scale.seaLevel == 100 && scale.level(at: 100) == 0.5 && scale.level(at: 63) < 0.5)
    }

    @Test func heightAndDepthUseTheSameColumnsIncludingCutawaysAndCappedWater() async throws {
        let url = try terrainWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let scale = try #require(MapHeightScale(settings: WorldDetails.read(world).dimensionSettings[dimension.id]))
        let region = RegionPosition(x: 0, z: 0)
        let normal = try #require(try await RegionTileRenderer(dimension: dimension, heightScale: scale).pixels(for: region))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let columns = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(columns[0]?.y == 0 && columns[4]?.y == 40 && columns[8]?.waterDepth == 1 && columns[12]?.waterDepth == 32)
        for style in [MapStyle.height, .waterDepth] {
            let pixels = try #require(try await RegionTileRenderer(dimension: dimension, style: style, heightScale: scale).pixels(for: region))
            for x in [0, 4, 8, 12] {
                let column = try #require(columns[x]), expected: MapColor
                if style == .height {
                    expected = MapStylePalette.heightColor(y: column.y, scale: scale)
                } else if column.waterDepth > 0 {
                    expected = MapStylePalette.waterColor(depth: column.waterDepth)
                } else {
                    #expect(pixel(pixels, x: x) == pixel(normal, x: x))
                    continue
                }
                #expect(pixel(pixels, x: x) == [expected.red, expected.green, expected.blue, 255])
            }
            #expect(pixel(pixels, x: 16) == [0, 0, 0, 0]) // No invented terrain in an absent chunk.
            let cutaway = try #require(try await RegionTileRenderer(dimension: dimension, cutawayY: 30,
                style: style, heightScale: scale).pixels(for: region))
            let expected = style == .height ? MapStylePalette.heightColor(y: 30, scale: scale) : MapStylePalette.waterColor(depth: 15)
            #expect(pixel(cutaway, x: 12) == [expected.red, expected.green, expected.blue, 255])
        }
        #expect(try await RegionTileRenderer(dimension: dimension, style: .height).pixels(for: region) == nil)
    }

    @Test func styleCachesCoexistAndSwitchingBackReadsTheNormalTile() async throws {
        let url = try terrainWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let scale = try #require(MapHeightScale(settings: WorldDetails.read(world).dimensionSettings[dimension.id]))
        let cache = TileCache(directory: url.appendingPathComponent("tiles")), region = RegionPosition(x: 0, z: 0)
        var saved: [MapStyle: Data] = [:]
        for style in MapStyle.allCases {
            let renderer = RegionTileRenderer(dimension: dimension, cache: cache, style: style, heightScale: scale)
            let tile = try #require(try await renderer.tile(for: region))
            await (try #require(tile.cacheWrite)).store()
            saved[style] = try #require(tile.full.image.dataProvider?.data as Data?)
        }
        for style in MapStyle.allCases {
            let renderer = RegionTileRenderer(dimension: dimension, cache: cache, style: style, heightScale: scale)
            let tile = try #require(try await renderer.tile(for: region))
            #expect(tile.cacheWrite == nil)
            #expect(tile.full.image.dataProvider?.data as Data? == saved[style])
        }
        let changedScale = try heightScale(sea: 80), file = dimension.regionURL(at: region)
        for y in [Int?.none, 30] {
            for style in MapStyle.allCases {
                let before = try #require(TileCache.key(for: region, regionFile: file, cutawayY: y, style: style, heightScale: scale))
                let after = try #require(TileCache.key(for: region, regionFile: file, cutawayY: y, style: style, heightScale: changedScale))
                #expect((before == after) == (style != .height))
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func aStyleChangeRejectsOldPixelsButKeepsPendingBlockReads() async throws {
        let url = try terrainWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let scale = try #require(MapHeightScale(settings: WorldDetails.read(world).dimensionSettings[dimension.id]))
        let render = AsyncReadGate<RegionTileRenderer.RenderedTile?>(), columns = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = MapModel(definitions: { .init(context: .unknown, heightScale: scale) }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8),
            renderTile: { renderer, _ in await render.read(renderer.style.rawValue) },
            readTopBlocks: { chunk, _, _ in await columns.read("\(chunk.x)") })
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        map.loadTopBlocks(at: CGPoint(x: 1, y: 1))
        var copiedY: Int?
        map.readTopBlock(at: CGPoint(x: 17, y: 1)) { copiedY = $0?.y }
        await render.waitForRequest("normal")
        let previousRenderer = map.currentRenderer
        await columns.waitForRequest("0")
        await columns.waitForRequest("1")
        map.setStyle(.height)
        await render.waitForCancellation("normal")
        await render.waitForRequest("height")
        let heightImage = try #require(CGImage.rgba([10, 20, 30, 255], width: 1, height: 1))
        await render.finish("height", with: try map.currentRenderer.fixtureTile(heightImage, for: .init(x: 0, z: 0)))
        await map.waitUntilIdle()
        let normalImage = try #require(CGImage.rgba([40, 50, 60, 255], width: 1, height: 1))
        await render.finish("normal", with: try previousRenderer.fixtureTile(normalImage, for: .init(x: 0, z: 0)))
        let block = RegionTileRenderer.TopBlock(id: "minecraft:stone", y: 40, waterDepth: 0)
        await columns.finish("0", with: (file, Array(repeating: block, count: 256)))
        await columns.finish("1", with: (file, Array(repeating: block, count: 256)))
        await map.waitForRenders()
        #expect(map.tiles[.init(x: 0, z: 0)]?.image === heightImage && map.style == .height)
        #expect(map.topBlock(at: CGPoint(x: 1, y: 1)) == block && copiedY == 40)
        map.close()
        map.setStyle(.waterDepth)
        #expect(map.style == .height)
    }

    @Test func stylesRestoreIndependentlyForDimensionDocumentsAndRereads() async throws {
        let url = try terrainWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let first = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let second = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        first.map?.setStyle(.height)
        first.map?.setBiomeBlending(true)
        #expect(first.map?.currentRenderer.samplesNeighborBiomes == false)
        second.map?.setStyle(.waterDepth)
        first.saveView()
        second.saveView()
        let restored = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let restoredNether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(restored.map?.style == .height && restoredNether.map?.style == .waterDepth)
        first.map?.setStyle(.waterDepth)
        restored.restoreView(from: first)
        #expect(restored.map?.style == .waterDepth)
        #expect(second.map?.style == .waterDepth)
        // An unreadable saved build range cannot enable a guessed height scale.
        let dimension = try #require(resources.world.dimension("overworld"))
        let unknown = MapModel(definitions: { .unknown }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: .zero)
        unknown.setStyle(.height)
        #expect(unknown.style == .normal)
        unknown.setStyle(.waterDepth)
        #expect(unknown.style == .waterDepth)
        unknown.close()
        [first, second, restored, restoredNether].forEach { $0.close() }
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func heightChoiceSurvivesMissingGameFilesAndReopening() async throws {
        let id = "minecraft:overworld"
        let root = try terrainWorld(definitions: [id: TestWorld.noiseDimension(
            type: .string("example:game_height"), noise: .string("example:game_height"))])
        let game = try ItemPictureFixture(extraFiles: [
            "data/example/dimension_type/game_height.json": Data(
                #"{"min_y":-64,"height":384,"logical_height":384,"has_ceiling":false,"has_skylight":true}"#.utf8),
            "data/example/worldgen/noise_settings/game_height.json": Data(
                #"{"noise":{"min_y":-64,"height":384},"sea_level":40}"#.utf8),
        ])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        await names.chooseMinecraftFolder(game.root)
        var sessions: [WorldSession] = []
        func open() async throws -> WorldSession {
            let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
                savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                watchWorld: { _, _ in nil })
            let session = WorldSession(resources: resources)
            sessions.append(session)
            await resources.waitForRefresh()
            return session
        }
        var failure: (any Error)?
        do {
            let first = try await open(), map = try #require(first.map)
            let scale = try #require(map.heightScale)
            map.setStyle(.height)
            first.saveView()
            #expect(first.resources.settings.style(for: id) == .height)

            // A real absence changes what can be shown, not what the user chose.
            names.forgetMinecraftFolder()
            await first.resources.waitForRefresh()
            #expect(map.heightScale == nil && map.style == .normal)
            #expect(map.currentRenderer.style == .normal && MapContent(session: first).mapStyle == .normal)
            first.saveView()
            #expect(first.resources.settings.style(for: id) == .height)
            first.close()
            await first.waitUntilClosed()

            // Reopen without the jar: saving a viewport must preserve the unavailable choice.
            let reopened = try await open(), restored = try #require(reopened.map)
            #expect(restored.heightScale == nil && restored.style == .normal)
            reopened.saveView()
            #expect(reopened.resources.settings.style(for: id) == .height)

            // The document reread/move path copies the choice while both maps show Normal.
            let reread = try await open(), rereadMap = try #require(reread.map)
            rereadMap.setStyle(.waterDepth)
            reread.restoreView(from: reopened)
            reread.saveView()
            #expect(reread.resources.settings.style(for: id) == .height)
            await names.chooseMinecraftFolder(game.root)
            for session in [reopened, reread] { await session.resources.waitForRefresh() }
            for current in [restored, rereadMap] {
                #expect(current.heightScale == scale && current.style == .height)
                #expect(current.currentRenderer.style == .height)
            }
            #expect(MapContent(session: reopened).mapStyle == .height)
            let region = RegionPosition(x: 0, z: 0)
            let pixels = try #require(try await restored.currentRenderer.pixels(for: region))
            let expected = MapStylePalette.heightColor(y: 40, scale: scale)
            #expect(pixel(pixels, x: 4) == [expected.red, expected.green, expected.blue, 255])

            for artwork in [false, true] {
                names.minecraft.usesGameArtwork = artwork
                await reopened.resources.waitForRefresh()
                #expect(restored.style == .height && restored.currentRenderer.style == .height)
            }
            await names.chooseMinecraftFolder(game.root)
            await reopened.resources.waitForRefresh()
            #expect(restored.style == .height)
            reopened.saveView()
            #expect(reopened.resources.settings.style(for: id) == .height)
        } catch { failure = error }
        for session in sessions { session.close() }
        for session in sessions { await session.waitUntilClosed() }
        names.forgetMinecraftFolder()
        await names.minecraft.waitUntilIdle()
        if let failure { throw failure }
    }

    @Test(arguments: [MapStyle.normal, .waterDepth])
    func choosingAnAvailableMenuStyleReplacesUnavailableHeight(_ choice: MapStyle) throws {
        let root = try terrainWorld()
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try World(contentsOf: root), dimension = try #require(world.dimension("overworld"))
        let settings = try #require(WorldDetails.read(world).dimensionSettings[dimension.id])
        let definitions = MapStyleDefinitions(.init(settings: settings, water: nil))
        let map = MapModel(definitions: { definitions.value }, gameResources: { .unavailable },
            savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: .zero)
        defer { map.close() }
        map.setStyle(.height)
        definitions.value = .unknown
        #expect(map.chosenStyle == .height && map.style == .normal)

        let menu = NSHostingMenu(rootView: MapStyleOptions(map: map))
        menu.update()
        let normal = try #require(menu.item(at: 0)), height = try #require(menu.item(at: 1))
        #expect(normal.state == .on && normal.isEnabled)
        #expect(height.state == .off && !height.isEnabled)
        menu.performActionForItem(at: choice == .normal ? 0 : 2)
        #expect(map.chosenStyle == choice && map.style == choice)
        definitions.value = .init(settings: settings, water: nil)
        #expect(map.chosenStyle == choice && map.style == choice)
        #expect(map.currentRenderer.style == choice)
    }

    @Test func bothRampsCarryTheirOrderInLightnessAsWellAsHue() {
        func luminance(_ color: MapColor) -> Double {
            func linear(_ byte: UInt8) -> Double {
                let value = Double(byte) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        for (palette, increasing) in [(MapStylePalette.height, true), (MapStylePalette.waterDepth, false)] {
            let values = palette.map(luminance)
            for (a, b) in zip(values, values.dropFirst()) {
                #expect(increasing ? b >= a - 0.002 : b <= a + 0.002) // One-byte sRGB quantization.
            }
            #expect(abs((values.last ?? 0) - (values.first ?? 0)) > 0.5)
        }
        #expect(MapStylePalette.waterColor(depth: 32) == MapStylePalette.waterColor(depth: 100))
    }

    private func pixel(_ pixels: [UInt8], x: Int) -> [UInt8] {
        Array(pixels[x * 4 ..< x * 4 + 4])
    }

    private func definition(sea: Int?) -> NBT {
        var noise: [String: NBT] = ["noise": .compound(["min_y": .int(-64), "height": .int(384)])]
        if let sea { noise["sea_level"] = .int(Int32(sea)) }
        return TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .compound(noise))
    }

    private func heightScale(sea: Int?) throws -> MapHeightScale {
        let url = try TestWorld.make(chunks: [], dimensionSettings: ["minecraft:overworld": definition(sea: sea)])
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(MapHeightScale(settings: WorldDetails.read(try World(contentsOf: url)).dimensionSettings["minecraft:overworld"]))
    }

    private func terrainWorld(definitions: [String: NBT]? = nil) throws -> URL {
        let sections = (0..<4).map { section in
            Fixtures.section(y: section, palette: [.string("minecraft:air"), .string("minecraft:stone"), .string("minecraft:water")],
                indices: (0..<4096).map { index in
                    let x = index % 16, y = section * 16 + index / 256
                    if x < 4 { return y == 0 ? 1 : 0 }
                    if x < 8 { return y <= 40 ? 1 : 0 }
                    if x < 12 { return y == 63 ? 2 : 1 }
                    return y >= 16 ? 2 : 1
                })
        }
        let chunk = TestWorld.ChunkSpec(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
            dataVersion: SaveVersion.java26_3, sections: sections, extra: ["yPos": .int(0)]))
        return try TestWorld.make(chunks: [chunk], dimensionSettings: definitions ?? ["minecraft:overworld": definition(sea: 40)])
    }
}
