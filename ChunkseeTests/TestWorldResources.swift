import Foundation

/// Small synthetic pack for app scenarios. Tests that need absent/invalid resources override
/// the enabled-pack list or these files explicitly; no installed game files are required.
nonisolated enum TestWorldResources {
    static let pack = "file/ChunkseeTest"

    static func write(to root: URL) throws {
        let files: [String: Any] = [
            "pack.mcmeta": ["pack": ["min_format": 121, "max_format": 121, "description": "App fixtures"]],
            "data/minecraft/dimension_type/overworld.json": ["min_y": -64, "height": 384, "logical_height": 384, "has_ceiling": false, "coordinate_scale": 1],
            "data/minecraft/dimension_type/the_nether.json": ["min_y": 0, "height": 256, "logical_height": 128, "has_ceiling": true, "coordinate_scale": 8],
            "data/minecraft/dimension_type/the_end.json": ["min_y": 0, "height": 256, "logical_height": 256, "has_ceiling": false, "coordinate_scale": 1],
            "data/minecraft/worldgen/noise_settings/overworld.json": ["noise": ["min_y": -64, "height": 384], "sea_level": 63],
            "data/minecraft/worldgen/noise_settings/nether.json": ["noise": ["min_y": 0, "height": 128], "sea_level": 32],
            "data/minecraft/tags/block/diamond_ores.json": ["replace": true, "values": ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"]],
            "data/minecraft/tags/worldgen/biome/is_overworld.json": ["replace": true, "values": ["minecraft:plains", "minecraft:lush_caves", "minecraft:deep_dark", "minecraft:mushroom_fields"]]
        ]
        let pack = root.appendingPathComponent("datapacks/ChunkseeTest")
        for (path, json) in files {
            let file = pack.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json, options: .sortedKeys).write(to: file)
        }
    }
}
