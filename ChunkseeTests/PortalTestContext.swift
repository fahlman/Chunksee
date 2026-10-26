import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

/// Synthetic saved scales and borders, read through the same public Kit API as the app.
nonisolated struct PortalTestContext {
    let types: [String: DimensionType]
    let borders: [String: WorldBorder]

    static var dimensions: [String: NBT] {
        Dictionary(uniqueKeysWithValues: [(NetherPortal.overworld, 1.0), (NetherPortal.nether, 8.0)].map { id, scale in
            (id, .compound(["type": .compound([
                "min_y": .int(0), "height": .int(256), "logical_height": .int(256),
                "has_ceiling": .byte(0), "coordinate_scale": .double(scale)
            ])]))
        })
    }

    init() throws {
        let url = try TestWorld.make(chunks: [], dimensionSettings: Self.dimensions)
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeBorder(to: url)
        let world = try World(contentsOf: url)
        types = try world.dimensionTypes(assets: nil)
        let dimension = try #require(world.dimension(NetherPortal.overworld))
        let border = try #require(try world.worldBorder(of: dimension))
        borders = [NetherPortal.overworld: border, NetherPortal.nether: border]
    }

    /// This helper is used only by fixtures whose level contains the same minimal metadata.
    static func writeBorder(to url: URL) throws {
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string("Test"), "DataVersion": .int(5023),
            "BorderSize": .double(59_999_968),
            "DataPacks": .compound(["Enabled": .list([.string("vanilla")])])
        ])]), to: url.appendingPathComponent("level.dat"))
    }
}
