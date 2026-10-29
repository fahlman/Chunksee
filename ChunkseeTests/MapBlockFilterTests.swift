import AppKit
import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapBlockFilterTests {
    private let leaves = "minecraft:oak_leaves"
    private var hiddenLeaves: MapBlockFilter { MapBlockFilter(hiddenIDs: [leaves]) }

    @Test func choicesStayDisjointAndDisabledChoicesKeepTheirIdentity() {
        let first = MapBlockFilter(hiddenIDs: ["oak_leaves", "stone", "bad id"], highlightedIDs: ["stone", "dirt"])
        let reordered = MapBlockFilter(hiddenIDs: ["minecraft:stone", leaves], highlightedIDs: ["minecraft:dirt"])
        #expect(first == reordered && first.cacheKey != nil)
        #expect(first.choice(for: "minecraft:stone") == .hide)
        #expect(first.choosing(.highlight, for: ["stone"]).choice(for: "minecraft:stone") == .highlight)
        #expect(first.choosing(.show, for: ["stone"]).choice(for: "minecraft:stone") == .show)
        let disabled = first.enabled(false)
        #expect(disabled.hiddenIDs == first.hiddenIDs && disabled.highlightedIDs == first.highlightedIDs)
        #expect(disabled.cacheKey == nil && disabled.effectiveHiddenIDs.isEmpty)
        #expect(disabled.enabled(true) == first)
        #expect(first.cacheKey != MapBlockFilter(highlightedIDs: first.hiddenIDs).cacheKey)
    }

    @Test func theLeafShortcutUsesGameMembershipAndOnlySavedNames() throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/block/leaves.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"replace":true,"values":["minecraft:oak_leaves","example:needles","example:retired_needles","minecraft:cherry_leaves",{"id":"example:absent","required":false}]}"#.utf8).write(to: file)
        let before = MapBlockFilter(hiddenIDs: ["minecraft:stone"], highlightedIDs: [leaves, "example:leafy_rock"])
        let catalog: Set<String> = [leaves, "example:needles", "example:fake_leaves", "example:leafy_rock", "minecraft:stone"]
        let definitions = try WorldDefinitions.read(World(contentsOf: root), assets: nil)
        let selected = try #require(MapBlockFilter.leafIDs(in: catalog, tag: definitions.leafTag))
        #expect(selected == [leaves, "example:needles"])
        #expect(MapBlockFilter.leafIDs(in: catalog.union(["example:retired_needles"]), tag: definitions.leafTag)
                == selected.union(["example:retired_needles"]))
        let hidden = before.choosing(.hide, for: selected)
        #expect(hidden.hiddenIDs == selected.union(["minecraft:stone"]))
        #expect(hidden.highlightedIDs == ["example:leafy_rock"])
        #expect(hidden.choosing(.show, for: selected).hiddenIDs == ["minecraft:stone"])
    }

    @Test func unavailableAndEmptyLeafTagsNeverGuessFromNames() throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try World(contentsOf: root), catalog: Set<String> = [leaves, "example:blue_leaves"]
        #expect(MapBlockFilter.leafIDs(in: catalog, tag: try WorldDefinitions.read(world, assets: nil).leafTag) == nil)
        let file = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/block/leaves.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"replace":true,"values":[]}"#.utf8).write(to: file)
        #expect(MapBlockFilter.leafIDs(in: catalog, tag: try WorldDefinitions.read(world, assets: nil).leafTag) == [])
        try Data("damaged tag".utf8).write(to: file)
        #expect(MapBlockFilter.leafIDs(in: catalog, tag: try WorldDefinitions.read(world, assets: nil).leafTag) == nil)
    }

    @Test func hidingCanopyAndWaterRevealsTheSameBlocksForDrawingAndReading() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let all = MapBlockFilter(hiddenIDs: [leaves, "minecraft:water"])
        for height: Int? in [nil, 15, 10] {
            let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0, cutawayY: height, blockFilter: all))
            let named = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, cutawayY: height, blockFilter: all))
            #expect(columns[0]?.y == 2 && named[0]?.y == 2 && named[0]?.id == "minecraft:grass_block")
            #expect(columns[8]?.y == 3 && named[8]?.y == 3 && named[8]?.id == "minecraft:stone" && named[8]?.waterDepth == 0)
        }
        let original = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(original[0]?.id == leaves && original[0]?.y == 15)
        let restored = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, blockFilter: all.enabled(false)))
        #expect(restored == original)
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension, blockFilter: all).pixels(for: .init(x: 0, z: 0)))
        let grass = try #require(BlockColors.color(for: "minecraft:grass_block"))
        #expect(Array(pixels[0..<4]) == [grass.red, grass.green, grass.blue, 255])
        #expect(Array(pixels[16 * 4..<17 * 4]) == [0, 0, 0, 0])
    }

    @Test func highlightUsesTheSelectedSurfaceInEveryMapStyle() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let scale = try #require(MapHeightScale(settings: WorldDetails.read(world).dimensionSettings[dimension.id]))
        let filter = MapBlockFilter(hiddenIDs: [leaves], highlightedIDs: ["minecraft:grass_block"])
        let accent = MapBlockFilter.Emphasis.accent, region = RegionPosition(x: 0, z: 0)
        for style in MapStyle.allCases {
            let actual = try #require(try await RegionTileRenderer(dimension: dimension, style: style,
                heightScale: scale, blockFilter: filter).pixels(for: region))
            // Highlight changes the surface colour; ordinary land relief still uses its height.
            let highlighted = style == .height ? accent : accent.shaded(
                MapRelief(heightScale: scale).factor(height: 2, north: 0, west: 0))
            #expect(Array(actual[0..<4]) == [highlighted.red, highlighted.green, highlighted.blue, 255])
            let plain = try #require(try await RegionTileRenderer(dimension: dimension, style: style, heightScale: scale).pixels(for: region))
            // Flat rows have no relief difference, so only the filter dims this unselected water.
            for channel in 0..<3 { #expect(actual[8 * 4 + channel] == UInt8((Double(plain[8 * 4 + channel]) * 0.25).rounded())) }
        }
    }

    @Test func unfilteredTilesSurviveFilteredVariantsAndOnlyTheLatestVariantIsKept() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let cache = TileCache(directory: url.appendingPathComponent("tiles")), region = RegionPosition(x: 0, z: 0)
        let normal = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        let original = try #require(try await normal.tile(for: region))
        let first = try #require(try await RegionTileRenderer(dimension: dimension, cache: cache,
            savesInBackground: false, blockFilter: hiddenLeaves).tile(for: region))
        #expect(first.full.image.dataProvider?.data as Data? != original.full.image.dataProvider?.data as Data?)
        let secondFilter = MapBlockFilter(highlightedIDs: ["minecraft:water"])
        _ = try await RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false, blockFilter: secondFilter).tile(for: region)
        let firstKey = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(at: region), blockFilter: hiddenLeaves))
        #expect(cache.load(firstKey) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count == 2)
        let restored = try #require(try await RegionTileRenderer(dimension: dimension, cache: cache,
            blockFilter: secondFilter.enabled(false)).tile(for: region))
        #expect(restored.cacheWrite == nil && restored.full.image.dataProvider?.data as Data? == original.full.image.dataProvider?.data as Data?)
    }

    @Test(.timeLimit(.minutes(1))) func applyingChoicesRejectsLateTilesAndCoordinatesAndRereadsHover() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let before = try await RegionTileRenderer(dimension: dimension).tile(for: .init(x: 0, z: 0))
        let after = try await RegionTileRenderer(dimension: dimension, blockFilter: hiddenLeaves).tile(for: .init(x: 0, z: 0))
        let oldBlocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        let tiles = AsyncReadGate<RegionTileRenderer.RenderedTile?>(), blocks = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, _ in
            await tiles.read(renderer.blockFilter.cacheKey == nil ? "before" : "after")
        }, readTopBlocks: { chunk, renderer, cached in
            if renderer.blockFilter.cacheKey == nil { return await blocks.read(String(chunk.x)) }
            return await MapModel.readTopBlocks(of: chunk, using: renderer, cached: cached)
        })
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        map.loadTopBlocks(at: CGPoint(x: 1, y: 1))
        var copiedOld = false
        map.readTopBlock(at: CGPoint(x: 17, y: 1)) { _ in copiedOld = true }
        await tiles.waitForRequest("before")
        await blocks.waitForRequest("0")
        await blocks.waitForRequest("1")
        map.setBlockFilter(hiddenLeaves)
        await tiles.waitForCancellation("before")
        await blocks.waitForCancellation("0")
        await blocks.waitForCancellation("1")
        await tiles.waitForRequest("after")
        await tiles.finish("after", with: after)
        await map.waitUntilIdle()
        await tiles.finish("before", with: before)
        await blocks.finishAll(with: (file, oldBlocks))
        await map.waitForRenders()
        #expect(!copiedOld)
        #expect(map.topBlock(at: CGPoint(x: 1, y: 1))?.y == 2)
        #expect(map.tiles[.init(x: 0, z: 0)]?.picture === after?.full)
        map.close()
        map.setBlockFilter(MapBlockFilter())
        #expect(map.blockFilter == hiddenLeaves)
    }

    @Test(.timeLimit(.minutes(1))) func changingOnlyHighlightsPreservesPendingBlockReads() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let named = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, blockFilter: hiddenLeaves))
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero,
            readTopBlocks: { chunk, _, _ in await gate.read(String(chunk.x)) })
        map.setBlockFilter(hiddenLeaves)
        map.loadTopBlocks(at: CGPoint(x: 1, y: 1))
        var copiedY: Int?
        map.readTopBlock(at: CGPoint(x: 17, y: 1)) { copiedY = $0?.y }
        await gate.waitForRequest("0")
        await gate.waitForRequest("1")
        map.setBlockFilter(hiddenLeaves.choosing(.highlight, for: ["minecraft:grass_block"]))
        await gate.finishAll(with: (file, named))
        await map.waitForRenders()
        #expect(copiedY == 2 && map.topBlock(at: CGPoint(x: 1, y: 1))?.y == 2)
        map.close()
    }

    @Test func copyingAnUncachedFilteredBlockUsesItsRevealedHeight() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero)
        defer { map.close() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        map.setBlockFilter(hiddenLeaves)
        MapClipboard.copy(CGPoint(x: 1.7, y: 1.3), y: nil, on: map, to: board)
        await map.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "1 2 1")
        map.setBlockFilter(hiddenLeaves.enabled(false))
        MapClipboard.copy(CGPoint(x: 1.7, y: 1.3), y: nil, on: map, to: board)
        await map.waitForCoordinateReads()
        #expect(board.string(forType: .string) == "1 15 1")
    }

    @Test func savedChoicesAndThePaletteCatalogBelongToTheirDimension() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let first = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let second = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        await first.search.waitForIndex()
        #expect(first.presentation.selectedIndex.shared?.paletteBlockIDs.contains("example:unused_name") == true)
        #expect(second.presentation.selectedIndex.shared?.paletteBlockIDs.isEmpty != false)
        first.map?.setBlockFilter(hiddenLeaves)
        let other = MapBlockFilter(isEnabled: false, highlightedIDs: ["minecraft:lava"])
        second.map?.setBlockFilter(other)
        first.saveView()
        second.saveView()
        let restored = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let restoredNether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(restored.map?.blockFilter == hiddenLeaves && restoredNether.map?.blockFilter == other)
        first.map?.setBlockFilter(hiddenLeaves.enabled(false))
        restored.restoreView(from: first)
        #expect(restored.map?.blockFilter == hiddenLeaves.enabled(false) && second.map?.blockFilter == other)
        [first, second, restored, restoredNether].forEach { $0.close() }
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func filteredExportAndCurrentViewHaveTheSamePixelsAndLegendInBothAppearances() async throws {
        let url = try terrain()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero)
        defer { map.close() }
        let filter = MapBlockFilter(hiddenIDs: [leaves], highlightedIDs: ["minecraft:grass_block"])
        map.setBlockFilter(filter)
        let plan = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 300, height: 200), blocksPerPixel: 1)
        map.viewport = plan.viewport
        map.requestTiles(visibleIn: plan.size, displayScale: 1)
        await map.waitUntilIdle()
        var content = MapContent()
        content.blockFilter = filter
        for appearance in [ColorScheme.light, .dark] {
            let actual = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: map.currentRenderer,
                content: content, portalStatus: { _ in nil }, colorScheme: appearance, locale: Locale(identifier: "en_US"),
                progress: { _, _ in })
            let expected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: plan.size,
                scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
            #expect(try pixels(actual) == pixels(expected))
        }
        await map.waitForRenders()
    }

    private func pixels(_ image: MapImage) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(decoded.dataProvider?.data as Data?)
    }

    private func terrain() throws -> URL {
        try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["minecraft:air", leaves, "minecraft:grass_block", "minecraft:water", "minecraft:stone", "example:unused_name"]) { x, y, _ in
            if x < 8 { return y == 15 ? 1 : y <= 2 ? 2 : 0 }
            return y >= 4 ? 3 : 4
        }], dimensionSettings: ["minecraft:overworld":
            TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld"))])
    }
}
