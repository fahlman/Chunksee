import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapSurfaceContextTests {
    @Test func viewContextFollowsSavedTypesAndGeneratorsInsteadOfDimensionNames() throws {
        let definitions: [String: NBT] = [
            "minecraft:overworld": definition(type: .string("minecraft:the_nether"), noise: .string("minecraft:nether")),
            "minecraft:the_nether": definition(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld")),
            "example:offset": definition(type: ceilingType, noise: noise(minY: -64, height: 128)),
        ]
        let details = try details(definitions)
        let roof = MapSurfaceContext(settings: details.dimensionSettings["minecraft:overworld"])
        #expect(roof.buildHeight == 256 && roof.ceilingY == 127 && roof.biomeSampleY == 64)
        let open = MapSurfaceContext(settings: details.dimensionSettings["minecraft:the_nether"])
        #expect(open.buildHeight == 384 && open.ceilingY == nil && open.biomeSampleY == nil)
        let offset = MapSurfaceContext(settings: details.dimensionSettings["example:offset"])
        #expect(offset.buildHeight == 256 && offset.ceilingY == 63 && offset.biomeSampleY == 0)
        let options = RegionReader.options(context: offset)
        #expect(options.height == 256 && options.biomeSampleY == 0)
    }

    @Test func unknownOrEmptyGenerationKeepsSurfaceWithAnyKnownBuildHeight() throws {
        let definitions: [String: NBT] = [
            "example:missing": .compound(["type": ceilingType]),
            "example:unknown": definition(type: ceilingType, noise: .string("example:unavailable")),
            "example:empty": definition(type: ceilingType, noise: noise(minY: 0, height: 0)),
            "example:flat": .compound(["type": ceilingType, "generator": .compound([
                "type": .string("minecraft:flat"), "settings": noise(minY: 0, height: 128),
            ])]),
            "example:no_type": definition(type: .string("example:unavailable"), noise: .string("minecraft:nether")),
        ]
        let details = try details(definitions)
        for id in definitions.keys {
            let context = MapSurfaceContext(settings: details.dimensionSettings[id])
            #expect(context.ceilingY == nil && context.biomeSampleY == nil)
            #expect(context.buildHeight == (id == "example:no_type" ? nil : 256))
        }
        #expect(MapSurfaceContext.unknown.buildHeight == nil)
        #expect(RegionReader.options().biomeSampleY == nil && RegionReader.options().height == nil)
    }

    @Test func surfaceRuleHeightIsNotTheLogicalHeightOrAnIntersection() throws {
        let details = try details([
            "example:shifted": definition(type: ceilingType, noise: noise(minY: 64, height: 128)),
        ])
        let context = MapSurfaceContext(settings: details.dimensionSettings["example:shifted"])
        // WorldGenerationContext uses max(minimums) and min(heights): 64..<192. Intersecting
        // build bounds instead would end at 128, while logical_height would supply only 64.
        #expect(context.ceilingY == 191 && context.biomeSampleY == 128 && context.buildHeight == 256)
    }

    private var ceilingType: NBT {
        .compound(["min_y": .int(-128), "height": .int(256), "logical_height": .int(64), "has_ceiling": .byte(1)])
    }

    private func noise(minY: Int32, height: Int32) -> NBT {
        .compound(["noise": .compound(["min_y": .int(minY), "height": .int(height)])])
    }

    private func definition(type: NBT, noise: NBT) -> NBT {
        .compound(["type": type, "generator": .compound(["type": .string("minecraft:noise"), "settings": noise])])
    }

    private func details(_ definitions: [String: NBT]) throws -> WorldDetails {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "DataVersion": .int(Int32(SaveVersion.java26_3)),
            "DataPacks": .compound(["Enabled": .list([.string("vanilla")])]),
        ])]), to: url.appendingPathComponent("level.dat"))
        try Fixtures.writeGzippedNBT(.compound([
            "DataVersion": .int(Int32(SaveVersion.java26_3)), "data": .compound(["dimensions": .compound(definitions)]),
        ]), to: url.appendingPathComponent("data/minecraft/world_gen_settings.dat"))
        return WorldDetails.read(try World(contentsOf: url))
    }
}
