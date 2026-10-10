import CoreGraphics
import Foundation
import MCWorldKit
import SwiftUI
import Testing
@testable import MCWorld

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

@Suite struct TileCacheTests {
    @Test func secondRenderComesFromTheCacheAndChangesInvalidateIt() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldTileCache-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: world)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionCoordinate(x: 0, z: 0)
        let renderer = RegionTileRenderer(dimension: dimension, cache: TileCache(directory: cacheDir), savesInBackground: false)
        let regionFile = dimension.regionDirectory.appendingPathComponent("r.0.0.mca")

        let first = try #require(try await renderer.tile(for: region))
        let key = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(TileCache(directory: cacheDir).load(key) != nil)
        let second = try #require(try await renderer.tile(for: region))
        #expect(second.full.dataProvider?.data as Data? == first.full.dataProvider?.data as Data?)

        // Touching the region file (as the game does on save) makes a new key; the old entry is replaced.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: regionFile.path)
        let newKey = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(newKey != key)
        #expect(TileCache(directory: cacheDir).load(newKey) == nil)
        _ = try await renderer.tile(for: region)
        #expect(TileCache(directory: cacheDir).load(newKey) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count == 1)
    }
}

@Suite struct TileCachePruningTests {
    @Test func prunesLeastRecentlyUsedWorldsButKeepsTheOpenOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldPrune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func world(_ name: String, bytes: Int, daysAgo: Double) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("overworld"), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: folder.appendingPathComponent("overworld/r.0.0.x"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: folder.path)
            return folder
        }
        let oldest = try world("a", bytes: 400, daysAgo: 30)
        let middle = try world("b", bytes: 400, daysAgo: 10)
        let open = try world("c", bytes: 400, daysAgo: 60)   // oldest, but it's the world being opened
        TileCache.prune(root: root, limit: 900, keeping: open)
        // A dimension's folder sits inside its world's folder, which sits directly in the root.
        let world = URL(fileURLWithPath: "/tmp/Some World")
        let worldFolder = try #require(TileCache.worldFolder(forWorldAt: world))
        #expect(worldFolder.deletingLastPathComponent().standardizedFileURL == TileCache.root?.standardizedFileURL)
        #expect(TileCache.directory(forWorldAt: world, dimensionID: "minecraft:overworld")?.deletingLastPathComponent().standardizedFileURL
                == worldFolder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: open.path))
    }
}

@Suite struct PlayerMarkerTests {
    let you = UUID(uuidString: "52DFB519-DE9C-47E6-BC6C-BB053CC423E7")!
    let friend = UUID(uuidString: "06D119DA-BC79-410F-8F7B-062CE442A86D")!
    let bukkit = UUID(uuidString: "11C0E607-2120-4B62-A7E5-938F830B3CE7")!

    func pos(_ x: Double, _ z: Double) -> NBT { .list([.double(x), .double(64), .double(z)]) }

    var players: [PlayerInfo] {
        [
            PlayerInfo(uuid: you, nbt: .compound([
                "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"), "Pos": pos(-2806.6, -3895.2),
                "LastDeathLocation": .compound(["dimension": .string("minecraft:the_nether"), "pos": .intArray([10, 70, 20])]),
                "respawn": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([-2811, 48, -3918])]),
            ])),
            PlayerInfo(uuid: friend, nbt: .compound(["DataVersion": .int(2730), "Dimension": .string("minecraft:overworld"), "Pos": pos(99, -68)])),
            PlayerInfo(uuid: bukkit, nbt: .compound(["Dimension": .int(0), "Pos": pos(-12, 241), "SpawnWorld": .string("laurenland")])),
        ]
    }

    @Test func markersForTheOverworld() {
        let markers = PlayerPresentation.markers(for: players, in: "minecraft:overworld", singleplayerUUID: you, worldDataVersion: 5023)
        // You (position + respawn) and the friend; the death is in the Nether; the Bukkit player is left off.
        #expect(markers.count == 3)
        let mine = markers.first { $0.kind == .player && $0.label == "You" }
        #expect(mine?.position == CGPoint(x: -2806.6, y: -3895.2))
        #expect(mine?.isOutdated == false)
        #expect(markers.contains { $0.kind == .respawn })
        let theirs = markers.first { $0.label == "Player 06d119da" }
        #expect(theirs?.isOutdated == true)  // file predates the world's version
        #expect(!markers.contains { $0.position == CGPoint(x: -12, y: 241) })
    }

    @Test func deathMarkerAppearsInItsOwnDimension() {
        let nether = PlayerPresentation.markers(for: players, in: "minecraft:the_nether", singleplayerUUID: you, worldDataVersion: 5023)
        #expect(nether.map(\.kind) == [.death])
        #expect(nether.first?.position == CGPoint(x: 10, y: 20))
    }
}

@Suite struct PlayerNameTests {
    let friend = UUID(uuidString: "06D119DA-BC79-410F-8F7B-062CE442A86D")!
    let you = UUID(uuidString: "52DFB519-DE9C-47E6-BC6C-BB053CC423E7")!

    /// A fake Mojang that records requests and answers from a table.
    nonisolated final class FakeMojang: @unchecked Sendable {  // state guarded by `lock`
        var requests: [URL] = []
        var answers: [String: (String, Int)] = [:]
        let lock = NSLock()

        var profiles: MojangProfiles {
            MojangProfiles(fetch: { url in
                self.lock.withLock {
                    self.requests.append(url)
                    let (body, status) = self.answers[url.lastPathComponent] ?? ("", 404)
                    return (Data(body.utf8), status)
                }
            })
        }
    }

    func freshDefaults() -> UserDefaults {
        let name = "MCWorldTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func mojangProfileURLAndResponses() async throws {
        #expect(MojangProfiles.profileURL(for: friend).absoluteString
                == "https://sessionserver.mojang.com/session/minecraft/profile/06d119dabc79410f8f7b062ce442a86d")
        let fake = FakeMojang()
        fake.answers["06d119dabc79410f8f7b062ce442a86d"] = (#"{"id":"06d119dabc79410f8f7b062ce442a86d","name":"Friend"}"#, 200)
        fake.answers["52dfb519de9c47e6bc6cbb053cc423e7"] = ("", 500)
        #expect(try await fake.profiles.name(for: friend) == "Friend")
        await #expect(throws: MojangProfiles.LookupError.unexpectedStatus(500)) { try await fake.profiles.name(for: you) }
        #expect(try await fake.profiles.name(for: UUID()) == nil)  // 404: no such profile
    }

    @Test func onlineLookupIsOffByDefaultAndSendsNothing() async {
        let fake = FakeMojang()
        let names = PlayerNames(defaults: freshDefaults(), mojang: fake.profiles)
        #expect(!names.looksUpOnline)
        await names.lookUp([friend])
        #expect(fake.requests.isEmpty)
        #expect(names.name(for: friend) == nil)
    }

    @Test func onlineLookupFindsRemembersAndDoesNotRepeat() async {
        let fake = FakeMojang()
        fake.answers["06d119dabc79410f8f7b062ce442a86d"] = (#"{"name":"Friend"}"#, 200)
        let defaults = freshDefaults()
        let names = PlayerNames(defaults: defaults, mojang: fake.profiles)
        names.looksUpOnline = true
        await names.lookUp([friend, you])  // `you` answers 404
        await names.lookUp([friend, you])
        #expect(names.name(for: friend) == "Friend")
        #expect(fake.requests.count == 2)  // each UUID asked once
        // Remembered across launches, without asking again.
        let relaunched = PlayerNames(defaults: defaults, mojang: FakeMojang().profiles)
        #expect(relaunched.name(for: friend) == "Friend")
        #expect(relaunched.looksUpOnline)
    }

    @Test func localCachesWinAndAreReadFromTheChosenFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldNames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("vanilla/release"), withIntermediateDirectories: true)
        try Data(#"[{"uuid":"52dfb519-de9c-47e6-bc6c-bb053cc423e7","name":"fahlman","expiresOn":"2026-11-09 21:40:44 -0500"}]"#.utf8)
            .write(to: folder.appendingPathComponent("vanilla/release/usercache.json"))
        let fake = FakeMojang()
        let names = PlayerNames(defaults: freshDefaults(), mojang: fake.profiles)
        await names.chooseMinecraftFolder(folder)
        names.looksUpOnline = true
        await names.lookUp([you])
        #expect(names.name(for: you) == "fahlman")
        #expect(fake.requests.isEmpty)  // known locally, so not sent online
        let player = PlayerInfo(uuid: you, nbt: .compound([:]))
        #expect(PlayerPresentation.name(of: player, singleplayerUUID: you, knownName: names.name(for: you)) == "fahlman")
        names.forgetMinecraftFolder()
        #expect(names.name(for: you) == nil)
    }
}

@Suite struct StructureTests {
    /// A structure start built the way chunks store it, read through MCWorldKit's public API.
    func start(_ id: String, chunk: (Int, Int), pieces: [(String, [Int])]) -> StructureStart {
        let nbt = NBT.compound(["structures": .compound(["starts": .compound([id: .compound([
            "id": .string(id), "ChunkX": .int(Int32(chunk.0)), "ChunkZ": .int(Int32(chunk.1)),
            "Children": .list(.compound, pieces.map { .compound(["id": .string($0.0), "BB": .intArray($0.1.map { Int32($0) })]) }),
        ])])])])
        return StructureStart.starts(inChunk: nbt)[0]
    }

    @Test func groupsNamesAndDefaults() {
        #expect(StructureGroup.group(for: "minecraft:village_savanna") == .village)
        #expect(StructureGroup.group(for: "minecraft:ocean_ruin_cold") == .ruins)
        #expect(StructureGroup.group(for: "minecraft:mineshaft_mesa") == .mineshaft)
        #expect(StructureGroup.group(for: "mydatapack:tower") == .other)
        #expect(!StructureGroup.mineshaft.isShownByDefault && !StructureGroup.netherFossil.isShownByDefault)
        #expect(StructureGroup.stronghold.isShownByDefault)
        let names = ["minecraft:village_plains", "minecraft:ocean_ruin_cold", "minecraft:ruined_portal_ocean",
                     "minecraft:shipwreck_beached", "minecraft:ancient_city"].map {
            StructureMarker(start($0, chunk: (0, 0), pieces: [])).name
        }
        #expect(names == ["Plains Village", "Cold Ocean Ruin", "Ocean Ruined Portal", "Beached Shipwreck", "Ancient City"])
    }

    @Test func boundsAndStrongholdPortalRoom() {
        let marker = StructureMarker(start("minecraft:stronghold", chunk: (-302, -51), pieces: [
            ("minecraft:shstart", [-4830, -19, -814, -4826, -9, -810]),
            ("minecraft:shpr", [-4900, -40, -830, -4890, -32, -815]),
        ]))
        #expect(marker.bounds == CGRect(x: -4900, y: -830, width: 75, height: 21))
        #expect(marker.portalRoom == CGPoint(x: -4894.5, y: -822))
        // No pieces: the start chunk stands in.
        #expect(StructureMarker(start("minecraft:igloo", chunk: (2, -3), pieces: [])).bounds == CGRect(x: 32, y: -48, width: 16, height: 16))
    }

    @Test func scannerFindsStructuresAcrossRegions() async throws {
        func withStructure(_ spec: TestWorld.ChunkSpec, _ id: String) -> TestWorld.ChunkSpec {
            var spec = spec
            var root = spec.nbt.compound!
            root["structures"] = .compound(["References": .compound([:]), "starts": .compound([id: .compound([
                "id": .string(id), "ChunkX": .int(Int32(spec.x)), "ChunkZ": .int(Int32(spec.z)),
                "Children": .list([.compound(["id": .string("piece"),
                                              "BB": .intArray([Int32(spec.x * 16), 60, Int32(spec.z * 16), Int32(spec.x * 16 + 9), 70, Int32(spec.z * 16 + 9)])])]),
            ])])])
            spec.nbt = .compound(root)
            return spec
        }
        let stone = { (x: Int, z: Int) in TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } }
        let world = try TestWorld.make(chunks: [
            withStructure(stone(0, 0), "minecraft:village_plains"),
            withStructure(stone(40, -1), "minecraft:stronghold"),   // region (1, -1)
            stone(1, 0),
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let found = await StructureScanner.scan(dimension, concurrency: 2)
        #expect(found.map(\.structureID).sorted() == ["minecraft:stronghold", "minecraft:village_plains"])
        #expect(found.first { $0.group == .stronghold }?.bounds == CGRect(x: 640, y: -16, width: 10, height: 10))
    }
}

@Suite struct PlaceTests {
    func poi(_ type: String, _ x: Int, _ y: Int, _ z: Int, tickets: Int = 1) -> PointOfInterest {
        PointOfInterest(type: type, x: x, y: y, z: z, freeTickets: tickets)
    }

    @Test func groupsNamesAndClaims() {
        #expect(PlaceGroup.group(for: "minecraft:librarian") == .workstation)
        #expect(PlaceGroup.group(for: "minecraft:meeting") == .bell)
        #expect(PlaceGroup.group(for: "minecraft:beehive") == .beeNest)
        #expect(PlaceGroup.portal.isShownByDefault && !PlaceGroup.bed.isShownByDefault)
        #expect(PlaceMarker(poi("minecraft:librarian", 0, 64, 0)).name == "Librarian’s Workstation")
        let claimedBed = PlaceMarker(poi("minecraft:home", 0, 64, 0, tickets: 0))
        #expect(claimedBed.isClaimed && claimedBed.name == "Villager’s Bed")
        #expect(!PlaceMarker(poi("minecraft:meeting", 0, 64, 0, tickets: 0)).isClaimed)  // only beds and workstations
    }

    @Test func onePlacePerPortalFromMCWorldKitsGrouping() {
        // A 2-wide, 3-tall portal at x 10–11, plus a separate single block far away.
        let blocks = [(10, 64), (11, 64), (10, 65), (11, 65), (10, 66), (11, 66)].map { poi("minecraft:nether_portal", $0.0, $0.1, 5) }
            + [poi("minecraft:nether_portal", 200, 70, 5)]
        let places = NetherPortal.portals(from: blocks, in: "minecraft:overworld").map(PlaceMarker.init)
        #expect(places.count == 2)
        #expect(places.contains { $0.position == CGPoint(x: 11, y: 5.5) && $0.y == 64 && $0.portal?.blocks.count == 6 })
        #expect(places.allSatisfy { $0.group == .portal })
    }

    @Test func portalLinkStatuses() {
        typealias Block = NetherPortal.Block
        func frame(_ d: String, _ x: Int, _ z: Int) -> NetherPortal {
            NetherPortal(dimension: d, blocks: [0, 1].flatMap { dx in (0..<3).map { Block(x: x + dx, y: 64 + $0, z: z) } })
        }
        let a = frame("minecraft:overworld", 800, 0), b = frame("minecraft:overworld", 840, 0)  // both lead near nether x 100–105
        let n = frame("minecraft:the_nether", 100, 0)
        let lonely = frame("minecraft:overworld", 8000, 8000)
        let portals = ["minecraft:overworld": [a, b, lonely], "minecraft:the_nether": [n]]
        #expect(PortalLinkStatus.status(of: a, portals: portals) == .linked)    // n leads back to a (closer to 800)
        #expect(PortalLinkStatus.status(of: b, portals: portals) == .oneWay)    // b -> n, but n -> a
        #expect(PortalLinkStatus.status(of: lonely, portals: portals) == .noPartner)
        #expect(PortalLinkStatus.status(of: a, portals: ["minecraft:overworld": [a]]) == nil)  // Nether not loaded yet
    }

    @Test func scannerReadsPoiFiles() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let records: [NBT] = [
            .compound(["type": .string("minecraft:nether_portal"), "pos": .intArray([1, 70, 1]), "free_tickets": .int(0)]),
            .compound(["type": .string("minecraft:nether_portal"), "pos": .intArray([1, 71, 1]), "free_tickets": .int(0)]),
            .compound(["type": .string("minecraft:home"), "pos": .intArray([5, 64, 5]), "free_tickets": .int(0)]),
        ]
        let chunk = NBT.compound(["DataVersion": .int(5023), "Sections": .compound(["4": .compound(["Valid": .byte(1), "Records": .list(records)])])])
        let poiDir = world.appendingPathComponent("dimensions/minecraft/overworld/poi")
        try FileManager.default.createDirectory(at: poiDir, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([TestWorld.ChunkSpec(x: 0, z: 0, nbt: chunk)])).write(to: poiDir.appendingPathComponent("r.0.0.mca"))
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let places = await PlaceScanner.scan(dimension)
        #expect(places.filter { $0.group == .portal }.count == 1)  // two blocks, one portal
        #expect(places.filter { $0.group == .bed }.count == 1)
    }
}

@Suite struct WorldSearchTests {
    func item(_ id: String, _ count: Int32, components: [String: NBT]? = nil) -> NBT {
        var c: [String: NBT] = ["id": .string(id), "count": .int(count)]
        if let components { c["components"] = .compound(components) }
        return .compound(c)
    }

    @Test func readableNamesAndMatching() throws {
        #expect(ReadableName.from("minecraft:diamond_sword") == "Diamond Sword")
        let sword = try #require(ItemStack(item("minecraft:diamond_sword", 1, components: ["minecraft:custom_name": .string("Excalibur")])))
        #expect(WorldSearch.matches(sword, words: ["diamond", "sword"]))
        #expect(WorldSearch.matches(sword, words: ["excal"]))
        #expect(!WorldSearch.matches(sword, words: ["diamond", "pickaxe"]))
    }

    @Test func searchFindsContainersNestedItemsAndPlayers() {
        let shulker = item("minecraft:shulker_box", 1, components: ["minecraft:container": .list([.compound(["slot": .int(0), "item": item("minecraft:diamond", 64)])])])
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(10), "y": .int(64), "z": .int(-5), "Items": .list([item("minecraft:diamond", 3), shulker])]),
            .compound(["id": .string("minecraft:barrel"), "x": .int(0), "y": .int(64), "z": .int(0), "Items": .list([item("minecraft:dirt", 64)])]),
        ])])
        let index = SearchIndex(containers: ItemContainer.containers(inChunk: chunk).map { .init(dimension: "minecraft:overworld", value: $0) })
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "Dimension": .string("minecraft:overworld"), "Pos": .list([.double(1), .double(64), .double(2)]),
            "EnderItems": .list([item("minecraft:diamond", 5)]),
        ]))
        let hits = WorldSearch.search("diamond", in: index, players: [player]) { _ in "fahlman" }
        #expect(hits.map(\.count) == [67, 5])   // chest (3 + 64 in the shulker box), then the ender chest
        #expect(hits[0].title == "Chest" && hits[0].detail == "67 Diamond")
        #expect(hits[0].position == CGPoint(x: 10.5, y: -4.5))
        #expect(hits[1].title == "fahlman’s ender chest" && hits[1].position == nil)
        #expect(WorldSearch.search("  ", in: index, players: [player]) { _ in "" }.isEmpty)
    }

    @Test func signsAndBooksMatchTheirText() throws {
        let side = { (lines: [String]) in NBT.compound(["messages": .list(lines.map(NBT.string))]) }
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:sign"), "x": .int(-2895), "y": .int(68), "z": .int(2245),
                       "front_text": side(["East", "Northeast", "to", "Desert"]), "back_text": side(["Village", "", "", ""])]),
            .compound(["id": .string("minecraft:hanging_sign"), "x": .int(0), "y": .int(70), "z": .int(0), "front_text": side(["Exit", "", "", ""])]),
            .compound(["id": .string("minecraft:lectern"), "x": .int(5), "y": .int(64), "z": .int(5), "Book": item("minecraft:written_book", 1, components: [
                "minecraft:written_book_content": .compound(["title": .compound(["raw": .string("Travels")]), "author": .string("fahlman"),
                                                            "pages": .list([.compound(["raw": .string("We found a desert village today.")])])]),
            ])]),
        ])])
        let index = SearchIndex(containers: ItemContainer.containers(inChunk: chunk).map { .init(dimension: "minecraft:overworld", value: $0) },
                                signs: Sign.signs(inChunk: chunk).map { .init(dimension: "minecraft:overworld", value: $0) })
        // A phrase can run across a sign's lines and onto its back.
        let hits = WorldSearch.search("desert village", in: index, players: []) { _ in "" }
        #expect(hits.map(\.title).sorted() == ["Lectern", "Sign"])
        #expect(hits.first { $0.source == .sign }?.detail == "East / Northeast / to / Desert / Village")
        #expect(hits.first { $0.title == "Lectern" }?.detail == "1 “Travels” by fahlman")
        #expect(WorldSearch.search("written book", in: index, players: []) { _ in "" }.map(\.title) == ["Lectern"])
        #expect(WorldSearch.search("exit", in: index, players: []) { _ in "" }.map(\.title) == ["Hanging Sign"])
    }

    @Test func sessionIndexesAndSearchesAWorld() async throws {
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        var root = spec.nbt.compound!
        root["block_entities"] = .list([.compound(["id": .string("minecraft:chest"), "x": .int(3), "y": .int(1), "z": .int(4),
                                                   "Items": .list([item("minecraft:golden_apple", 2)])]),
                                       .compound(["id": .string("minecraft:sign"), "x": .int(8), "y": .int(1), "z": .int(9),
                                                  "front_text": .compound(["messages": .list([.string("Orchard"), .string(""), .string(""), .string("")])])])])
        spec.nbt = .compound(root)
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults))
        defer { session.close() }
        session.searchText = "golden apple"
        #expect(session.isIndexing)
        await session.waitForIndex()
        #expect(session.searchResults.map(\.detail) == ["2 Golden Apple"])
        session.show(session.searchResults[0])
        #expect(session.selectedHitID == session.searchResults[0].id)
        #expect(session.map?.viewport.center == CGPoint(x: 3.5, y: 4.5))
        session.searchText = "orchard"
        #expect(session.searchResults.map(\.detail) == ["Orchard"])
        session.searchText = ""
        #expect(session.searchResults.isEmpty)
    }
}

@Suite struct ItemAppearanceTests {
    @Test func symbolsAndTintsByCategoryAndMaterial() {
        #expect(ItemAppearance.symbol(for: "minecraft:diamond_pickaxe") == "hammer.fill")
        #expect(ItemAppearance.symbol(for: "minecraft:iron_chestplate") == "tshirt.fill")
        #expect(ItemAppearance.symbol(for: "minecraft:golden_apple") == "fork.knife")
        #expect(ItemAppearance.symbol(for: "minecraft:filled_map") == "map.fill")
        #expect(ItemAppearance.symbol(for: "minecraft:cobblestone") == "cube.fill")
        #expect(ItemAppearance.tint(for: "minecraft:redstone_torch") == .red)
        #expect(ItemAppearance.tint(for: "minecraft:stone_axe") == .gray)
    }

    @Test func slotsDescriptionsAndEnchantments() throws {
        let sword = try #require(ItemStack(.compound(["id": .string("minecraft:diamond_sword"), "count": .int(1), "Slot": .byte(10), "components": .compound([
            "minecraft:custom_name": .string("Excalibur"), "minecraft:enchantments": .compound(["minecraft:sharpness": .int(5)]),
        ])])))
        let torches = ItemStack(id: "minecraft:torch", count: 64, slot: 0)
        #expect(ItemAppearance.description(of: sword) == "Diamond Sword “Excalibur”, enchanted")
        #expect(ItemAppearance.description(of: torches) == "64 Torch")
        let hotbar = ItemAppearance.slots([torches, sword], count: 9)
        #expect(hotbar.count == 9 && hotbar[0]?.id == "minecraft:torch" && hotbar.compactMap(\.self).count == 1)
        #expect(ItemAppearance.slots([torches, sword], first: 9, count: 27)[1]?.id == "minecraft:diamond_sword")
        #expect(!ItemAppearance.isEnchanted(torches))
    }
}

@Suite struct WorldDetailsTests {
    @Test func ruleNamesAndClock() {
        #expect(WorldDetails.readableRule("minecraft:keep_inventory") == "Keep Inventory")
        #expect(WorldDetails.readableRule("doDaylightCycle") == "Do Daylight Cycle")
        #expect(WorldDetails.clockTime(ofDayTicks: 0) == (6, 0))
        #expect(WorldDetails.clockTime(ofDayTicks: 18_000) == (0, 0))
        #expect(WorldDetails.clockTime(ofDayTicks: 24_000 * 3 + 4_245) == (10, 14))
    }

    @Test func sessionReadsDetailsAndShowsOnlyALimitedBorder() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        func write(_ path: String, _ data: [String: NBT]) throws {
            let url = world.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let root = NBT.compound(["DataVersion": .int(5023), "data": .compound(data)])
            try Data(Compression.deflate(root.serialized(), gzip: true)).write(to: url)
        }
        try write("data/minecraft/game_rules.dat", ["minecraft:keep_inventory": .byte(1)])
        try write("dimensions/minecraft/overworld/data/minecraft/world_border.dat", ["size": .double(2000), "center_x": .double(100), "center_z": .double(0)])
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults))
        defer { session.close() }
        #expect(session.details.gameRules.map(\.name) == ["Keep Inventory"])
        #expect(session.visibleBorder?.size == 2000)
        session.inspector = .world
        #expect(session.inspector == .world)
    }
}

@Suite struct PlayerRecordsTests {
    @Test func namesRankingsAndDistances() {
        #expect(PlayerRecords.travelName("minecraft:aviate_one_cm") == "Elytra")
        #expect(PlayerRecords.travelName("minecraft:boat_one_cm") == "Boat")
        #expect(PlayerRecords.advancementName("minecraft:story/mine_diamond") == "Mine Diamond")
        let records = PlayerRecords(statistics: PlayerStatistics(values: [
            "minecraft:custom": ["minecraft:walk_one_cm": 250_000, "minecraft:boat_one_cm": 2_087_548_000, "minecraft:crouch_one_cm": 5_000],
            "minecraft:mined": ["minecraft:stone": 900, "minecraft:dirt": 1200, "minecraft:sand": 5],
        ]))
        #expect(records.distances.map(\.name) == ["Boat", "Walk"])   // crouching, under 100 m, is left out
        #expect(records.distances.first?.kilometers == 20_875.48)
        #expect(records.top("minecraft:mined", count: 2).map(\.name) == ["Dirt", "Stone"])
        #expect(records.rows.count == 6 && records.rows.contains { $0.category == "General" && $0.name == "Walk One Cm" })
    }

    @Test func readsUUIDFilesAndFallsBackToNameKeyedStatistics() async throws {
        let worldURL = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: worldURL) }
        let uuid = UUID()
        let stats = worldURL.appendingPathComponent("players/stats")
        let advancements = worldURL.appendingPathComponent("players/advancements")
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: advancements, withIntermediateDirectories: true)
        try Data(#"{"stat.playOneMinute":144000}"#.utf8).write(to: stats.appendingPathComponent("PlayerTwo.json"))
        try Data(#"{"minecraft:story/mine_stone":{"criteria":{"get_stone":"2012-01-01 10:00:00 +0000"},"done":true},"minecraft:recipes/misc/x":{"criteria":{},"done":true},"DataVersion":5023}"#.utf8)
            .write(to: advancements.appendingPathComponent(uuid.uuidString.lowercased() + ".json"))
        let world = try World(contentsOf: worldURL)
        let records = await PlayerRecords.load(from: world, uuid: uuid, name: "PlayerTwo")
        #expect(records.statistics?.playTime == 144_000)
        #expect(records.completedAdvancements.map(\.id) == ["minecraft:story/mine_stone"])
        #expect(await PlayerRecords.load(from: world, uuid: UUID(), name: nil).statistics == nil)
    }
}

@Suite struct InGameMapTests {
    func mapNBT(dimension: NBT, scale: Int8 = 0, x: Int32 = 0, z: Int32 = 0, drawn: Bool = true) -> NBT {
        var colors = [Int8](repeating: 0, count: 128 * 128)
        if drawn { colors[0] = 4 * 12 + 2 }   // water, top-left pixel
        return .compound(["DataVersion": .int(5023), "data": .compound([
            "dimension": dimension, "scale": .byte(scale), "xCenter": .int(x), "zCenter": .int(z), "colors": .byteArray(colors),
        ])])
    }

    @Test func imageAndFittingScale() throws {
        let map = try #require(MapItem(id: 1, nbt: mapNBT(dimension: .string("minecraft:overworld"), scale: 3)))
        let image = try #require(InGameMapImage.make(map))
        #expect(image.width == 128 && image.height == 128)
        #expect(InGameMapImage.fittingScale(for: map) == 0.5)   // 1,024 blocks in about 512 points
        #expect(InGameMapImage.fittingScale(for: try #require(MapItem(id: 2, nbt: mapNBT(dimension: .byte(0))))) == 4)
    }

    @Test func sessionListsDrawnMapsAndShowsOne() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let maps = world.appendingPathComponent("data/minecraft/maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        func write(_ id: Int, _ nbt: NBT) throws {
            try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: maps.appendingPathComponent("\(id).dat"))
        }
        try write(3, mapNBT(dimension: .string("minecraft:overworld"), scale: 1, x: 256, z: -2432))
        try write(4, mapNBT(dimension: .string("minecraft:overworld"), drawn: false))   // blank
        try write(5, mapNBT(dimension: .byte(15)))                                       // another Bukkit world
        try write(6, mapNBT(dimension: .string("minecraft:the_nether")))                 // dimension not in this world
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults))
        defer { session.close() }
        #expect(session.inGameMaps.map(\.id) == [3])
        session.show(session.inGameMaps[0])
        #expect(session.visibleInGameMap?.id == 3)
        #expect(session.map?.viewport.center == CGPoint(x: 256, y: -2432) && session.map?.viewport.scale == 2)
        session.selectedInGameMapID = nil
        #expect(session.visibleInGameMap == nil)
    }
}

@Suite struct HeatMapTests {
    @Test func logarithmicScaleAndColors() throws {
        #expect(HeatMap.level(ofTicks: 1_199) == nil)
        #expect(HeatMap.level(ofTicks: HeatMap.minimumTicks) == 0)
        #expect(HeatMap.level(ofTicks: HeatMap.maximumTicks * 50) == 1)
        let hour = try #require(HeatMap.level(ofTicks: 72_000))
        #expect(hour > 0.3 && hour < 0.45)
        #expect(HeatMap.hue(atLevel: 1) == 0)   // red
        let red = HeatMap.rgb(hue: 0), blue = HeatMap.rgb(hue: 0.66)
        #expect(red.0 == 1 && red.2 == 0 && blue.2 == 1)
        var ticks = [Int](repeating: 0, count: 1024)
        #expect(HeatMap.image(fromTicks: ticks) == nil)
        ticks[33] = 72_000
        let image = try #require(HeatMap.image(fromTicks: ticks))
        #expect(image.width == 32 && image.height == 32)
    }

    @Test func sessionReadsTheSelectedDimensionWhenShown() async throws {
        var lived = TestWorld.chunk(x: 1, z: 1, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        var root = lived.nbt.compound!
        root["InhabitedTime"] = .long(720_000)
        lived.nbt = .compound(root)
        let world = try TestWorld.make(chunks: [lived])
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults))
        defer { session.close() }
        #expect(session.visibleHeatMap == nil && !session.isLoadingHeatMap)
        session.showsHeatMap = true
        #expect(session.isLoadingHeatMap)
        await session.waitForHeatMaps()
        #expect(session.visibleHeatMap?.keys.sorted { $0.x < $1.x } == [RegionCoordinate(x: 0, z: 0)])
        session.showsHeatMap = false
        #expect(session.visibleHeatMap == nil)
    }
}

@Suite struct BiomeViewTests {
    @Test func paletteColorsAreDistinctAndReadBack() {
        #expect(Set(BiomeColors.table.values).count == BiomeColors.table.count)
        let plains = BiomeColors.color(for: "minecraft:plains")
        #expect(BiomeColors.biome(red: plains.red, green: plains.green, blue: plains.blue) == "minecraft:plains")
        #expect(BiomeColors.color(for: "mymod:glade") == BiomeColors.color(for: "mymod:glade"))
    }

    @Test func biomeTilesAreFlatAndNameTheBiomeUnderThePointer() async throws {
        // Two heights, which terrain relief would shade differently.
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, z in y <= (z < 8 ? 1 : 3) ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension, style: .biomes).pixels(for: RegionCoordinate(x: 0, z: 0)))
        let plains = BiomeColors.color(for: "minecraft:plains")
        for z in [0, 7, 8, 15] {
            let i = z * RegionTileRenderer.side * 4
            #expect(Array(pixels[i..<i + 4]) == [plains.red, plains.green, plains.blue, 255])
        }
        let map = MapModel(dimension: dimension, center: CGPoint(x: 8, y: 8), style: .biomes, regionConcurrency: 1, chunkConcurrency: 1)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        await map.waitUntilIdle()
        #expect(map.biome(at: CGPoint(x: 3.5, y: 9.2)) == "minecraft:plains")
        #expect(map.biome(at: CGPoint(x: 100, y: 100)) == nil)   // ungenerated, transparent
        let terrain = MapModel(dimension: dimension, center: .zero)
        #expect(terrain.biome(at: .zero) == nil)
    }
}

@Suite struct CreatureTests {
    let owner = UUID()

    func entity(_ id: String, x: Double, z: Double, extra: [String: NBT] = [:]) -> NBT {
        .compound(["id": .string(id), "Health": .float(10), "Pos": .list([.double(x), .double(64), .double(z)])].merging(extra) { $1 })
    }

    @Test func groupsAndTitles() throws {
        let villager = try #require(Creature(entity("minecraft:villager", x: 0, z: 0, extra: [
            "VillagerData": .compound(["profession": .string("minecraft:librarian"), "level": .int(5)])])))
        let marker = try #require(CreatureMarker(villager, dimension: "minecraft:overworld"))
        #expect(marker.group == .villager && marker.title == "Librarian")
        #expect(CreatureCard.levelName(5) == "Master")
        let pet = Creature(id: "minecraft:cat", x: 1, y: 64, z: 2, customName: "Mittens", owner: owner)
        #expect(CreatureGroup.group(for: pet) == .pet && CreatureMarker(pet, dimension: "d")?.title == "Mittens")
        #expect(CreatureGroup.group(for: Creature(id: "minecraft:sheep", x: 0, y: 0, z: 0)) == nil)
    }

    @Test func sessionScansShowsAndSearchesCreatures() async throws {
        // Scans walk the terrain region files, as entities only exist where terrain does.
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: world) }
        let entities = world.appendingPathComponent("dimensions/minecraft/overworld/entities")
        try FileManager.default.createDirectory(at: entities, withIntermediateDirectories: true)
        let chunk = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list([
            entity("minecraft:wolf", x: 10, z: 20, extra: ["CustomName": .string("Summer"), "Owner": .intArray([1, 2, 3, 4])]),
            entity("minecraft:villager", x: 5, z: 5, extra: ["VillagerData": .compound(["profession": .string("minecraft:farmer")])]),
            entity("minecraft:sheep", x: 1, z: 1),
        ])])
        try Data(TestWorld.regionFile([TestWorld.ChunkSpec(x: 0, z: 0, nbt: chunk)])).write(to: entities.appendingPathComponent("r.0.0.mca"))
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults))
        defer { session.close() }
        await session.map?.waitForCreatures()
        #expect(session.map?.creatures.map(\.group).sorted { $0.rawValue < $1.rawValue } == [.pet, .villager])
        session.shownCreatureGroups = [.pet]
        #expect(session.visibleCreatures.map(\.title) == ["Summer"])
        session.selectedCreature = session.visibleCreatures.first
        #expect(session.selectedCreature?.title == "Summer")
        #expect(session.name(ofPlayerWith: UUID(uuidString: "00000001-0000-0002-0000-000300000004")!).hasPrefix("a player not in this world"))
        session.searchText = "summer"
        await session.waitForIndex()
        #expect(session.searchResults.map(\.detail) == ["“Summer”"])
        #expect(session.searchResults.first?.source == .creature)
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

/// Builds minimal 26.x worlds on disk using MCWorldKit's public NBT and compression API.
enum TestWorld {
    struct ChunkSpec {
        var x: Int, z: Int
        var nbt: NBT
    }

    /// A chunk with one section (y 0–15). `index(x, y, z)` returns a palette index.
    static func chunk(x: Int, z: Int, palette: [String], index: (Int, Int, Int) -> Int) -> ChunkSpec {
        var longs = [UInt64](repeating: 0, count: 256)  // 4 bits × 4096 entries
        for y in 0..<16 { for bz in 0..<16 { for bx in 0..<16 {
            let i = y * 256 + bz * 16 + bx
            longs[i / 16] |= UInt64(index(bx, y, bz)) << UInt64((i % 16) * 4)
        } } }
        let section = NBT.compound([
            "Y": .byte(0),
            "block_states": .compound(["palette": .list(palette.map(NBT.string)),
                                       "data": .longArray(longs.map { Int64(bitPattern: $0) })]),
            "biomes": .compound(["palette": .list([.string("minecraft:plains")])]),
        ])
        return ChunkSpec(x: x, z: z, nbt: .compound([
            "DataVersion": .int(5023), "xPos": .int(Int32(x)), "zPos": .int(Int32(z)), "yPos": .int(0),
            "Status": .string("minecraft:full"), "sections": .list([section]),
        ]))
    }

    static func make(chunks: [ChunkSpec]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldTests-\(UUID().uuidString)")
        let regionDir = root.appendingPathComponent("dimensions/minecraft/overworld/region")
        try FileManager.default.createDirectory(at: regionDir, withIntermediateDirectories: true)
        let level = NBT.compound(["Data": .compound(["LevelName": .string("Test"), "DataVersion": .int(5023)])])
        try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: root.appendingPathComponent("level.dat"))
        for (region, regionChunks) in Dictionary(grouping: chunks, by: { RegionCoordinate(x: $0.x >> 5, z: $0.z >> 5) }) {
            try Data(regionFile(regionChunks)).write(to: regionDir.appendingPathComponent("r.\(region.x).\(region.z).mca"))
        }
        return root
    }

    /// A region file holding chunks of one region, zlib-compressed, one record per sector run.
    static func regionFile(_ chunks: [ChunkSpec]) throws -> [UInt8] {
        var file = [UInt8](repeating: 0, count: 8192)
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        for chunk in chunks {
            let payload = try Compression.deflate(chunk.nbt.serialized())
            var record = be32(payload.count + 1) + [2] + payload
            let sectors = (record.count + 4095) / 4096
            record += [UInt8](repeating: 0, count: sectors * 4096 - record.count)
            let header = 4 * ((chunk.x & 31) + (chunk.z & 31) * 32)
            file.replaceSubrange(header..<header + 4, with: be32((file.count / 4096) << 8 | sectors))
            file += record
        }
        return file
    }
}
