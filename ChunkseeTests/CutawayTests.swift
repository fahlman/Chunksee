import AppKit
import ChunkseeKit
import CoreGraphics
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct CutawayTests {
    private final class Fixture {
        let url: URL
        let defaults: UserDefaults
        var maps: [MapModel] = []
        var resources: [WorldResources] = []
        let tiles = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        let blocks = AsyncReadGate<MapModel.TopBlockRead?>()

        init() throws {
            defaults = TestDefaults.make()
            url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
                palette: ["minecraft:air", "minecraft:grass_block", "minecraft:stone", "minecraft:bedrock"]) { _, y, _ in
                y == 15 ? 3 : y == 10 ? 2 : y <= 2 ? 1 : 0
            }])
        }

        func dimension() throws -> ChunkseeKit.Dimension { try #require(try World(contentsOf: url).dimension("overworld")) }

        func close() async {
            maps.forEach { $0.close() }
            resources.forEach { $0.close() }
            await tiles.finishAll(with: nil)
            await blocks.finishAll(with: nil)
            for map in maps { await map.waitForRenders() }
            for resource in resources { await resource.waitUntilClosed() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func columnsAndHoverStartAtOrBelowTheChosenHeight() async throws {
        try await withFixture { f in
            let file = try #require(try f.dimension().region(x: 0, z: 0))
            for (height, expected) in [(15, 15), (14, 10), (7, 2), (2, 2), (1, 1), (0, 0)] {
                let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0, cutawayY: height))
                let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, cutawayY: height))
                #expect(columns.count == 256 && columns.allSatisfy { $0?.y == expected })
                #expect(blocks.allSatisfy { $0?.y == expected })
            }
            let below = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0, cutawayY: -1))
            #expect(below.allSatisfy { $0 == nil })
            // Surface keeps its roof rule; cutaway must show the actual block at the requested Y.
            let surface = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, ceilingY: 127))
            let roofSlice = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, ceilingY: 127, cutawayY: 15))
            #expect(surface[0]?.y == 10 && roofSlice[0]?.y == 15)
        }
    }

    @Test func cachedHeightsAndSurfaceStayIndependentAcrossFileChanges() async throws {
        try await withFixture { f in
            let dimension = try f.dimension(), region = RegionCoordinate(x: 0, z: 0)
            let cache = TileCache(directory: f.url.appendingPathComponent("test-cache"))
            let file = dimension.regionDirectory.appendingPathComponent("r.0.0.mca")
            var keys: [TileCache.Key] = []
            var images: [Data] = []
            for height: Int? in [nil, 7, 14] {
                let renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false, cutawayY: height)
                let tile = try #require(try await renderer.tile(for: region))
                keys.append(try #require(TileCache.key(for: region, regionFile: file, cutawayY: height)))
                images.append(try #require(tile.full.dataProvider?.data as Data?))
            }
            #expect(Set(keys).count == 3 && Set(images).count == 3)
            #expect(cache.load(keys[0]) != nil && cache.load(keys[1]) == nil && cache.load(keys[2]) != nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count == 2)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
            _ = try await RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false, cutawayY: 14).tile(for: region)
            #expect(cache.load(keys[2]) == nil && cache.load(keys[0]) != nil)
        }
    }

    @Test func aLateSurfaceRenderCannotReplaceTheChosenCutaway() async throws {
        try await withFixture { f in
            let dimension = try f.dimension(), region = RegionCoordinate(x: 0, z: 0)
            let surface = try await RegionTileRenderer(dimension: dimension).tile(for: region)
            let cutaway = try await RegionTileRenderer(dimension: dimension, cutawayY: 7).tile(for: region)
            let gate = f.tiles
            let map = MapModel(dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, _ in
                guard !Task.isCancelled else { return nil }
                return await gate.read(renderer.cutawayY.map(String.init) ?? "surface")
            })
            f.maps.append(map)
            map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
            await gate.waitForRequest("surface")
            map.setDepth(MapDepth(y: 7, isSurface: false))
            await gate.waitForCancellation("surface")
            await gate.waitForRequest("7")
            await gate.finish("7", with: cutaway)
            await map.waitUntilIdle()
            let expected = try #require(cutaway?.full.dataProvider?.data as Data?)
            #expect(map.tiles[region]?.dataProvider?.data as Data? == expected)
            await gate.finish("surface", with: surface)
            await map.waitForRenders()
            #expect(map.tiles[region]?.dataProvider?.data as Data? == expected)
            map.close()
            map.setDepth(MapDepth(y: 1, isSurface: false))
            #expect(map.depth.cutawayY == 7)
        }
    }

    @Test func changingHeightCancelsPendingCopiesAndRereadsAStillPointer() async throws {
        try await withFixture { f in
            let dimension = try f.dimension(), gate = f.blocks
            let map = MapModel(dimension: dimension, center: .zero, readTopBlocks: { chunk, dimension, depth, cached in
                guard !Task.isCancelled else { return nil }
                if depth.isSurface { return await gate.read("surface") }
                return await MapModel.readTopBlocks(of: chunk, in: dimension, depth: depth, cached: cached)
            })
            f.maps.append(map)
            let point = CGPoint(x: 8, y: 8)
            map.loadTopBlocks(at: point)
            await gate.waitForRequest("surface")
            var oldCopyFinished = false
            map.readTopBlock(at: point) { _ in oldCopyFinished = true }
            await gate.waitForRequest("surface", count: 2)
            map.setDepth(MapDepth(y: 7, isSurface: false))
            await gate.waitForCancellation("surface")
            await gate.finishAll(with: nil)
            await map.waitForRenders()
            #expect(!oldCopyFinished && map.topBlock(at: point)?.y == 2)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            MapClipboard.copy(point, on: map, to: board)
            await map.waitForCoordinateReads()
            #expect(board.string(forType: .string) == "8 2 8")
            map.setDepth(MapDepth(y: 14, isSurface: false))
            await map.waitForTopBlocks()
            #expect(map.topBlock(at: point)?.y == 10)
        }
    }

    @Test func exportedTerrainFollowsTheCutawayAndSurface() async throws {
        try await withFixture { f in
            let map = MapModel(dimension: try f.dimension(), center: CGPoint(x: 8, y: 8))
            f.maps.append(map)
            let size = CGSize(width: 16, height: 16)
            map.requestTiles(visibleIn: size, displayScale: 1)
            await map.waitUntilIdle()
            let surface = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil }, size: size, scale: 1))
            map.setDepth(MapDepth(y: 7, isSurface: false))
            await map.waitUntilIdle()
            let cutaway = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil }, size: size, scale: 1))
            #expect(cutaway.data != surface.data)
            map.setDepth(MapDepth(y: 7, isSurface: true))
            await map.waitUntilIdle()
            let restored = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil }, size: size, scale: 1))
            #expect(restored.data == surface.data && map.depth.y == 7)
        }
    }

    @Test func sessionsRestoreTheirOwnHeightAndSurfaceState() async throws {
        try await withFixture { f in
            try FileManager.default.createDirectory(at: f.url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
            let resources = WorldResources(snapshot: try await WorldSnapshot.read(f.url), names: PlayerNames(defaults: f.defaults),
                savedSearches: SavedSearches(defaults: f.defaults), defaults: f.defaults, cacheRoot: nil)
            f.resources.append(resources)
            let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
            let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
            overworld.map?.setDepth(MapDepth(y: -20, isSurface: false))
            nether.map?.setDepth(MapDepth(y: 31, isSurface: true))
            overworld.close()
            await overworld.waitUntilClosed()
            let reopened = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
            #expect(reopened.map?.depth == MapDepth(y: -20, isSurface: false))
            #expect(nether.map?.depth == MapDepth(y: 31, isSurface: true))
            reopened.restoreView(from: nether)
            #expect(reopened.map?.depth.cutawayY == -20)
            nether.close()
            await nether.waitUntilClosed()
            let again = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
            #expect(again.map?.depth == MapDepth(y: 31, isSurface: true))
            let reread = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
            reread.restoreView(from: reopened)
            #expect(reread.map?.depth == reopened.map?.depth)
        }
    }

    @Test func movedViewsMergeDimensionHeightsAndOlderPreferencesDefaultToSurface() {
        let old = URL(fileURLWithPath: "/Cutaway Old"), new = URL(fileURLWithPath: "/Cutaway New")
        let defaults = TestDefaults.make()

        let source = RememberedViews(world: old, defaults: defaults), target = RememberedViews(world: new, defaults: defaults)
        #expect(source.depth(for: "minecraft:overworld") == MapDepth())
        source.save(MapViewport(center: .zero, scale: 1), for: "minecraft:overworld", selected: nil)
        #expect(source.depth(for: "minecraft:overworld") == MapDepth())
        source.save(MapViewport(center: .zero, scale: 1), for: "minecraft:overworld", selected: nil, depth: MapDepth(y: -23, isSurface: false))
        target.save(MapViewport(center: .zero, scale: 1), for: "minecraft:the_nether", selected: nil, depth: MapDepth(y: 40, isSurface: true))
        source.relocate(to: new)
        #expect(target.depth(for: "minecraft:overworld") == MapDepth(y: -23, isSurface: false))
        #expect(target.depth(for: "minecraft:the_nether") == MapDepth(y: 40, isSurface: true))
        #expect(source.depth(for: "minecraft:overworld") == MapDepth())
        #expect(MapDepth(y: 900, isSurface: false).sliderRange.contains(900))
        #expect(MapDepth(y: -900, isSurface: false).sliderRange.contains(-900))
    }
}
