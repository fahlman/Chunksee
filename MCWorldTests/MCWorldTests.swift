import CoreGraphics
import Foundation
import MCWorldKit
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
    private static func regionFile(_ chunks: [ChunkSpec]) throws -> [UInt8] {
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
