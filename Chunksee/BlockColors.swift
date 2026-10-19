/// An opaque sRGB color for one map pixel.
nonisolated struct MapColor: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(_ hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    /// Scales brightness; values above 1 lighten, below 1 darken.
    func shaded(_ factor: Double) -> MapColor {
        func channel(_ v: UInt8) -> UInt32 { UInt32(min(255, max(0, (Double(v) * factor).rounded()))) }
        return MapColor(channel(red) << 16 | channel(green) << 8 | channel(blue))
    }
}

/// Top-down map colors for blocks. This is presentation, so it lives in the app, not ChunkseeKit.
nonisolated enum BlockColors {
    /// The map color for a block ID, or `nil` for blocks the map sees through (air, glass panes, light).
    static func color(for id: String) -> MapColor? {
        let name = ReadableName.vanillaPath(id) ?? id
        if transparent.contains(name) { return nil }
        if let exact = exact[name] { return MapColor(exact) }
        for (fragment, hex) in fragments where name.contains(fragment) { return MapColor(hex) }
        return fallback(for: name)
    }

    static func isWater(_ id: String) -> Bool {
        guard let path = ReadableName.vanillaPath(id) else { return false }
        return path == "water" || path == "bubble_column"
    }

    private static let transparent: Set<String> = [
        "air", "cave_air", "void_air", "light", "barrier", "structure_void",
    ]

    private static let exact: [String: UInt32] = [
        "grass_block": 0x7CBD6B, "short_grass": 0x6FA85E, "tall_grass": 0x6FA85E, "fern": 0x5E9150,
        "dirt": 0x866043, "coarse_dirt": 0x77553B, "rooted_dirt": 0x8F6A4F, "podzol": 0x5B3F24,
        "mycelium": 0x6F6265, "mud": 0x3C3A3D, "farmland": 0x7A5332, "dirt_path": 0x947A41,
        "stone": 0x7D7D7D, "cobblestone": 0x7A7A7A, "mossy_cobblestone": 0x6E7A5F, "andesite": 0x888888,
        "diorite": 0xBDBDBD, "granite": 0x956755, "deepslate": 0x505052, "tuff": 0x6C6D66,
        "calcite": 0xDFE0DC, "bedrock": 0x3A3A3A, "gravel": 0x837F7E, "clay": 0xA0A6B3,
        "sand": 0xDBD3A0, "red_sand": 0xBE6621, "sandstone": 0xD8CB9B, "red_sandstone": 0xB5621F,
        "water": 0x3F76E4, "bubble_column": 0x3F76E4, "lava": 0xCF5B13, "ice": 0x91B7FD,
        "packed_ice": 0x8DB4FA, "blue_ice": 0x74A8FD, "snow": 0xF4FCFC, "snow_block": 0xF4FCFC,
        "powder_snow": 0xF8FDFD, "netherrack": 0x6F3534, "soul_sand": 0x513E32, "soul_soil": 0x4B3A2F,
        "basalt": 0x4D4D53, "blackstone": 0x2A2328, "magma_block": 0x8E3F1F, "glowstone": 0xD8B36C,
        "crimson_nylium": 0x852A2A, "warped_nylium": 0x2B7265, "nether_wart_block": 0x761213,
        "warped_wart_block": 0x167A73, "shroomlight": 0xF1924B, "end_stone": 0xDBDE9E,
        "obsidian": 0x0F0B19, "crying_obsidian": 0x210A3C, "purpur_block": 0xA97DA9,
        "chorus_plant": 0x5E395E, "chorus_flower": 0x977597, "moss_block": 0x596E2D,
        "lily_pad": 0x208030, "seagrass": 0x2E6B3A, "tall_seagrass": 0x2E6B3A, "kelp": 0x58822F,
        "kelp_plant": 0x58822F, "sugar_cane": 0x95C165, "cactus": 0x5C8E35, "pumpkin": 0xC67618,
        "melon": 0x6F9123, "hay_block": 0xA68C11, "bamboo": 0x5D8C1E, "dripstone_block": 0x866B5C,
        "pointed_dripstone": 0x866B5C, "amethyst_block": 0x8562C6, "budding_amethyst": 0x8462C3,
        "sculk": 0x0D1E24, "terracotta": 0x985E43, "bricks": 0x966153, "bookshelf": 0x6B5839,
        "glass": 0xC0DCE0, "torch": 0xF7C34A, "lantern": 0x6A5B4A, "campfire": 0x6A5134,
        "rail": 0x7D6C51, "powered_rail": 0x8E7744, "chest": 0x9E7130, "crafting_table": 0x7F5E3A,
        "furnace": 0x6E6E6E, "beacon": 0x75DED8, "spawner": 0x223042,
    ]

    /// Ordered substring rules for families of blocks (wood types, colored blocks, ores…).
    private static let fragments: [(String, UInt32)] = [
        ("leaves", 0x4A7A2F), ("azalea", 0x667E2E), ("vine", 0x3F6A23), ("mushroom", 0x93685A),
        ("crimson_", 0x7B3A53), ("warped_", 0x3A8E8C), ("cherry_", 0xE2B5B3), ("mangrove_", 0x773634),
        ("bamboo_", 0xC1AD50), ("dark_oak_", 0x4A311A), ("spruce_", 0x6B4F2F), ("birch_", 0xC4B47E),
        ("jungle_", 0x9F7351), ("acacia_", 0xA8592F), ("pale_oak_", 0xE0D6D2), ("oak_", 0xA2834F),
        ("_log", 0x6C5536), ("_wood", 0x6C5536), ("planks", 0xA2834F),
        ("white_", 0xE9ECEC), ("light_gray_", 0x8E8E86), ("gray_", 0x3E4447), ("black_", 0x141519),
        ("brown_", 0x724728), ("red_", 0xA12722), ("orange_", 0xF07613), ("yellow_", 0xF8C527),
        ("lime_", 0x70B919), ("green_", 0x546D1B), ("cyan_", 0x158991), ("light_blue_", 0x3AAFD9),
        ("blue_", 0x35399D), ("purple_", 0x792AAC), ("magenta_", 0xBD44B3), ("pink_", 0xED8DAC),
        ("deepslate", 0x505052), ("copper", 0xC06C50), ("_ore", 0x7D7D7D), ("stone", 0x7D7D7D),
        ("sandstone", 0xD8CB9B), ("prismarine", 0x63A797), ("coral", 0xC75D8C), ("quartz", 0xEBE5DE),
        ("nether_brick", 0x2C1519), ("brick", 0x966153), ("glass", 0xC0DCE0), ("ice", 0x91B7FD),
        ("snow", 0xF4FCFC), ("sapling", 0x4F8A2C), ("flower", 0x9E6B9E), ("tulip", 0xC4553E),
        ("rose", 0xA11E1E), ("berry", 0x3B6B2B), ("wheat", 0xB8A042), ("carrots", 0x5F9B2A),
        ("potatoes", 0x5F9B2A), ("beetroots", 0x5F9B2A), ("candle", 0xD9C38E), ("carpet", 0xB0A090),
    ]

    /// A stable, muted color for blocks the table doesn't know, so unknown blocks stay visible.
    private static func fallback(for name: String) -> MapColor {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let r = 0x60 + (hash & 0x3F), g = 0x60 + ((hash >> 8) & 0x3F), b = 0x60 + ((hash >> 16) & 0x3F)
        return MapColor(r << 16 | g << 8 | b)
    }
}
