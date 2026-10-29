import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct BiomeOutlineColorsTests {
    @Test func knownPaletteWinsAndOtherBiomesUseTheirDefinitionsAndWaterTags() async throws {
        let land = try definition(grass: 0x123456, foliage: 0xabcdef, water: 0x654321)
        let fixture = try ItemPictureFixture(extraFiles: [
            "data/minecraft/worldgen/biome/plains.json": land,
            "data/test/worldgen/biome/land.json": land,
            "data/test/worldgen/biome/ocean.json": land,
            "data/test/worldgen/biome/river.json": land,
            "data/test/worldgen/biome/foliage.json": ItemPictureFixture.json([
                "temperature": 1, "downfall": 1,
                "effects": ["water_color": 0x654321, "foliage_color": 0xabcdef, "grass_color_modifier": "future_modifier"]]),
            "data/minecraft/tags/worldgen/biome/is_ocean.json": ItemPictureFixture.json(["values": ["test:ocean"]]),
            "data/minecraft/tags/worldgen/biome/is_river.json": ItemPictureFixture.json(["values": ["test:river"]]),
        ])
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try fixture.library()
        let colors = try await library.data.biomeColors(in: World(contentsOf: root), artwork: library)
        for (id, rgb) in BiomeColors.table { #expect(BiomeColors.color(for: id, game: colors) == MapColor(rgb)) }
        #expect(BiomeColors.color(for: "test:land", game: colors) == MapColor(0x123456))
        #expect(BiomeColors.color(for: "test:ocean", game: colors) == MapColor(0x654321))
        #expect(BiomeColors.color(for: "test:river", game: colors) == MapColor(0x654321))
        #expect(BiomeColors.color(for: "test:foliage", game: colors) == MapColor(0xabcdef))
        #expect(colors.outlineColor(for: "test:missing", at: .zero) == nil)
        #expect(BiomeColors.color(for: "test:missing", game: colors) == BiomeColors.color(for: "test:missing"))
        await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func packColorsRefreshAcrossTabsWithoutGameFilesAndRetireWithTheirSource() async throws {
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        try pack(at: root, grass: 0xff0000)
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        resources.refreshDelay = .zero
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        first.visibility.biomes.insert(.init(id: "test:land"))
        second.visibility.biomes.insert(.init(id: "test:land"))
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        func color(_ session: WorldSession) throws -> MapColor {
            let content = MapContent(session: session)
            return try #require(content.scene(viewport: .init(center: CGPoint(x: 8, y: 8), scale: 4),
                size: CGSize(width: 100, height: 100)).biomeAreas.first).color
        }
        #expect(try color(first) == MapColor(0xff0000) && color(second) == MapColor(0xff0000))
        #expect(first.map?.currentRenderer.biomeColors?.biome("test:land").color(.water, x: 0, z: 0) == 0x654321)
        let map = try #require(first.map)
        map.viewport = .init(center: CGPoint(x: 8, y: 8), scale: 4)
        map.requestTiles(visibleIn: CGSize(width: 100, height: 100), displayScale: 1)
        await map.waitForRenders()
        let terrain = try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes
        let noArt = try #require(resources.biomeColors)
        #expect(BiomeColors.color(for: "test:foliage", game: noArt) == MapColor(0xabcdef))
        #expect(BiomeColors.color(for: "test:climate", game: noArt) == MapColor(0x654321))

        try pack(at: root, grass: 0x00ff00)
        resources.worldChanged([root.appendingPathComponent("datapacks/outline")])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(try color(first) == MapColor(0x00ff00) && color(second) == MapColor(0x00ff00))
        await map.waitForRenders()
        #expect(try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes == terrain)

        let fixture = try ItemPictureFixture(extraFiles: [
            "data/minecraft/tags/worldgen/biome/is_ocean.json": ItemPictureFixture.json(["values": ["test:land"]]),
        ])
        defer { fixture.remove() }
        let game = try fixture.resources(), library = try #require(resources.names.minecraft.artwork(for: game))
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        resources.prepareGameAssets(source)
        resources.setGameAssets(game, source: source)
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(try color(first) == MapColor(0x654321) && color(second) == MapColor(0x654321))
        let terrainKey = try #require(first.map?.currentRenderer.biomeColors?.sourceKey)
        try write(ItemPictureFixture.json(["replace": true, "values": [String]()]),
                  to: root.appendingPathComponent("datapacks/outline/data/minecraft/tags/worldgen/biome/is_ocean.json"))
        resources.worldChanged([root.appendingPathComponent("datapacks/outline")])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(try color(first) == MapColor(0x00ff00))
        #expect(first.map?.currentRenderer.biomeColors?.sourceKey == terrainKey)

        resources.setGameAssets(nil, source: source)
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(try color(first) == MapColor(0x00ff00) && color(second) == MapColor(0x00ff00))
        #expect(first.map?.currentRenderer.biomeColors?.source.data == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("datapacks/outline"))
        resources.worldChanged([root.appendingPathComponent("datapacks/outline")])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(try color(first) == BiomeColors.color(for: "test:land"))
        resources.close(); await resources.waitUntilClosed()
        await library.close()
        #expect(resources.biomeColors == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func sharedOverlayDrawingUsesTheNewColorInBothAppearances(_ scheme: ColorScheme) async throws {
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        try pack(at: root, grass: 0xff0000)
        let colors = try MapBiomeColors.read(in: World(contentsOf: root), source: .init(data: "test", artwork: .unavailable), assets: nil)
        var content = MapContent()
        content.biomeAreas = BiomePresentation.areas(from: [.init(x: 0, z: 0): "test:land"])
        content.biomeColors = colors
        let viewport = MapViewport(center: CGPoint(x: 8, y: 8), scale: 4)
        let canvas = Canvas { context, size in
            MapView.drawOverlays(viewport: viewport, regions: [], content: content,
                                 portalStatus: { _ in nil }, in: context, size: size)
        }.frame(width: 100, height: 100).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: canvas); renderer.scale = 1
        let image = try #require(renderer.cgImage)
        Attachment.record(image, named: "game-biome-outline-\(scheme)", as: .png)
        let pixels = try ItemPictureFixture.pixels(image)
        #expect(pixels.color(50, 50) == [38, 0, 0, 38]) // Existing 15% area fill uses the game red.
    }

    private func world() throws -> URL {
        let section = Fixtures.section(y: 0, palette: [.string("minecraft:stone")], biomes: ["test:land"])
        return try TestWorld.make(chunks: [.init(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
            dataVersion: 5023, sections: [section], extra: ["yPos": .int(0)]))])
    }

    private func pack(at root: URL, grass: UInt32) throws {
        let folder = root.appendingPathComponent("datapacks/outline")
        try write(ItemPictureFixture.json(["pack": ["min_format": 121, "max_format": 121, "description": "Fixture"]]),
                  to: folder.appendingPathComponent("pack.mcmeta"))
        try write(definition(grass: grass, foliage: 0xabcdef, water: 0x654321),
                  to: folder.appendingPathComponent("data/test/worldgen/biome/land.json"))
        try write(definition(grass: nil, foliage: 0xabcdef, water: 0x654321),
                  to: folder.appendingPathComponent("data/test/worldgen/biome/foliage.json"))
        try write(definition(grass: nil, foliage: nil, water: 0x654321),
                  to: folder.appendingPathComponent("data/test/worldgen/biome/climate.json"))
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string("Outline Check"), "DataVersion": .int(9001),
            "DataPacks": .compound(["Enabled": .list([.string("vanilla"), .string(TestWorldResources.pack), .string("file/outline")])]),
        ])]), to: root.appendingPathComponent("level.dat"))
    }

    private func definition(grass: UInt32?, foliage: UInt32?, water: UInt32) throws -> Data {
        var effects: [String: Any] = ["water_color": water]
        effects["grass_color"] = grass; effects["foliage_color"] = foliage
        return try ItemPictureFixture.json(["temperature": 1, "downfall": 1, "effects": effects])
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
