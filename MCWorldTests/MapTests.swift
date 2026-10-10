import CoreGraphics
import Foundation
import MCWorldKit
import SwiftUI
import Testing
@testable import MCWorld

@Suite struct MapAccessibilityTests {
    @Test func visiblePlayerDeathRespawnAndSearchLocationsKeepTheirNamesAndCoordinates() {
        var content = MapContent()
        content.players = [
            .init(id: "friend-player", kind: .player, position: .zero, label: "Friend", isOutdated: false),
            .init(id: "friend-death", kind: .death, position: CGPoint(x: 10, y: 20), label: "Where Friend last died", isOutdated: false),
            .init(id: "friend-respawn", kind: .respawn, position: CGPoint(x: -10, y: -20), label: "Friend’s respawn point", isOutdated: false),
            .init(id: "outside", kind: .player, position: CGPoint(x: 1000, y: 1000), label: "Outside", isOutdated: false)
        ]
        content.hits = [.init(id: "chest", source: .container(kind: "minecraft:chest"), dimension: "minecraft:overworld",
                             position: CGPoint(x: 5, y: 6), y: 64, title: "Chest", detail: "3 Diamond", count: 3)]
        let locations = content.accessibleLocations(viewport: .init(center: .zero, scale: 1), size: .init(width: 400, height: 300))
        #expect(Set(locations.map(\.name)) == ["Friend", "Where Friend last died", "Friend’s respawn point", "Chest, 3 Diamond"])
        #expect(locations.first { $0.name == "Where Friend last died" }?.position == CGPoint(x: 10, y: 20))
        #expect(Set(locations.map(\.id)).count == locations.count)
    }
}

@Suite struct MapViewportTests {
    let size = CGSize(width: 800, height: 600)

    @Test func centerOfViewIsViewportCenter() {
        let viewport = MapViewport(center: CGPoint(x: 100, y: -50), scale: 2)
        #expect(viewport.blockPoint(at: CGPoint(x: 400, y: 300), in: size) == CGPoint(x: 100, y: -50))
        #expect(viewport.blockPoint(at: CGPoint(x: 0, y: 0), in: size) == CGPoint(x: -100, y: -200))
    }

    @Test func regionRectsLineUpWithBlockCoordinates() {
        let viewport = MapViewport(center: .zero, scale: 1)
        #expect(viewport.viewRect(for: RegionCoordinate(x: 0, z: 0), in: size) == CGRect(x: 400, y: 300, width: 512, height: 512))
        #expect(viewport.viewRect(for: RegionCoordinate(x: -1, z: -1), in: size) == CGRect(x: -112, y: -212, width: 512, height: 512))
    }

    @Test func visibleRegionsAreNearestFirst() {
        let viewport = MapViewport(center: CGPoint(x: 256, y: 256), scale: 1)
        let regions = viewport.visibleRegions(in: size)
        #expect(regions.first == RegionCoordinate(x: 0, z: 0))
        // The view spans blocks x -144…656 and z -44…556, which touches regions -1…1 on both axes.
        #expect(Set(regions) == Set((-1...1).flatMap { x in (-1...1).map { RegionCoordinate(x: x, z: $0) } }))
        #expect(regions.count == 9)
    }

    @Test func zoomKeepsAnchorFixedAndClamps() {
        var viewport = MapViewport(center: .zero, scale: 1)
        let anchor = CGPoint(x: 600, y: 100)
        let before = viewport.blockPoint(at: anchor, in: size)
        viewport.zoom(by: 4, anchor: anchor, in: size)
        #expect(viewport.scale == 4)
        #expect(viewport.blockPoint(at: anchor, in: size) == before)
        viewport.zoom(by: 1000, anchor: anchor, in: size)
        #expect(viewport.scale == MapViewport.scaleRange.upperBound)
    }

    @Test func dragMovesContentWithPointer() {
        var viewport = MapViewport(center: .zero, scale: 2)
        viewport.pan(by: CGSize(width: 20, height: -10))
        #expect(viewport.center == CGPoint(x: -10, y: 5))
    }
}

@Suite struct BlockColorsTests {
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

@Suite struct RegionTileRendererTests {
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
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionCoordinate(x: 0, z: 0)))

        func pixel(_ x: Int, _ z: Int) -> [UInt8] { Array(pixels[((z * 512) + x) * 4 ..< ((z * 512) + x) * 4 + 4]) }
        func rgba(_ c: MapColor) -> [UInt8] { [c.red, c.green, c.blue, 255] }

        #expect(pixel(2, 5) == rgba(MapColor(0x7CBD6B)))                    // grass, level with its north neighbor
        #expect(pixel(10, 5) == rgba(MapColor(0x3F76E4).shaded(1.125)))     // water, one block deep
        #expect(pixel(20, 5)[3] == 0)                                        // chunk (1, 0) not generated
        #expect(pixel(2, 16) == rgba(MapColor(0x7D7D7D).shaded(1.12)))      // higher than the chunk to its north
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
        let region = RegionCoordinate(x: 0, z: 0)
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
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionCoordinate(x: 0, z: 0)))
        func rgb(_ x: Int, _ z: Int) -> [UInt8] { Array(pixels[(z * 512 + x) * 4 ..< (z * 512 + x) * 4 + 3]) }
        let lit = MapColor(0x7D7D7D).shaded(1.12)
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
        let top = open.topColumns { _ in 15 }
        #expect(top[0]?.y == 15)  // without a ceiling, the roof is the top block
        var underRoof = RegionTileRenderer.ColorSections(chunk)
        let floor = underRoof.topColumns(underCeiling: true) { _ in 15 }
        #expect(floor[0]?.y == 4)
        #expect(floor[0]?.color == BlockColors.color(for: "minecraft:netherrack"))

        // A column that is solid all the way down shows its first block under the roof, darkened.
        let solid = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:netherrack"]) { _, _, _ in 0 }
        var solidSections = RegionTileRenderer.ColorSections(try Chunk(nbt: solid.nbt))
        let rock = solidSections.topColumns(underCeiling: true) { _ in 15 }
        #expect(rock[0]?.y == 10)  // below the five-block roof band
        #expect(rock[0]?.color == BlockColors.color(for: "minecraft:netherrack")?.shaded(0.6))
    }

    @Test func missingRegionFileRendersNothing() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        #expect(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionCoordinate(x: 3, z: 3)) == nil)
    }
}

@Suite struct MapModelTests {
    @Test func loadsEveryVisibleRegionThatExists() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let map = MapModel(dimension: dimension, center: .zero, regionConcurrency: 2, chunkConcurrency: 2)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        #expect(map.isLoading)
        await map.waitUntilIdle()
        #expect(!map.isLoading)
        // Four regions are visible around the origin, but only r.0.0 exists.
        #expect(Array(map.tiles.keys) == [RegionCoordinate(x: 0, z: 0)])
    }
}

@Suite struct LevelOfDetailTests {
    func stoneWorld(regions: [RegionCoordinate]) throws -> URL {
        try TestWorld.make(chunks: regions.map { r in
            TestWorld.chunk(x: r.x * 32, z: r.z * 32, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        })
    }

    @Test func fullResolutionOnlyWhenRegionsAreLargeOnScreen() throws {
        let world = try stoneWorld(regions: [RegionCoordinate(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero)
        map.viewport.scale = 0.25   // a region is 128 points: 256 pixels at 2×, the preview's size
        #expect(!map.needsFullResolution(displayScale: 2))
        map.viewport.scale = 0.5
        #expect(map.needsFullResolution(displayScale: 2))
        #expect(!map.needsFullResolution(displayScale: 1))
    }

    @Test func visibleTilesSurviveASmallCacheAndPreviewsArePrepared() async throws {
        let regions = [RegionCoordinate(x: -1, z: -1), RegionCoordinate(x: 0, z: -1), RegionCoordinate(x: -1, z: 0), RegionCoordinate(x: 0, z: 0)]
        let world = try stoneWorld(regions: regions)
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero,
                           maxTiles: 1, maxPreviews: 1)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        await map.waitUntilIdle()
        // All four regions are visible, so none is evicted despite the limit of one.
        #expect(Set(map.tiles.keys) == Set(regions))
        #expect(Set(map.previews.keys) == Set(regions))
        #expect(map.previews[RegionCoordinate(x: 0, z: 0)]?.width == RegionTileRenderer.previewSide)
    }

    @Test func zoomedOutRequestsNeedOnlyPreviews() async throws {
        let world = try stoneWorld(regions: [RegionCoordinate(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero)
        map.viewport.scale = 1.0 / 16
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        await map.waitUntilIdle()
        #expect(map.image(for: RegionCoordinate(x: 0, z: 0), fullResolution: false)?.width == RegionTileRenderer.previewSide)
        #expect(map.tiles.isEmpty)  // full tiles aren't kept when only previews are needed
        // A second request at the same zoom has nothing left to do.
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        #expect(!map.isLoading)
    }

    @Test func panningWithinLoadedRegionsRequestsNothingButNewRegionsLoad() async throws {
        let world = try stoneWorld(regions: [RegionCoordinate(x: 0, z: 0), RegionCoordinate(x: 3, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: CGPoint(x: 256, y: 256))
        let size = CGSize(width: 400, height: 300)
        map.requestTiles(visibleIn: size, displayScale: 2)
        await map.waitUntilIdle()
        #expect(map.tiles[RegionCoordinate(x: 0, z: 0)] != nil)
        map.viewport.pan(by: CGSize(width: -10, height: 0))   // still inside region (0, 0)
        map.requestTiles(visibleIn: size, displayScale: 2)
        #expect(!map.isLoading)
        map.viewport.center = CGPoint(x: 3 * 512 + 256, y: 256)  // over region (3, 0)
        map.requestTiles(visibleIn: size, displayScale: 2)
        #expect(map.isLoading)
        await map.waitUntilIdle()
        #expect(map.tiles[RegionCoordinate(x: 3, z: 0)] != nil)
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

@Suite struct ScrollWheelInputTests {
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

@Suite struct LiveMapTests {
    static func stone(x: Int, z: Int, height: Int) -> TestWorld.ChunkSpec {
        TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= height ? 1 : 0 }
    }

    @Test func changedRegionsRedrawAndNewOnesAppear() async throws {
        let world = try TestWorld.make(chunks: [Self.stone(x: 0, z: 0, height: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let map = MapModel(dimension: dimension, center: CGPoint(x: 8, y: 8), regionConcurrency: 1, chunkConcurrency: 1)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        await map.waitUntilIdle()
        let before = try #require(map.tiles[RegionCoordinate(x: 0, z: 0)])

        // The game adds a chunk to r.0.0 and creates r.-1.0.
        let regions = dimension.regionDirectory
        try Data(TestWorld.regionFile([Self.stone(x: 0, z: 0, height: 0), Self.stone(x: 1, z: 0, height: 3)]))
            .write(to: regions.appendingPathComponent("r.0.0.mca"))
        try Data(TestWorld.regionFile([Self.stone(x: -1, z: 0, height: 0)])).write(to: regions.appendingPathComponent("r.-1.0.mca"))
        map.regionsChanged([RegionCoordinate(x: 0, z: 0), RegionCoordinate(x: -1, z: 0)])
        // The old image stays until the new one is drawn.
        #expect(map.tiles[RegionCoordinate(x: 0, z: 0)] != nil)
        await map.waitUntilIdle()
        let after = try #require(map.tiles[RegionCoordinate(x: 0, z: 0)])
        #expect(after !== before)
        #expect(map.tiles[RegionCoordinate(x: -1, z: 0)] != nil)
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
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        session.refreshDelay = .zero
        #expect(session.players.isEmpty)

        let regions = try #require(session.map?.dimension.regionDirectory)
        let newRegion = regions.appendingPathComponent("r.-1.0.mca")
        try Data(TestWorld.regionFile([Self.stone(x: -1, z: 0, height: 0)])).write(to: newRegion)
        let players = world.appendingPathComponent("players/data")
        try FileManager.default.createDirectory(at: players, withIntermediateDirectories: true)
        let player = players.appendingPathComponent(UUID().uuidString.lowercased() + ".dat")
        let nbt = NBT.compound(["Dimension": .string("minecraft:overworld"), "Pos": .list([.double(1), .double(64), .double(2)])])
        try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: player)

        session.worldChanged([newRegion, player, world.appendingPathComponent("session.lock")])
        await session.waitForRefresh()
        #expect(session.map?.availableRegions.contains(RegionCoordinate(x: -1, z: 0)) == true)
        #expect(session.players.count == 1)
    }
}
