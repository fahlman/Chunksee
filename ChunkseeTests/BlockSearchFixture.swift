import ChunkseeIndex
import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

extension NotableBlock {
    /// Fixture identity only; production groups come from the composed root tag.
    nonisolated static var diamond: Self { .tag("minecraft:diamond_ores") }
}

nonisolated enum BlockSearchFixture {
    static func chunk(x: Int, z: Int = 0, count: Int, sectionY: Int = 0,
                      block: String = "minecraft:diamond_ore") -> TestWorld.ChunkSpec {
        let section = Fixtures.section(y: sectionY, palette: [.string("minecraft:stone"), .string(block)],
            indices: (0..<4096).map { $0 < count ? 1 : 0 })
        return .init(x: x, z: z, nbt: Fixtures.chunk(x: x, z: z, sections: [section]))
    }

    static func input(_ chunks: [TestWorld.ChunkSpec], x: Double = 8, z: Double = 8) throws -> BlockQueryInput {
        let root = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try World(contentsOf: root)
        let dimension = try #require(world.dimension("minecraft:overworld"))
        let catalog = try WorldDefinitions.read(world, assets: nil).notableBlocks
        let regions = Set(dimension.regionFiles().map { RegionPosition(x: $0.x, z: $0.z) })
        let counts = try regions.map { try dimension.countBlocks(region: $0, matching: catalog.blockIDs) }
        let index = BlockCountIndex(dimension: dimension.id).updating(available: regions, replacements: counts)
        return BlockQueryInput(counts: BlockCountSnapshot(dimensions: [dimension.id: index]), catalog: catalog,
            point: .init(dimension: dimension.id, origin: try #require(BlockSearchOrigin(x: x, z: z))))
    }
}
