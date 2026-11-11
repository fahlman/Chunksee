import ChunkseeKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ChunkseeTestHost

/// Evidence-only: identical on both products, never included in the shipping PR.
@Suite(.isolatedStores, .serialized) struct BiomeColorComparison {
    struct Configuration: Decodable {
        let world: String
        let game: String
        let output: String
        let expected: String?
        let timing: Bool
        let artworkOrder: [Bool]
        let expectsRetainedTerrain: Bool
    }

    struct Context {
        let names: PlayerNames
        let resources: WorldResources
        let session: WorldSession
        let map: MapModel
    }

    struct Outputs {
        var comparable: [String: Data]
        var raw: [String: Data]
    }

    struct Water: Encodable {
        let x: Int
        let y: Int
        let z: Int
        let depth: Int
        let block: String
        let savedBiome: String
        let numericColor: UInt32
    }

    enum Failure: Error { case configuration, missingWater, mismatch(String) }
    private let region = RegionPosition(x: 0, z: -1)

    @Test(.timeLimit(.minutes(3))) func compare() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHUNKSEE_BIOME_COLOR_COMPARISON"] else {
            throw Failure.configuration
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        try #require(config.artworkOrder == [false, true] || (config.timing && config.artworkOrder == [true, false]))
        try #require(!config.timing || config.expected != nil)
        try #require(Locale.preferredLanguages.first == "en-US")
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let context = try await open(config)
        let gate = AsyncReadGate<Void>()
        var failure: (any Error)?
        var rows: [[String: Any]] = []
        do {
            if config.timing {
                for artwork in config.artworkOrder {
                    context.names.minecraft.usesGameArtwork = artwork
                    await settle(context)
                    try checkConfiguration(context, artwork: artwork)
                    for pass in 0..<6 {
                        try await render(context, artwork: artwork, pass: pass, config: config, rows: &rows)
                    }
                }
            } else {
                try checkConfiguration(context, artwork: false)
                let numeric = try #require(context.resources.biomeColors)
                let water = try await firstWater(in: context, colors: numeric)
                try encoded(water).write(to: output.appendingPathComponent("water.json"))
                try await render(context, artwork: false, pass: 0, config: config, rows: &rows)
                try await transition(context, numeric: numeric, gate: gate, config: config)
                try checkConfiguration(context, artwork: true)
                let completedColors = try #require(context.resources.biomeColors)
                try #require(completedColors.biome(water.savedBiome).color(.water, x: Int32(water.x), z: Int32(water.z))
                    == water.numericColor)
                try await render(context, artwork: true, pass: 0, config: config, rows: &rows)
                // Require a real displayed water column, without mistaking its depth/relief
                // shade for the unshaded numeric color from the saved biome definition.
                for cell in ["off", "on"] {
                    let pixels = try Data(contentsOf: output.appendingPathComponent(cell + "/full.rgba"))
                    let offset = ((water.z + 512) * 512 + water.x) * 4
                    try #require(pixels.indices.contains(offset + 3) && pixels[offset + 3] > 0)
                }
            }
            try #require(rows.count == (config.timing ? 12 : 2))
        } catch {
            failure = error
            try? json(["error": String(reflecting: error), "completedRows": rows.count])
                .write(to: output.appendingPathComponent("failure.json"))
        }
        // Release the exact held read even when a transition assertion failed.
        await gate.releaseAllAndFuture(with: ())
        await close(context)
        try json(["processID": ProcessInfo.processInfo.processIdentifier,
            "language": Locale.preferredLanguages, "locale": Locale.current.identifier,
            "world": config.world, "game": config.game, "region": [region.x, region.z],
            "artworkOrder": config.artworkOrder, "chunkConcurrency": MapModel.defaultConcurrency,
            "worldClosed": context.resources.isClosed, "sessionClosed": context.session.isClosed,
            "backgroundWorkClosed": context.resources.backgroundWork.isClosed,
            "rows": rows.count, "timing": config.timing])
            .write(to: output.appendingPathComponent("completion.json"))
        if let failure { throw failure }
        print("BIOME_COLOR_COMPARISON completed \(rows.count) rows")
    }

    private func open(_ config: Configuration) async throws -> Context {
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in
            throw Failure.configuration
        }))
        names.looksUpOnline = false
        names.minecraft.usesGameArtwork = config.artworkOrder[0]
        names.minecraft.choose(URL(filePath: config.game, directoryHint: .isDirectory))
        var resources: WorldResources?
        var session: WorldSession?
        do {
            let snapshot = try await WorldSnapshot.read(URL(filePath: config.world, directoryHint: .isDirectory))
            let current = try await WorldResources(snapshot: snapshot, names: names,
                savedSearches: SavedSearches(defaults: defaults), defaults: defaults,
                cacheRoot: nil, watchWorld: { _, _ in nil })
            resources = current
            let opened = WorldSession(resources: current, dimensionID: "minecraft:overworld")
            session = opened
            let map = try #require(opened.map)
            map.setStyle(.normal)
            map.setDepth(MapDepth())
            map.setLightingMode(.daylight)
            map.setCastsShadows(false)
            map.setBiomeBlending(false)
            map.setBlockFilter(MapBlockFilter())
            map.setDarkSpots(false)
            try #require(map.availableRegions.contains(region))
            let result = Context(names: names, resources: current, session: opened, map: map)
            await settle(result)
            return result
        } catch {
            session?.close(); resources?.close()
            await session?.waitUntilClosed(); await resources?.waitUntilClosed()
            names.minecraft.forget(); await names.minecraft.waitUntilIdle()
            throw error
        }
    }

    private func settle(_ context: Context) async {
        let session = context.session
        await context.resources.waitForRefresh()
        await context.resources.backgroundWork.waitUntilFinished()
        await session.search.waitForIndex(); await session.search.waitForSearch()
        await context.resources.index.waitForProjection()
        await session.heatMap.waitForReads(); await session.slimeChunks.waitForImages()
        await context.map.waitUntilIdle(); await context.map.waitForRenders()
        await context.map.waitForTopBlocks()
    }

    private func close(_ context: Context) async {
        context.session.close(); context.resources.close()
        await context.session.waitUntilClosed(); await context.resources.waitUntilClosed()
        context.names.minecraft.forget(); await context.names.minecraft.waitUntilIdle()
    }

    private func checkConfiguration(_ context: Context, artwork: Bool) throws {
        let renderer = try requiredRenderer(context.map)
        let colors = try #require(context.resources.biomeColors)
        try #require(renderer.cache == nil && renderer.chunkConcurrency == MapModel.defaultConcurrency)
        try #require(renderer.style == .normal && renderer.cutawayY == nil && !renderer.usesSavedLighting)
        try #require(!renderer.blendsBiomeColors && renderer.darkSpots == nil && renderer.blockFilter == MapBlockFilter())
        try #require(context.map.lightingMode == .daylight && !context.map.castsShadows)
        try #require(renderer.gameData != nil && (renderer.gameArtwork != nil) == artwork)
        try #require(renderer.biomeColors?.sourceKey == colors.sourceKey)
        try #require(context.resources.mapGameResources.biomeColors?.sourceKey == colors.sourceKey)
        try #require(MapContent(session: context.session).biomeColors?.sourceKey == colors.sourceKey)
        try #require(renderer.colorSourceKey == .biomes(colors.sourceKey, blending: nil))
        try #require(colors.source == renderer.gameSource)
    }

    private func transition(_ context: Context, numeric: MapBiomeColors, gate: AsyncReadGate<Void>,
                            config: Configuration) async throws {
        context.resources.readBiomeColors = { world, data, artwork, previous, reload in
            let colors = try await WorldResources.readBiomeColors(world, data: data, artwork: artwork,
                                                                  previous: previous, reload: reload)
            await gate.read("artwork")
            return colors
        }
        context.names.minecraft.usesGameArtwork = true
        await gate.waitForRequest("artwork")
        let pending = try requiredRenderer(context.map)
        let retained = context.resources.biomeColors?.sourceKey
        let outlines = MapContent(session: context.session).biomeColors?.sourceKey
        let drawing = context.resources.mapGameResources.biomeColors?.sourceKey
        try #require(pending.gameArtwork != nil && retained == numeric.sourceKey && outlines == numeric.sourceKey)
        try #require(try !numeric.matchesMetadata(context.resources.world, source: pending.gameSource))
        if config.expectsRetainedTerrain {
            try #require(drawing == numeric.sourceKey && pending.biomeColors?.sourceKey == numeric.sourceKey)
            try #require(pending.colorSourceKey == .biomes(numeric.sourceKey, blending: nil))
        } else {
            try #require(drawing == nil && pending.biomeColors == nil)
            let data = try #require(pending.gameData)
            try #require(pending.colorSourceKey == .game(data.sourceKey))
        }
        var record: [String: Any] = ["expectsRetainedTerrain": config.expectsRetainedTerrain,
            "numeric": try object(numeric.sourceKey), "world": try optionalObject(retained),
            "outlines": try optionalObject(outlines), "drawing": try optionalObject(drawing),
            "terrain": try optionalObject(pending.biomeColors?.sourceKey),
            "terrainColorSource": try optionalObject(pending.colorSourceKey),
            "freshArtworkReadEntered": true]
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        try json(record).write(to: output.appendingPathComponent("transition-pending.json"))
        await gate.releaseAllAndFuture(with: ())
        await settle(context)
        let complete = try requiredRenderer(context.map)
        let colors = try #require(complete.biomeColors)
        try #require(colors.sourceKey != numeric.sourceKey && colors.source == complete.gameSource)
        try #require(complete.colorSourceKey != pending.colorSourceKey)
        try #require(MapContent(session: context.session).biomeColors?.sourceKey == colors.sourceKey)
        record["complete"] = try object(colors.sourceKey)
        record["completeTerrainColorSource"] = try optionalObject(complete.colorSourceKey)
        record["distinctCompleteKey"] = true
        try json(record).write(to: output.appendingPathComponent("transition-complete.json"))
    }

    private func firstWater(in context: Context, colors: MapBiomeColors) async throws -> Water {
        let renderer = try requiredRenderer(context.map)
        let file = try #require(try renderer.dimension.region(x: region.x, z: region.z))
        for position in file.chunkCoordinates.sorted(by: { ($0.localZ, $0.localX) < ($1.localZ, $1.localX) }) {
            try Task.checkCancellation()
            guard let columns = try await renderer.topBlocks(in: file, localX: position.localX, localZ: position.localZ),
                  let index = columns.firstIndex(where: { ($0?.waterDepth ?? 0) > 0 }), let water = columns[index] else { continue }
            let x = region.x * 512 + position.localX * 16 + index % 16
            let z = region.z * 512 + position.localZ * 16 + index / 16
            let nbt = try #require(try file.chunkNBT(localX: position.localX, localZ: position.localZ,
                                                   skipping: Chunk.keysNotNeededForBiomes))
            let chunk = try Chunk(nbt: nbt)
            let biome = try #require(chunk.biomeSnapshot.biome(x: x, y: water.y, z: z))
            let color = try #require(colors.biome(biome).color(.water, x: Int32(x), z: Int32(z)))
            return Water(x: x, y: water.y, z: z, depth: water.waterDepth, block: water.id,
                         savedBiome: biome, numericColor: color)
        }
        throw Failure.missingWater
    }

    private func render(_ context: Context, artwork: Bool, pass: Int, config: Configuration,
                        rows: inout [[String: Any]]) async throws {
        let cell = artwork ? "on" : "off"
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        // The real resources-to-renderer projection belongs inside the measured interval.
        let beforeCPU = config.timing ? cpu() : 0
        let beforeWall = config.timing ? DispatchTime.now().uptimeNanoseconds : 0
        let renderer = try requiredRenderer(context.map)
        let tile = try #require(try await renderer.tile(for: region))
        let wall = config.timing ? Double(DispatchTime.now().uptimeNanoseconds - beforeWall) / 1e9 : 0
        let usedCPU = config.timing ? cpu() - beforeCPU : 0
        var row: [String: Any] = ["cell": cell, "pass": pass,
            "phase": config.timing ? (pass < 2 ? "warmup" : "measured") : "proof"]
        if config.timing { row["wallSeconds"] = wall; row["cpuSeconds"] = usedCPU }
        do {
            let outputs = try outputs(tile, renderer: renderer)
            let expected = config.expected.map { URL(filePath: $0, directoryHint: .isDirectory).appendingPathComponent(cell) }
            let comparison = try compare(outputs.comparable, with: expected)
            row["comparison"] = comparison
            row["hashes"] = outputs.comparable.mapValues(hash)
            if !config.timing || comparison["matches"] as? Bool != true {
                let folder = output.appendingPathComponent(config.timing ? "mismatch-\(cell)-\(pass)" : cell)
                try write(outputs.comparable.merging(outputs.raw) { value, _ in value }, to: folder)
            }
            if comparison["matches"] as? Bool != true { throw Failure.mismatch(cell) }
        } catch {
            row["error"] = String(reflecting: error)
            rows.append(row)
            try json(rows).write(to: output.appendingPathComponent("records.json"))
            throw error
        }
        rows.append(row)
        try json(rows).write(to: output.appendingPathComponent("records.json"))
    }

    private func outputs(_ tile: RegionTileRenderer.RenderedTile, renderer: RegionTileRenderer) throws -> Outputs {
        try #require(tile.cacheWrite == nil && tile.key.chunk == nil && renderer.accepts(tile.key))
        try #require(tile.full.image.width == 512 && tile.full.image.height == 512)
        try #require(tile.preview.image.width == 256 && tile.preview.image.height == 256)
        var files: [String: Data] = [:], raw: [String: Data] = [:], images: [String: Any] = [:]
        for (name, image) in [("full", Optional(tile.full.image)), ("preview", Optional(tile.preview.image)),
                              ("full-normal", tile.full.normals), ("preview-normal", tile.preview.normals)] {
            guard let image else { images[name] = NSNull(); continue }
            let bytes = try pixels(image)
            files[name + ".rgba"] = bytes
            images[name] = ["width": image.width, "height": image.height,
                "bitsPerComponent": image.bitsPerComponent, "bitmapInfo": image.bitmapInfo.rawValue,
                "colorSpace": (image.colorSpace?.name).map { $0 as String } as Any? ?? NSNull()]
        }
        let full = try #require(files["full.rgba"])
        try #require(stride(from: 3, to: full.count, by: 4).contains { full[$0] > 0 })
        if let heights = tile.heights { files["heights.i32le"] = integers(heights) }
        if let surface = tile.detail {
            let bytes = try #require(surface.detail.encoded())
            try #require(MapSurfaceDetail.decoded(bytes) == surface.detail)
            // A binary plist's dictionary/object order is not a semantic output. Preserve
            // its bytes, and compare the complete decoded payload with sorted JSON keys.
            let stored: Any = bytes.isEmpty ? [:] : try PropertyListSerialization.propertyList(from: bytes, format: nil)
            files["detail.json"] = try json(canonical(stored))
            raw["detail-original.plist"] = bytes
            files["detail-heights.i32le"] = integers(surface.heights)
            if let night = surface.nightLight { files["detail-night.u8"] = Data(night) }
        }
        files["structure.json"] = try json([
            "surfaceKey": try object(tile.key.surface), "inputs": try object(renderer.cacheInputs),
            "heightScale": try optionalObject(tile.key.preparation.heightScale),
            "usesSavedLighting": tile.key.preparation.usesSavedLighting, "chunk": NSNull(),
            "chunkConcurrency": renderer.chunkConcurrency, "images": images,
            "hasHeights": tile.heights != nil, "hasDetail": tile.detail != nil,
            "hasDetailNightLight": tile.detail?.nightLight != nil,
        ])
        return Outputs(comparable: files, raw: raw)
    }

    private func compare(_ actual: [String: Data], with folder: URL?) throws -> [String: Any] {
        guard let folder else { return ["matches": true, "oracle": "baseline proof", "maximumRGBDifference": 0, "differingRGBBytes": 0] }
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "detail-original.plist" }
        let expected = Dictionary(uniqueKeysWithValues: try entries.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        var matches = Set(actual.keys) == Set(expected.keys)
        var largest = 0, differences = 0
        for (name, bytes) in actual {
            guard let reference = expected[name], bytes.count == reference.count else { matches = false; continue }
            if name.hasSuffix(".rgba") {
                for (offset, pair) in zip(bytes, reference).enumerated() {
                    let difference = abs(Int(pair.0) - Int(pair.1))
                    if offset % 4 == 3 { matches = matches && difference == 0 }
                    else {
                        largest = max(largest, difference)
                        if difference != 0 { differences += 1 }
                    }
                }
                matches = matches && largest <= 1
            } else { matches = matches && bytes == reference }
        }
        return ["matches": matches, "oracle": "baseline proof", "maximumRGBDifference": largest, "differingRGBBytes": differences]
    }

    private func pixels(_ image: CGImage) throws -> Data {
        try #require(image.bitsPerPixel == 32 && image.bitsPerComponent == 8)
        try #require(image.alphaInfo == .premultipliedLast || image.alphaInfo == .last)
        let source = try #require(image.dataProvider?.data) as Data
        try #require(source.count >= image.bytesPerRow * image.height)
        var result = Data(capacity: image.width * image.height * 4)
        for row in 0..<image.height {
            result.append(source[(row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width * 4)])
        }
        return result
    }

    private func integers(_ values: [Int32]) -> Data { values.map(\.littleEndian).withUnsafeBytes { Data($0) } }
    private func canonical(_ value: Any) -> Any {
        if let data = value as? Data { return ["$data": data.base64EncodedString()] }
        if let array = value as? [Any] { return array.map(canonical) }
        if let object = value as? [String: Any] { return object.mapValues(canonical) }
        return value
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoded(value), options: [.fragmentsAllowed])
    }
    private func optionalObject<T: Encodable>(_ value: T?) throws -> Any { try value.map(object) ?? NSNull() }
    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    private func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func write(_ files: [String: Data], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting) }
    }
    private func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
