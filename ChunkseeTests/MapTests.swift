import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapGridTests {
    let size = CGSize(width: 800, height: 600)

    @Test func chunkLinesWhenTheyreFarEnoughApart() {
        // At 1 point per block, chunks are 16 points apart: lines, but too close to label.
        let grid = MapGrid(viewport: MapViewport(center: .zero, scale: 1), size: size)
        #expect(grid.vertical.count == 51)                       // X -400 through 400, every 16 blocks
        #expect(grid.vertical.first?.block == -400 && grid.vertical.last?.block == 400)
        let origin = grid.vertical.first { $0.block == 0 }
        #expect(origin?.position == 400 && origin?.isRegionEdge == true)
        #expect(!grid.labelsChunks && grid.labelsRegions)
        #expect(grid.horizontal.first?.block == -288)            // Z -300 rounds up to the next chunk edge
    }

    @Test func onlyRegionLinesWhenZoomedOutAndChunkLabelsWhenZoomedIn() {
        let far = MapGrid(viewport: MapViewport(center: .zero, scale: 0.25), size: size)
        #expect(far.vertical.map(\.block) == [-1536, -1024, -512, 0, 512, 1024, 1536])
        #expect(far.vertical.allSatisfy(\.isRegionEdge) && far.labelsRegions && !far.labelsChunks)
        let near = MapGrid(viewport: MapViewport(center: CGPoint(x: 8, y: 8), scale: 4), size: size)
        #expect(near.labelsChunks)
        #expect(near.vertical.map(\.block) == [-80, -64, -48, -32, -16, 0, 16, 32, 48, 64, 80, 96])
    }

    @Test func blockLinesFromEightTimesZoomWithOnlyChunkAndRegionEdgesLabeled() {
        // At 8 points per block, every block gets a line; chunk and region edges are marked.
        let grid = MapGrid(viewport: MapViewport(center: CGPoint(x: 8, y: 8), scale: 8), size: size)
        #expect(grid.vertical.map(\.block) == Array(-42...58))   // X -42 through 58 across 800 points
        #expect(grid.vertical.filter(\.isChunkEdge).map(\.block) == [-32, -16, 0, 16, 32, 48])
        #expect(grid.vertical.first { $0.block == 0 }?.isRegionEdge == true)
        #expect(grid.vertical.filter { grid.isLabeled($0) }.map(\.block) == [-32, -16, 0, 16, 32, 48])
        // Just below 8×, only chunk lines.
        let chunks = MapGrid(viewport: MapViewport(center: CGPoint(x: 8, y: 8), scale: 7.9), size: size)
        #expect(chunks.vertical.allSatisfy { $0.isChunkEdge })
    }

    @Test func theGridSettingIsRemembered() {
        let defaults = TestDefaults.make()
        let worldID = UUID()
        #expect(!LayerVisibility(settings: WorldSettings(id: worldID, defaults: defaults), dimension: "minecraft:overworld").showsGrid)
        LayerVisibility(settings: WorldSettings(id: worldID, defaults: defaults), dimension: "minecraft:overworld").showsGrid = true
        #expect(LayerVisibility(settings: WorldSettings(id: worldID, defaults: defaults), dimension: "minecraft:overworld").showsGrid)
    }
}

@Suite(.isolatedStores) struct MapAccessibilityTests {
    @Test func visiblePlayerDeathRespawnAndSearchLocationsKeepTheirNamesAndCoordinates() throws {
        let playerID = UUID()
        var content = MapContent()
        content.players = [
            .init(id: "friend-player", playerID: playerID, kind: .player, position: .zero, label: "Friend", isOutdated: false),
            .init(id: "friend-death", playerID: playerID, kind: .death, position: CGPoint(x: 10, y: 20), y: 64, label: "Where Friend last died", isOutdated: false),
            .init(id: "friend-respawn", playerID: playerID, kind: .respawn, position: CGPoint(x: -10, y: -20), label: "Friend’s respawn point", isOutdated: false),
            .init(id: "outside", playerID: playerID, kind: .player, position: CGPoint(x: 1000, y: 1000), label: "Outside", isOutdated: false)
        ]
        content.hits = [.init(id: "chest", source: .container(kind: "minecraft:chest"), dimension: "minecraft:overworld",
                             position: CGPoint(x: 5, y: 6), y: 64, title: "Chest", detail: "3 Diamond", count: 3)]
        let locations = content.accessibleLocations(viewport: .init(center: .zero, scale: 1), size: .init(width: 400, height: 300))
        #expect(Set(locations.map(\.name)) == ["Friend", "Where Friend last died", "Friend’s respawn point", "Chest, 3 Diamond"])
        let death = try #require(locations.first { $0.name == "Where Friend last died" })
        #expect(death.position == CGPoint(x: 10, y: 20) && death.y == 64)
        #expect(death.anchor == CGPoint(x: 10.5, y: 20.5))
        #expect(Set(locations.map(\.id)).count == locations.count)
    }
}

@Suite(.isolatedStores) struct MapViewportTests {
    let size = CGSize(width: 800, height: 600)

    @Test func centerOfViewIsViewportCenter() {
        let viewport = MapViewport(center: CGPoint(x: 100, y: -50), scale: 2)
        #expect(viewport.blockPoint(at: CGPoint(x: 400, y: 300), in: size) == CGPoint(x: 100, y: -50))
        #expect(viewport.blockPoint(at: CGPoint(x: 0, y: 0), in: size) == CGPoint(x: -100, y: -200))
    }

    @Test func regionRectsLineUpWithBlockCoordinates() {
        let viewport = MapViewport(center: .zero, scale: 1)
        #expect(viewport.viewRect(for: RegionPosition(x: 0, z: 0), in: size) == CGRect(x: 400, y: 300, width: 512, height: 512))
        #expect(viewport.viewRect(for: RegionPosition(x: -1, z: -1), in: size) == CGRect(x: -112, y: -212, width: 512, height: 512))
    }

    @Test func pointsAndAreasStayAlignedAcrossZoomLevels() throws {
        let center = CGPoint(x: -513.25, y: 768.5)
        let block = CGPoint(x: center.x + 128, y: center.y - 64)
        let scales: [CGFloat] = [MapViewport.scaleRange.lowerBound, 1.0 / 16, 1.25, 32]
        for scale in scales {
            let viewport = MapViewport(center: center, scale: scale)
            let transform = viewport.transform(in: size)
            let expected = CGPoint(x: 400 + 128 * scale, y: 300 - 64 * scale)
            for point in [block.applying(transform), viewport.viewPoint(for: block, in: size)] {
                #expect(abs(point.x - expected.x) < 0.00000001)
                #expect(abs(point.y - expected.y) < 0.00000001)
                let restored = viewport.blockPoint(at: point, in: size)
                #expect(abs(restored.x - block.x) < 0.00001)
                #expect(abs(restored.y - block.y) < 0.00001)
            }
            let area = CGRect(x: -1024, y: 512, width: 512, height: 512).applying(transform)
            let tile = try #require(viewport.viewRect(for: RegionPosition(x: -2, z: 1), in: size))
            #expect(tile == area)
            #expect(abs(tile.width - 512 * scale) < 0.00000001)
            #expect(abs(tile.height - 512 * scale) < 0.00000001)
            #expect(viewport.viewPoint(for: CGPoint(x: -1024, y: 512), in: size) == tile.origin)
        }
    }

    @Test func visibleRegionsAreNearestFirst() {
        let viewport = MapViewport(center: CGPoint(x: 256, y: 256), scale: 1)
        let available = Set((-1...1).flatMap { x in (-1...1).map { RegionPosition(x: x, z: $0) } })
        let regions = viewport.visibleRegions(in: size, among: available.union([RegionPosition(x: 9, z: 9)]))
        #expect(regions.first == RegionPosition(x: 0, z: 0))
        // The view spans blocks x -144…656 and z -44…556, which touches regions -1…1 on both axes.
        #expect(Set(regions) == available)
        #expect(regions.count == 9)
    }

    @Test func zoomKeepsAnchorFixedAndClamps() {
        var viewport = MapViewport(center: .zero, scale: 1)
        let anchor = CGPoint(x: 600, y: 100)
        let before = viewport.blockPoint(at: anchor, in: size)
        viewport.zoom(by: 4, anchor: anchor, in: size)
        #expect(viewport.scale == 4 && viewport.canZoomIn)
        #expect(viewport.blockPoint(at: anchor, in: size) == before)
        viewport.zoom(by: 1000, anchor: anchor, in: size)
        #expect(viewport.scale == MapViewport.scaleRange.upperBound && viewport.scale == 32)   // 3,200%
        #expect(!viewport.canZoomIn)
        viewport.zoom(by: 0.5)
        #expect(viewport.scale == 16 && viewport.canZoomIn)
    }

    @Test func dragMovesContentWithPointer() {
        var viewport = MapViewport(center: .zero, scale: 2)
        viewport.pan(by: CGSize(width: 20, height: -10))
        #expect(viewport.center == CGPoint(x: -10, y: 5))
    }

    @Test func directionalCommandsUseTheCorrespondingViewAxisAtEveryZoom() {
        for size in [CGSize(width: 1000, height: 600), CGSize(width: 600, height: 1000)] {
            for scale in [CGFloat(0.125), 1, 8] {
                let original = MapViewport(center: CGPoint(x: -100, y: 200), scale: scale)
                var viewport = original
                viewport.pan(.north, in: size)
                #expect(viewport.center == CGPoint(x: -100, y: 200 - size.height / (4 * scale)))
                viewport.pan(.south, in: size)
                #expect(viewport == original)
                viewport.pan(.west, in: size)
                #expect(viewport.center == CGPoint(x: -100 - size.width / (4 * scale), y: 200))
                viewport.pan(.east, in: size)
                #expect(viewport == original)
            }
        }
    }

    @Test func manualZoomIsBoundedWhileDistantTerrainCanStillFit() throws {
        var viewport = MapViewport()
        viewport.zoom(by: 0.000001)
        #expect(viewport.scale == 1.0 / 16 && !viewport.canZoomOut)
        let atLimit = viewport
        viewport.zoom(by: 0.5, anchor: CGPoint(x: 600, y: 100), in: size)
        #expect(viewport == atLimit)

        let regions: Set<RegionPosition> = [.init(x: -50_000, z: -50_000), .init(x: 50_000, z: 50_000)]
        var fitted = try #require(MapViewport.fitting(regions, in: size))
        let original = fitted
        #expect(fitted.scale < 1.0 / 16 && !fitted.canZoomOut && fitted.canZoomIn)
        fitted.zoom(by: 0.5, anchor: CGPoint(x: 600, y: 100), in: size)
        #expect(fitted == original)
        fitted.zoom(by: 2)
        #expect(fitted.scale == original.scale * 2 && fitted.center == original.center)
    }
}

@Suite(.isolatedStores) struct BlockColorsTests {
    @Test func airIsTransparent() {
        #expect(BlockColors.color(for: "minecraft:air") == nil)
        #expect(BlockColors.color(for: "minecraft:cave_air") == nil)
    }

    @Test func knownAndFamilyColors() {
        #expect(BlockColors.color(for: "minecraft:grass_block") == MapColor(0x7CBD6B))
        #expect(BlockColors.color(for: "minecraft:spruce_leaves") == BlockColors.color(for: "minecraft:oak_leaves"))
        #expect(BlockColors.color(for: "minecraft:light_gray_wool") != BlockColors.color(for: "minecraft:gray_wool"))
    }

    @Test func unknownBlocksGetAStableColor() {
        let first = BlockColors.color(for: "mymod:strange_block")
        #expect(first != nil)
        #expect(first == BlockColors.color(for: "mymod:strange_block"))
    }
}

@Suite(.isolatedStores) struct RegionTileRendererTests {
    @Test func rendersSurfaceWaterGapsAndRelief() async throws {
        let world = try TestWorld.make(chunks: [
            // Chunk (0, 0): stone floor at y 0; grass at y 1 for x < 8, water at y 1 for x ≥ 8.
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:grass_block", "minecraft:water"]) { x, y, _ in
                y == 0 ? 1 : y == 1 ? (x < 8 ? 2 : 3) : 0
            },
            // Chunk (0, 1): solid stone up to y 2, one block higher than chunk (0, 0)'s grass.
            TestWorld.chunk(x: 0, z: 1, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= 2 ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }

        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionPosition(x: 0, z: 0)))

        func pixel(_ x: Int, _ z: Int) -> [UInt8] { Array(pixels[((z * 512) + x) * 4 ..< ((z * 512) + x) * 4 + 4]) }
        func rgba(_ c: MapColor) -> [UInt8] { [c.red, c.green, c.blue, 255] }

        #expect(pixel(2, 5) == rgba(MapColor(0x7CBD6B)))                    // grass, level with its north neighbor
        #expect(pixel(10, 5) == rgba(MapColor(0x707F9E)))     // one block of water over stone
        #expect(pixel(20, 5)[3] == 0)                                        // chunk (1, 0) not generated
        #expect(pixel(2, 16) == rgba(MapColor(0x7D7D7D).shaded(1.025)))     // one block higher than the chunk to its north
        #expect(pixel(2, 17) == rgba(MapColor(0x7D7D7D)))                    // level with its north neighbor
        #expect(RegionTileRenderer.makeImage(pixels)?.width == 512)
    }

    @Test func parallelChunksMatchSequential() async throws {
        let world = try TestWorld.make(chunks: (0..<4).flatMap { x in (0..<4).map { z in
            TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone", "minecraft:grass_block", "minecraft:water"]) { bx, y, bz in
                y < (bx + bz + x * 3 + z) % 9 ? 1 : y == (bx + bz + x * 3 + z) % 9 ? (bx % 3 == 0 ? 3 : 2) : 0
            }
        } })
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let sequential = try await RegionTileRenderer(dimension: dimension, chunkConcurrency: 1).pixels(for: region)
        let parallel = try await RegionTileRenderer(dimension: dimension, chunkConcurrency: 8).pixels(for: region)
        #expect(sequential != nil)
        #expect(parallel == sequential)
    }

    @Test func topRowOfARegionIsShadedLikeTheRest() async throws {
        // A slope rising to the south: every row is one block higher than the row to its north.
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, z in y <= z ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionPosition(x: 0, z: 0)))
        func rgb(_ x: Int, _ z: Int) -> [UInt8] { Array(pixels[(z * 512 + x) * 4 ..< (z * 512 + x) * 4 + 3]) }
        let lit = MapColor(0x7D7D7D).shaded(1.025)
        #expect(rgb(3, 5) == [lit.red, lit.green, lit.blue])
        #expect(rgb(3, 0) == rgb(3, 5))  // the region's top row matches its neighbors
    }

    @Test func ceilingDimensionsShowTheFloorUnderTheRoof() throws {
        // Netherrack floor at y 0–4, open air at 5–11, bedrock roof at 12–15.
        let spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:netherrack", "minecraft:bedrock"]) { _, y, _ in
            y <= 4 ? 1 : y >= 12 ? 2 : 0
        }
        let chunk = try Chunk(nbt: spec.nbt)
        var open = RegionTileRenderer.ColorSections(chunk)
        let top = open.topColumns(from: .height(15))
        #expect(top[0]?.y == 15)  // without a ceiling, the roof is the top block
        var underRoof = RegionTileRenderer.ColorSections(chunk)
        let floor = underRoof.topColumns(from: .height(15), underCeiling: true)
        #expect(floor[0]?.y == 4)
        #expect(floor[0]?.color == BlockColors.color(for: "minecraft:netherrack"))

        // A column that is solid all the way down shows its first block under the roof, darkened.
        let solid = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:netherrack"]) { _, _, _ in 0 }
        var solidSections = RegionTileRenderer.ColorSections(try Chunk(nbt: solid.nbt))
        let rock = solidSections.topColumns(from: .height(15), underCeiling: true)
        #expect(rock[0]?.y == 10)  // below the five-block roof band
        #expect(rock[0]?.color == BlockColors.color(for: "minecraft:netherrack")?.shaded(0.6))
    }

    @Test func missingRegionFileRendersNothing() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        #expect(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionPosition(x: 3, z: 3)) == nil)
    }
}

@Suite(.isolatedStores) struct MapModelTests {
    @Test func loadsEveryVisibleRegionThatExists() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, regionConcurrency: 2, chunkConcurrency: 2)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        #expect(map.isLoading)
        await map.waitUntilIdle()
        #expect(!map.isLoading)
        // Four regions are visible around the origin, but only r.0.0 exists.
        #expect(Array(map.tiles.keys) == [RegionPosition(x: 0, z: 0)])
    }
}

@Suite(.isolatedStores) struct LevelOfDetailTests {
    func stoneWorld(regions: [RegionPosition]) throws -> URL {
        try TestWorld.make(chunks: regions.map { r in
            TestWorld.chunk(x: r.x * 32, z: r.z * 32, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        })
    }

    @Test func exportedImageMatchesTheViewAtItsPixelDensity() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        // The one chunk fills blocks 0–15; centered on it at 1×, it covers the view's middle.
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), regionConcurrency: 1, chunkConcurrency: 1)
        let size = CGSize(width: 200, height: 100)
        map.requestTiles(visibleIn: size, displayScale: 2)
        await map.waitUntilIdle()
        let image = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil }, size: size, scale: 2, colorScheme: .light, locale: Locale(identifier: "en_US")))
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 400 && decoded.height == 200)
        // Read the alpha of the middle pixel (terrain) and a corner (no terrain).
        func alpha(x: Int, y: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(decoded, in: CGRect(x: -x, y: y - decoded.height + 1, width: decoded.width, height: decoded.height))
            return pixel[3]
        }
        #expect(alpha(x: 200, y: 100) == 255)
        #expect(alpha(x: 2, y: 2) == 0)
    }

    @Test func exportedHeatMapIncludesItsColorScaleInBothAppearances() async throws {
        let world = try stoneWorld(regions: [RegionPosition(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), regionConcurrency: 1, chunkConcurrency: 1)
        let size = CGSize(width: 480, height: 320)
        map.requestTiles(visibleIn: size, displayScale: 1)
        await map.waitUntilIdle()
        for appearance in [ColorScheme.light, .dark] {
            for shown in [false, true] {
                var content = MapContent()
                content.showsHeatMap = shown
                let image = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil },
                    size: size, scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                Attachment.record(Array(image.data), named: "time-spent-\(appearance)-\(shown).png")
                let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
                let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                var pixels = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
                let rendered = pixels.withUnsafeMutableBytes { bytes in
                    guard let context = CGContext(data: bytes.baseAddress, width: decoded.width, height: decoded.height,
                        bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
                    return true
                }
                #expect(rendered)
                var red = false, blue = false
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    red = red || (r > 150 && r > g * 2 && b < 100)
                    blue = blue || (b > 150 && b > r * 2 && g < 150)
                }
                // Stone terrain is gray. Only the shared legend can supply either end of this scale,
                // including when the enabled layer has no inhabited chunks to color.
                #expect(red == shown && blue == shown)
            }
        }
    }

    @Test func fullResolutionOnlyWhenRegionsAreLargeOnScreen() throws {
        let world = try stoneWorld(regions: [RegionPosition(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(work: BackgroundWork(), dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero)
        map.viewport.scale = 0.25   // a region is 128 points: 256 pixels at 2×, the preview's size
        #expect(!map.needsFullResolution(displayScale: 2))
        map.viewport.scale = 0.5
        #expect(map.needsFullResolution(displayScale: 2))
        #expect(!map.needsFullResolution(displayScale: 1))
    }

    @Test func visibleTilesSurviveASmallCacheAndPreviewsArePrepared() async throws {
        let regions = [RegionPosition(x: -1, z: -1), RegionPosition(x: 0, z: -1), RegionPosition(x: -1, z: 0), RegionPosition(x: 0, z: 0)]
        let world = try stoneWorld(regions: regions)
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(work: BackgroundWork(), dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero,
                           maxTiles: 1, maxPreviews: 1)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        await map.waitUntilIdle()
        // All four regions are visible, so none is evicted despite the limit of one.
        #expect(Set(map.tiles.keys) == Set(regions))
        #expect(Set(map.previews.keys) == Set(regions))
        #expect(map.previews[RegionPosition(x: 0, z: 0)]?.width == RegionTileRenderer.previewSide)
    }

    @Test func zoomedOutRequestsNeedOnlyPreviews() async throws {
        let world = try stoneWorld(regions: [RegionPosition(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(work: BackgroundWork(), dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero)
        map.viewport.scale = 1.0 / 16
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        await map.waitUntilIdle()
        #expect(map.image(for: RegionPosition(x: 0, z: 0), fullResolution: false)?.width == RegionTileRenderer.previewSide)
        #expect(map.tiles.isEmpty)  // full tiles aren't kept when only previews are needed
        // A second request at the same zoom has nothing left to do.
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        #expect(!map.isLoading)
    }

    @Test func panningWithinLoadedRegionsRequestsNothingButNewRegionsLoad() async throws {
        let world = try stoneWorld(regions: [RegionPosition(x: 0, z: 0), RegionPosition(x: 3, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(work: BackgroundWork(), dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: CGPoint(x: 256, y: 256))
        let size = CGSize(width: 400, height: 300)
        map.requestTiles(visibleIn: size, displayScale: 2)
        await map.waitUntilIdle()
        #expect(map.tiles[RegionPosition(x: 0, z: 0)] != nil)
        map.viewport.pan(by: CGSize(width: -10, height: 0))   // still inside region (0, 0)
        map.requestTiles(visibleIn: size, displayScale: 2)
        #expect(!map.isLoading)
        map.viewport.center = CGPoint(x: 3 * 512 + 256, y: 256)  // over region (3, 0)
        map.requestTiles(visibleIn: size, displayScale: 2)
        #expect(map.isLoading)
        await map.waitUntilIdle()
        #expect(map.tiles[RegionPosition(x: 3, z: 0)] != nil)
    }

    @Test func halfSizeAveragesBlocksOfFour() {
        var pixels = [UInt8](repeating: 0, count: RegionTileRenderer.side * RegionTileRenderer.side * 4)
        // Top-left 2×2 block: two opaque white pixels, two transparent.
        for i in [0, 1] { for c in 0..<4 { pixels[i * 4 + c] = 255 } }
        let half = RegionTileRenderer.halfSize(pixels)
        #expect(half.count == RegionTileRenderer.previewSide * RegionTileRenderer.previewSide * 4)
        #expect(Array(half[0..<4]) == [128, 128, 128, 128])
    }
}

@Suite(.isolatedStores) struct ScrollWheelInputTests {
    let point = CGPoint(x: 100, y: 50)

    @Test func trackpadScrollPansWithTheFingers() {
        #expect(ScrollWheelInput.action(deltaX: 12, deltaY: -5, isTrackpad: true, command: false, at: point) == .pan(CGSize(width: 12, height: -5)))
    }

    @Test func commandScrollAndMouseWheelZoomAroundThePointer() {
        guard case .zoom(let up, let anchor)? = ScrollWheelInput.action(deltaX: 0, deltaY: 20, isTrackpad: true, command: true, at: point) else {
            Issue.record("expected a zoom"); return
        }
        #expect(up > 1)
        #expect(anchor == point)
        guard case .zoom(let down, _)? = ScrollWheelInput.action(deltaX: 0, deltaY: -1, isTrackpad: false, command: false, at: point) else {
            Issue.record("expected a zoom"); return
        }
        #expect(down < 1)
        #expect(ScrollWheelInput.action(deltaX: 3, deltaY: 0, isTrackpad: false, command: false, at: point) == nil)
    }
}

@Suite(.isolatedStores) struct LiveMapTests {
    static func stone(x: Int, z: Int, height: Int) -> TestWorld.ChunkSpec {
        TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= height ? 1 : 0 }
    }

    @Test func changedRegionsRedrawAndNewOnesAppear() async throws {
        let world = try TestWorld.make(chunks: [Self.stone(x: 0, z: 0, height: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), regionConcurrency: 1, chunkConcurrency: 1)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        await map.waitUntilIdle()
        let before = try #require(map.tiles[RegionPosition(x: 0, z: 0)])

        // The game adds a chunk to r.0.0 and creates r.-1.0.
        let regions = dimension.regionDirectory
        try Data(TestWorld.regionFile([Self.stone(x: 0, z: 0, height: 0), Self.stone(x: 1, z: 0, height: 3)]))
            .write(to: regions.appendingPathComponent("r.0.0.mca"))
        try Data(TestWorld.regionFile([Self.stone(x: -1, z: 0, height: 0)])).write(to: regions.appendingPathComponent("r.-1.0.mca"))
        map.regionsChanged([RegionPosition(x: 0, z: 0), RegionPosition(x: -1, z: 0)])
        // The old image stays until the new one is drawn.
        #expect(map.tiles[RegionPosition(x: 0, z: 0)] != nil)
        await map.waitUntilIdle()
        let after = try #require(map.tiles[RegionPosition(x: 0, z: 0)])
        #expect(after !== before)
        #expect(map.tiles[RegionPosition(x: -1, z: 0)] != nil)
    }

    @Test func watcherReportsChangedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (changes, continuation) = AsyncStream.makeStream(of: [URL].self)
        let watcher = try #require(WorldWatcher(folder: folder) { continuation.yield($0) })
        defer { watcher.stop() }
        let file = folder.appendingPathComponent("r.0.0.mca")
        try Data([1]).write(to: file)
        var seen: [URL] = []
        for await batch in changes {
            seen += batch
            if seen.contains(where: { $0.lastPathComponent == "r.0.0.mca" }) { break }
        }
        #expect(seen.contains { $0.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path })
    }

    @Test func sessionRefreshesRegionsAndPlayers() async throws {
        let world = try TestWorld.make(chunks: [Self.stone(x: 0, z: 0, height: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        session.resources.refreshDelay = .zero
        #expect(session.players.isEmpty)

        let regions = try #require(session.map?.dimension.regionDirectory)
        let newRegion = regions.appendingPathComponent("r.-1.0.mca")
        try Data(TestWorld.regionFile([Self.stone(x: -1, z: 0, height: 0)])).write(to: newRegion)
        let players = world.appendingPathComponent("players/data")
        try FileManager.default.createDirectory(at: players, withIntermediateDirectories: true)
        let player = players.appendingPathComponent(UUID().uuidString.lowercased() + ".dat")
        let nbt = NBT.compound(["Dimension": .string("minecraft:overworld"), "Pos": .list([.double(1), .double(64), .double(2)])])
        try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: player)

        session.resources.worldChanged([newRegion, player, world.appendingPathComponent("session.lock")])
        await session.resources.waitForRefresh()
        #expect(session.map?.availableRegions.contains(RegionPosition(x: -1, z: 0)) == true)
        #expect(session.players.count == 1)
    }
}

@Suite(.isolatedStores) struct HoverBlockTests {
    /// Stone at Y 0 everywhere; sand on it at x 0, z 0; three blocks of water on it at x 1, z 0.
    private func world() throws -> URL {
        let palette = ["minecraft:air", "minecraft:stone", "minecraft:sand", "minecraft:water"]
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: palette) { x, y, z in
            if y == 0 { return 1 }
            if z == 0, x == 0, y == 1 { return 2 }
            if z == 0, x == 1, y <= 3 { return 3 }
            return 0
        }
        return try TestWorld.make(chunks: [chunk])
    }

    @Test func theReadoutNamesTheBlockTheMapDrew() throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try RegionFile(contentsOf: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.0.0.mca"))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0))
        #expect(blocks[0] == .init(id: "minecraft:sand", y: 1, waterDepth: 0))
        #expect(blocks[1] == .init(id: "minecraft:water", y: 3, waterDepth: 3))   // the water's surface, as drawn
        #expect(blocks[2] == .init(id: "minecraft:stone", y: 0, waterDepth: 0))
        // Same scan as the map: every column's height and water depth match what was drawn.
        #expect(zip(blocks, columns).allSatisfy { block, column in block?.y == column?.y && block?.waterDepth == column?.waterDepth })
        #expect(MapView.describe(blocks[0]!) == "Sand" && MapView.describe(blocks[1]!) == "Water, 3 deep")
        // X, Y and Z together, then the block and biome.
        #expect(MapView.readout(at: CGPoint(x: 0.5, y: 0.5), block: blocks[0], biomes: "Plains") == "X 0  Y 1  Z 0 · Sand · Plains")
        #expect(MapView.readout(at: CGPoint(x: -3.2, y: 7), block: nil, biomes: nil) == "X -4  Z 7")
        #expect(!MapView.namesBlocks(at: 0.5) && MapView.namesBlocks(at: 1))
    }

    @Test func waterDeeperThanTheCountingLimitIsNotGivenAnExactDepth() throws {
        // Stone at Y 0 and water up to Y 63: three more sections of water above the test chunk's one.
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone", "minecraft:water"]) { _, y, _ in y == 0 ? 0 : 1 }
        guard case .compound(var root) = spec.nbt, case .list(let type, var sections)? = root["sections"] else {
            Issue.record("unexpected test chunk"); return
        }
        for y in 1...3 {
            sections.append(.compound(["Y": .byte(Int8(y)), "block_states": .compound(["palette": .list([.string("minecraft:water")])])]))
        }
        root["sections"] = .list(type, sections)
        spec.nbt = .compound(root)
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try RegionFile(contentsOf: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.0.0.mca"))
        let block = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0)?[0])
        #expect(block.id == "minecraft:water" && block.y == 63 && block.waterDepth == RegionTileRenderer.maximumWaterDepth)
        #expect(MapView.describe(block) == "Water, at least 32 deep")   // 63 deep, counted to the limit
    }

    @Test func theMapReadsTheHoveredChunkAndForgetsItWhenSaved() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, cacheDirectory: nil)
        defer { map.close() }
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5)) == nil)   // not read until hovered
        map.loadTopBlocks(at: CGPoint(x: 0.5, y: 0.5))
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5))?.id == "minecraft:sand")
        #expect(map.topBlock(at: CGPoint(x: 1.9, y: 0.2))?.id == "minecraft:water")
        map.regionsChanged([RegionPosition(x: 0, z: 0)])                  // the game saved the region
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5)) == nil)
    }
}

@Suite(.isolatedStores) struct HoverReadLifecycleTests {
    private func world(top: String = "minecraft:sand") throws -> URL {
        try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", top]) { _, y, _ in y == 0 ? 1 : y == 1 ? 2 : 0 }])
    }

    private func map(_ url: URL, read: MapModel.TopBlockReader? = nil) throws -> MapModel {
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        if let read { return MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, cacheDirectory: nil, readTopBlocks: read) }
        return MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, cacheDirectory: nil)
    }

    @Test func aSaveElsewhereKeepsTheHoveredRead() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let map = try map(url)
        defer { map.close() }
        map.loadTopBlocks(at: CGPoint(x: 0.5, y: 0.5))
        map.regionsChanged([RegionPosition(x: 1, z: 0)])   // another region saved before the read ran
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5))?.id == "minecraft:sand")
    }

    @Test func aSaveUnderAStillPointerIsReadAgain() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let map = try map(url)
        defer { map.close() }
        map.loadTopBlocks(at: CGPoint(x: 0.5, y: 0.5))
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5))?.id == "minecraft:sand")
        // The game replaces the sand with gravel and saves; the pointer doesn't move.
        let gravel = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:gravel"]) { _, y, _ in y == 0 ? 1 : y == 1 ? 2 : 0 }
        try Data(TestWorld.regionFile([gravel])).write(to: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.0.0.mca"))
        map.regionsChanged([RegionPosition(x: 0, z: 0)])
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5))?.id == "minecraft:gravel")
    }

    @Test func aReadOfTheFileBeforeASaveIsDropped() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try RegionFile(contentsOf: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.0.0.mca"))
        func blocks(_ id: String) -> [RegionTileRenderer.TopBlock?] { Array(repeating: .init(id: id, y: 1, waterDepth: 0), count: 256) }
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let reads = ReadNumbers()
        let map = try map(url) { _, _, _ in await gate.read("read\(await reads.next())") }
        defer { map.close() }
        map.loadTopBlocks(at: CGPoint(x: 0.5, y: 0.5))
        await gate.waitForRequest("read0")
        map.regionsChanged([RegionPosition(x: 0, z: 0)])   // saved while read 0 was reading the old file
        await gate.waitForRequest("read1")                   // the still pointer's chunk is read again
        await gate.finish("read1", with: (file, blocks("minecraft:new")))
        await gate.finish("read0", with: (file, blocks("minecraft:old")))   // the old read finishes last
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: CGPoint(x: 0.5, y: 0.5))?.id == "minecraft:new")
    }

    @Test func closingDrainsEveryHoverReadIncludingCancelledOnes() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = try map(url) { chunk, _, _ in await gate.read("\(chunk.x)") }
        map.loadTopBlocks(at: CGPoint(x: 0.5, y: 0.5))       // chunk 0
        await gate.waitForRequest("0")
        map.loadTopBlocks(at: CGPoint(x: 16.5, y: 0.5))      // chunk 1 replaces it, cancelling chunk 0's read
        await gate.waitForRequest("1")
        await gate.waitForCancellation("0")
        #expect(map.unfinishedHoverReads == 2)               // the cancelled read is still kept
        map.close()
        await gate.finish("1", with: nil)
        await gate.finish("0", with: nil)
        await map.waitForRenders()
        #expect(map.unfinishedHoverReads == 0)
    }
}

/// Numbers calls in the order they arrive.

