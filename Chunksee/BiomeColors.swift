import CoreGraphics
import Foundation

/// Outline colors for biomes. Minecraft has no official biome map colors, so these are the app's
/// own for familiar biomes. Other biomes use their readable game colors before the name hash.
nonisolated enum BiomeColors {
    static let table: [String: UInt32] = [
        "minecraft:ocean": 0x000070, "minecraft:deep_ocean": 0x000030, "minecraft:warm_ocean": 0x0000AC,
        "minecraft:lukewarm_ocean": 0x000090, "minecraft:deep_lukewarm_ocean": 0x000040, "minecraft:cold_ocean": 0x202070,
        "minecraft:deep_cold_ocean": 0x202038, "minecraft:frozen_ocean": 0x7070D6, "minecraft:deep_frozen_ocean": 0x404090,
        "minecraft:river": 0x0000FF, "minecraft:frozen_river": 0xA0A0FF, "minecraft:beach": 0xFADE55,
        "minecraft:snowy_beach": 0xFAF0C0, "minecraft:stony_shore": 0xA2A284, "minecraft:plains": 0x8DB360,
        "minecraft:sunflower_plains": 0xB5DB88, "minecraft:snowy_plains": 0xFFFFFF, "minecraft:ice_spikes": 0xB4DCDC,
        "minecraft:desert": 0xFA9418, "minecraft:swamp": 0x07F9B2, "minecraft:mangrove_swamp": 0x67352B,
        "minecraft:forest": 0x056621, "minecraft:flower_forest": 0x2D8E49, "minecraft:birch_forest": 0x307444,
        "minecraft:old_growth_birch_forest": 0x589C6C, "minecraft:dark_forest": 0x40511A, "minecraft:pale_garden": 0xB9C2BA,
        "minecraft:taiga": 0x0B6659, "minecraft:snowy_taiga": 0x31554A, "minecraft:old_growth_pine_taiga": 0x596651,
        "minecraft:old_growth_spruce_taiga": 0x818E79, "minecraft:jungle": 0x537B09, "minecraft:sparse_jungle": 0x628B17,
        "minecraft:bamboo_jungle": 0x768E14, "minecraft:savanna": 0xBDB25F, "minecraft:savanna_plateau": 0xA79D64,
        "minecraft:windswept_savanna": 0xE5DA87, "minecraft:badlands": 0xD94515, "minecraft:wooded_badlands": 0xB09765,
        "minecraft:eroded_badlands": 0xFF6D3D, "minecraft:windswept_hills": 0x606060, "minecraft:windswept_gravelly_hills": 0x888888,
        "minecraft:windswept_forest": 0x507050, "minecraft:meadow": 0x83BB6D, "minecraft:cherry_grove": 0xFFB7D5,
        "minecraft:grove": 0x8FB8A9, "minecraft:snowy_slopes": 0xC4C4C4, "minecraft:frozen_peaks": 0xB0B3F0,
        "minecraft:jagged_peaks": 0xDCDCC8, "minecraft:stony_peaks": 0x7B8F74, "minecraft:mushroom_fields": 0xFF00FF,
        "minecraft:dripstone_caves": 0x7B6B58, "minecraft:lush_caves": 0x3F8F3F, "minecraft:deep_dark": 0x0A1A1F,
        "minecraft:sulfur_caves": 0xC8B43C,
        "minecraft:nether_wastes": 0xBF3B3B, "minecraft:soul_sand_valley": 0x5E3830, "minecraft:crimson_forest": 0xDD0808,
        "minecraft:warped_forest": 0x49907B, "minecraft:basalt_deltas": 0x403636, "minecraft:the_end": 0x8080FF,
        "minecraft:end_highlands": 0xB5B5E0, "minecraft:end_midlands": 0x9A9AD0, "minecraft:end_barrens": 0x7070B0,
        "minecraft:small_end_islands": 0x5A5A9A, "minecraft:the_void": 0x101010,
    ]

    static func color(for biome: String, game: MapBiomeColors? = nil, at position: CGPoint = .zero) -> MapColor {
        if let hex = table[biome] { return MapColor(hex) }
        if let color = game?.outlineColor(for: biome, at: position) { return color }
        // No readable definition: preserve a stable visible outline rather than hide the biome.
        var hash: UInt32 = 2_166_136_261
        for byte in biome.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return MapColor(hash & 0xFFFFFF)
    }
}
