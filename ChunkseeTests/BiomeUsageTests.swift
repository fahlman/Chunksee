import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite(.timeLimit(.minutes(1))) struct BiomeUsageTests {
    private final class Fixture {
        let url: URL
        var readers: [RegionReader] = []

        init(version: Int, used: Int? = nil) throws {
            var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            var data = try #require(chunk.nbt.compound)
            var section = try #require(data["sections"]?.list?.first?.compound)
            // Independently pack three biome IDs into two bits per cell. Only the final cell
            // uses `used`; all others are plains. The surface sample stays plains.
            let cells = version >= 5119 ? 4096 : 64
            var words = [UInt64](repeating: 0, count: cells / 32)
            if let used { words[(cells - 1) / 32] = UInt64(used) << UInt64(((cells - 1) % 32) * 2) }
            section["biomes"] = .compound([
                "palette": .list([.string("minecraft:plains"), .string("minecraft:lush_caves"), .string("minecraft:deep_dark")]),
                "data": .longArray(words.map { Int64(bitPattern: $0) }),
            ])
            data["sections"] = .list([.compound(section)])
            data["DataVersion"] = .int(Int32(version))
            chunk.nbt = .compound(data)
            url = try TestWorld.make(chunks: [chunk])
        }

        func dimension() throws -> ChunkseeKit.Dimension { try #require(try World(contentsOf: url).dimension("overworld")) }
        func reader() throws -> RegionReader {
            let reader = RegionReader(dimension: try dimension(), cache: .off)
            readers.append(reader)
            return reader
        }
        func close() async {
            for reader in readers { await reader.close() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(version: Int, used: Int? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(version: version, used: used)
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func unusedPaletteEntriesDoNotCreateCaveAreas() async throws {
        for version in [5023, 5119] {
            try await withFixture(version: version) { f in
                let scan = await BiomeScanner.scan(try f.reader())
                #expect(scan.biomes[ChunkCoordinate(x: 0, z: 0)] == "minecraft:plains")
                #expect(scan.caveBiomes.isEmpty)
                #expect(scan.areas.filter { BiomeScanner.caveBiomeIDs.contains($0.group.id) }.isEmpty)
            }
        }
    }

    @Test func everyActuallyUsedCaveCellKeepsItsAreaAndCatalogEntry() async throws {
        for version in [5023, 5119] {
            for used in [1, 2] {
                try await withFixture(version: version, used: used) { f in
                    let scan = await BiomeScanner.scan(try f.reader())
                    let expected = used == 1 ? "minecraft:lush_caves" : "minecraft:deep_dark"
                    #expect(scan.caveBiomes[ChunkCoordinate(x: 0, z: 0)] == [expected])
                    let areas = scan.areas.filter { BiomeScanner.caveBiomeIDs.contains($0.group.id) }
                    #expect(areas.count == 1 && areas.first?.group.id == expected && areas.first?.chunkCount == 1)
                    let catalog = try f.dimension().vanillaBiomes
                    #expect(catalog.contains("minecraft:lush_caves") && catalog.contains("minecraft:deep_dark"))
                }
            }
        }
    }

    @Test func versionElevenCaveMembershipIsRereadInsteadOfRestored() async throws {
        try await withFixture(version: 5023) { f in
            let dimension = try f.dimension(), region = RegionCoordinate(x: 0, z: 0)
            let cache = ScanCache(directory: f.url.appendingPathComponent("test-cache"))
            let sources = [dimension.regionDirectory.appendingPathComponent("r.0.0.mca"), dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca")]
            let fingerprint = ScanCache.fingerprint(sources)
            let stale = [ChunkCoordinate(x: 0, z: 0): ["minecraft:lush_caves", "minecraft:deep_dark"]]
            cache.store(stale, "caveBiomes", region: region, fingerprint: fingerprint)
            let loaded: [ChunkCoordinate: [String]]? = cache.load("caveBiomes", region: region, fingerprint: fingerprint)
            #expect(loaded == stale)
            let directory = try #require(cache.directory)
            let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            let historical = directory.appendingPathComponent(file.lastPathComponent.components(separatedBy: ".v")[0] + ".v11")
            if file != historical { try FileManager.default.moveItem(at: file, to: historical) }
            let count = ReadCount()
            let reader = RegionReader(dimension: dimension, cache: cache, read: { dimension, region in
                await count.note()
                return await RegionData.read(dimension, region: region)
            })
            f.readers.append(reader)
            #expect(await reader.caveBiomes(region).isEmpty)
            #expect(await count.value == 1)
        }
    }

    private actor ReadCount {
        private(set) var value = 0
        func note() { value += 1 }
    }
}
