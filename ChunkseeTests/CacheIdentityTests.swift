import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

extension TileCache {
    /// Disk-format fixtures use explicit Normal inputs. Style and game-source behavior
    /// must be checked through RegionTileRenderer.cacheKey, which owns those decisions.
    nonisolated static func key(for region: RegionPosition, regionFile: URL, context: MapSurfaceContext = .unknown,
                    cutawayY: Int? = nil, blockFilter: MapBlockFilter = MapBlockFilter(),
                    darkSpots: DarkSpots? = nil) -> Key? {
        key(for: region, regionFile: regionFile,
            inputs: Inputs(context: context, cutawayY: cutawayY, style: .normal,
                           assets: GameAssets.interpretationVersion, heightScale: nil,
                           blockFilter: blockFilter, colorSource: nil, gameSource: .unavailable,
                           samplesNeighborBiomes: false, darkSpots: darkSpots), biomeFiles: nil)
    }
}

extension ScanCache {
    /// Fixtures for the retired cache format retain its original on-disk spelling.
    nonisolated static func legacyFingerprint(_ sources: [URL]) -> String {
        CacheKey.hash(sources.map { url in
            CacheKey.fileStamp(for: url).map { "\($0.size):\($0.modified);" } ?? "-;"
        }.joined())
    }
}

extension RegionTileRenderer {
    /// Controlled asynchronous results retain the source and choices of their actual request.
    nonisolated func fixtureTile(_ image: CGImage, for region: RegionPosition) throws -> RenderedTile {
        let key = ImageKey(surface: try #require(cacheKey(for: region)), preparation: preparation, chunk: nil)
        return RenderedTile(key: key, full: image, preview: image)
    }
}

@Suite(.isolatedStores) struct CacheIdentityTests {
    private func world() throws -> URL {
        try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 7 ? 1 : 0 }])
    }

    private func changing(_ version: InterpretationVersion, field: String) throws -> InterpretationVersion {
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as? [String: Any])
        switch field {
        case "revision": value[field] = version.revision + 1
        case "generatedFacts": value[field] = "changed-generated-facts"
        default:
            var dependencies = try #require(value[field] as? [[String: Any]])
            dependencies.append(["domain": "fixture", "revision": 1, "generatedFacts": "fixture", "dependencies": []])
            value[field] = dependencies
        }
        return try JSONDecoder().decode(InterpretationVersion.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func wholeReaderContractsRejectOldDiskEntriesWhileAnUnchangedReopenHits() throws {
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let renderer = RegionTileRenderer(dimension: dimension, darkSpots: DarkSpots(rule: nil))
        let key = try #require(renderer.cacheKey(for: .init(x: 0, z: 0)))
        let cache = TileCache(directory: root.appendingPathComponent("tiles"))
        let canvas = RegionTileRenderer.Canvas(nightLight: Array(repeating: DarkSpots.Status.unknown.rawValue, count: 512 * 512))
        cache.store(canvas, for: key)
        let reopened = TileCache(directory: cache.directory)
        #expect(reopened.load(try #require(renderer.cacheKey(for: key.region)))?.pixels == canvas.pixels)
        for field in ["revision", "generatedFacts", "dependencies"] {
            for owner in ["terrain", "assets", "light"] {
                var changed = key
                switch owner {
                case "terrain": changed.inputs.terrain = try changing(key.inputs.terrain, field: field)
                case "assets": changed.inputs.assets = try changing(#require(key.inputs.assets), field: field)
                default:
                    var light = try #require(key.inputs.nightLight)
                    light.interpretation = try changing(light.interpretation, field: field)
                    changed.inputs.nightLight = light
                }
                #expect(changed.fileName != key.fileName)
                #expect(reopened.load(changed) == nil)
                #expect(reopened.load(key) != nil)
            }
        }
    }

    @Test func uncachedRenderingCarriesItsSourceAndHasFixedFullPreviewAndNormalPixels() async throws {
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        var renderer = RegionTileRenderer(dimension: dimension)
        let region = RegionPosition(x: 0, z: 0)
        let ordinary = try #require(try await renderer.tile(for: region))
        renderer.usesSavedLighting = true
        let prepared = try #require(try await renderer.tile(for: region))
        #expect(renderer.cache == nil && ordinary.cacheWrite == nil && prepared.cacheWrite == nil)
        #expect(ordinary.key.surface == prepared.key.surface && ordinary.key != prepared.key)
        #expect(ordinary.key.surface.inputs.terrain == Chunk.interpretationVersion)
        #expect(ordinary.key.surface.inputs.assets == GameAssets.interpretationVersion)
        #expect(ordinary.key.surface.inputs.renderer == TileCache.rendererVersion)
        #expect(!renderer.accepts(ordinary.key) && renderer.accepts(prepared.key))
        // Fixed output, not recomputed through the palette or shading implementation. A
        // changed golden needs review of both the app and Kit interpretation contracts.
        func plane(side: Int, extent: Int, color: [UInt8]) -> Data {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            for z in 0..<extent {
                for x in 0..<extent { bytes.replaceSubrange((z * side + x) * 4..<(z * side + x + 1) * 4, with: color) }
            }
            return Data(bytes)
        }
        let full = plane(side: 512, extent: 16, color: [125, 125, 125, 255])
        let preview = plane(side: 256, extent: 8, color: [125, 125, 125, 255])
        for tile in [ordinary, prepared] {
            #expect(tile.full.image.dataProvider?.data as Data? == full)
            #expect(tile.preview.image.dataProvider?.data as Data? == preview)
        }
        #expect(ordinary.full.normals == nil)
        #expect(prepared.full.normals?.dataProvider?.data as Data? == plane(side: 512, extent: 16, color: [128, 255, 128, 255]))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func incompatibleBackgroundResultsNeverPublishOrStartCacheWrites(preparationChanged: Bool) async throws {
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let oldTerrain = try changing(Chunk.interpretationVersion, field: "generatedFacts")
        let directory = root.appendingPathComponent("tiles")
        let map = MapModel(definitions: { .unknown }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8),
            cacheDirectory: directory, writeCache: { _ in Issue.record("Incompatible pixels started a cache write") },
            renderTile: { renderer, region in
                guard let tile = try await renderer.tile(for: region) else { return nil }
                var surface = tile.key.surface
                if !preparationChanged { surface.inputs.terrain = oldTerrain }
                let preparation = preparationChanged
                    ? RegionTileRenderer.Preparation(heightScale: renderer.heightScale, usesSavedLighting: true)
                    : tile.key.preparation
                return .init(key: .init(surface: surface, preparation: preparation, chunk: nil),
                             full: tile.full, preview: tile.preview, cacheWrite: tile.cacheWrite,
                             detail: tile.detail, heights: tile.heights)
            })
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.tiles.isEmpty && map.previews.isEmpty && map.detailImages.isEmpty)
        #expect(map.unfinishedCacheWrites == 0 && !FileManager.default.fileExists(atPath: directory.path))
        map.close(); await map.waitForRenders()
    }

    @Test func scanIdentitiesIgnoreEnchantmentDefinitionsAndKeepReaderContractInvalidation() throws {
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let neutral = try #require(EnchantmentDefinition(data: Data(#"{"slots":["head"],"effects":{}}"#.utf8)))
        let health = try #require(EnchantmentDefinition(data: Data(#"{"slots":["head"],"effects":{"minecraft:attributes":[{"id":"test:health","attribute":"minecraft:max_health","amount":4,"operation":"add_value"}]}}"#.utf8)))
        var definitions = WorldDefinitions(enchantments: Dictionary(uniqueKeysWithValues: [("test:a", neutral), ("test:b", health)]))
        var first = RegionReader.options(definitions: definitions)
        first.blockIDs = Set(["minecraft:stone", "minecraft:dirt"])
        definitions.enchantments = Dictionary(uniqueKeysWithValues: [("test:b", health), ("test:a", neutral)])
        var reordered = RegionReader.options(definitions: definitions)
        reordered.blockIDs = Set(["minecraft:dirt", "minecraft:stone"])
        let region = RegionPosition(x: 0, z: 0)
        let key = ScanCache.Key(dimension: dimension, region: region, options: .init(first))
        let otherOrder = ScanCache.Key(dimension: dimension, region: region, options: .init(reordered))
        #expect(try InterpretationKey.identity(of: key) == InterpretationKey.identity(of: otherOrder))
        let cache = ScanCache(directory: root.appendingPathComponent("scans"))
        cache.store(try dimension.scan(region: region, options: first), key: key)
        #expect(ScanCache(directory: cache.directory).load(otherOrder)?.options == first)
        definitions.enchantments["test:a"] = health
        var newDefinitions = RegionReader.options(definitions: definitions)
        newDefinitions.blockIDs = first.blockIDs
        let sameKey = ScanCache.Key(dimension: dimension, region: region, options: .init(newDefinitions))
        #expect(sameKey == key && cache.load(sameKey)?.options == first)
        var changed = first
        changed.height = 384
        #expect(cache.load(.init(dimension: dimension, region: region, options: .init(changed))) == nil)
        for field in ["revision", "generatedFacts", "dependencies"] {
            var changed = key
            changed.interpretation = try changing(key.interpretation, field: field)
            #expect(cache.load(changed) == nil)
        }
        #expect(cache.load(key) != nil)
        let changedKey = ScanCache.Key(dimension: dimension, region: region, options: .init(changed))
        cache.store(try dimension.scan(region: region, options: changed), key: changedKey)
        #expect(cache.load(changedKey)?.options == changed && cache.load(key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: #require(cache.directory).path).count == 1)
    }

    @Test func savedMapPicturesUseCompleteContentAndReuseOnlyMatchingPublications() throws {
        let map = try #require(MapItem(id: 7, nbt: .compound([
            "dimension": .string("minecraft:overworld"),
            "colors": .byteArray(Array(repeating: 50, count: 128 * 128))
        ])))
        var cache = InGameMapImage.Cache()
        let first = InGameMapImage.Source(map)
        let firstImage = cache.image(for: first)
        let image = try #require(firstImage)
        let reused = cache.image(for: InGameMapImage.Source(map))
        #expect(reused === image)
        var changed = map
        changed.colors[0] = 18
        let next = InGameMapImage.Source(changed)
        #expect(next.key != first.key)
        let nextImage = cache.image(for: next)
        let replacement = try #require(nextImage)
        #expect(replacement !== image && replacement.dataProvider?.data as Data? != image.dataProvider?.data as Data?)
        let reusedReplacement = cache.image(for: next)
        #expect(reusedReplacement === replacement)
        changed.centerX += 1
        #expect(InGameMapImage.Source(changed).key != next.key)
    }
}
