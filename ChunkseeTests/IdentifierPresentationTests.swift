import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct IdentifierPresentationTests {
    @Test(arguments: ["minecraft:", "", ":"])
    func defaultNamespaceUsesTheSameNamesAndGroups(prefix: String) throws {
        #expect(ReadableName.from(prefix + "diamond_sword") == "Diamond Sword")
        #expect(ItemAppearance.symbol(for: prefix + "diamond_sword") == ItemAppearance.symbol(for: "minecraft:diamond_sword"))
        #expect(PlayerRecords.travelName(prefix + "aviate_one_cm", gameNames: .unavailable) == "Aviate One Cm")
        #expect(WorldDetails.readableRule(prefix + "keep_inventory") == "Keep Inventory")
        #expect(PetDetailText.name(prefix + "red_blue") == "Red Blue")
        #expect(try StructureTagFixture.catalog().group(for: prefix + "village_plains") == .village)
        let bed = PlaceMarker(PointOfInterest(type: prefix + "home", x: 1, y: 64, z: 2, freeTickets: 0))
        #expect(bed.group == .bed && bed.name == "Villager’s Bed")
    }

    @Test func customAndUnfamiliarNamesStayVisibleWithoutBecomingVanillaGroups() {
        #expect(ReadableName.from("mod:deep_caves") == "Deep Caves")
        #expect(StructureGroup.Catalog(tags: [:]).group(for: "mod:village_plains") == .other)
        #expect(PlaceGroup.group(for: "mod:home") == .other)
        #expect(BlockColors.color(for: "mod:air") != nil)
        #expect(!BlockColors.isWater("mod:water"))
        #expect(ReadableName.from("mod:minecraft:home") == "Mod:minecraft:home")
        #expect(ReadableName.from("minecraft:") == "Minecraft:")
        #expect(WorldDetails.readableRule("doDaylightCycle") == "Do Daylight Cycle")
    }

    @Test(arguments: ["minecraft:", "", ":"])
    func renderedWaterAndHoverUseTheSamePaletteMeaning(prefix: String) throws {
        let spec = TestWorld.chunk(x: 0, z: 0, palette: [prefix + "air", prefix + "stone", prefix + "water"]) { _, y, _ in
            y == 0 ? 1 : y <= 3 ? 2 : 0
        }
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let file = try RegionFile(contentsOf: dimension.regionURL(x: 0, z: 0))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0))
        #expect(blocks.compactMap { $0 }.allSatisfy { $0.y == 3 && $0.waterDepth == 3 })
        #expect(columns.compactMap { $0 }.allSatisfy { $0.y == 3 && $0.waterDepth == 3 })
        let first = try #require(blocks.first.flatMap { $0 })
        #expect(MapView.describe(first) == "Water, 3 deep")
        #expect(BlockColors.isWater(prefix + "bubble_column"))
    }

    @Test func oldTileCacheCannotHideDefaultNamespaceAir() async throws {
        let spec = TestWorld.chunk(x: 0, z: 0, palette: [":air", ":gold_block"]) { _, y, _ in y == 0 ? 1 : 0 }
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let cache = TileCache(directory: world.appendingPathComponent("tile-cache"))
        let key = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(x: 0, z: 0)))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let oldFile = cache.directory.appendingPathComponent("r.0.0.surface.\(key.fileSize).\(key.modified).v7.lzfse")
        let stale = Data(repeating: 0, count: RegionTileRenderer.side * RegionTileRenderer.side * 4)
        try ((stale as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)
        let tile = try #require(try await RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false).tile(for: region))
        let pixels = try #require(tile.full.image.dataProvider?.data as Data?)
        let offset = (RegionTileRenderer.side + 1) * 4
        let gold = try #require(BlockColors.color(for: "minecraft:gold_block"))
        #expect(Array(pixels[offset..<offset + 4]) == [gold.red, gold.green, gold.blue, 255])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }

    @Test func oldStructureCacheIsReclassifiedByTheSharedIdentifierParser() async throws {
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var fields = try #require(spec.nbt.compound)
        fields["structures"] = .compound(["starts": .compound([":village_plains": .compound([
            "id": .string(":village_plains"), "ChunkX": .int(0), "ChunkZ": .int(0),
            "Children": .list([.compound(["id": .string("minecraft:jigsaw"), "BB": .intArray([0, 60, 0, 9, 70, 9])])]),
        ])])])
        spec.nbt = .compound(fields)
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let cache = ScanCache(directory: world.appendingPathComponent("scan-cache"))
        let fingerprint = ScanCache.fingerprint([dimension.regionURL(x: 0, z: 0), dimension.regionURL(.entities, x: 0, z: 0)])
        var stale = StructureMarker(try #require(StructureStart.starts(inChunk: spec.nbt).first))
        stale.group = .other
        let oldFile = try #require(cache.directory).appendingPathComponent("structures.0.0.\(fingerprint).v16")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode([stale])
        try ((data as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)
        let groups = try StructureTagFixture.catalog()
        let markers = await TestWorld.index(RegionReader(dimension: dimension, cache: cache, structureGroups: groups)).structures
        #expect(markers.count == 1 && markers.first?.group == .village && markers.first?.name == "Village Plains")
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }
}
