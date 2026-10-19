import Foundation
import ChunkseeKit

/// Original, fictional sample content. Uses the same fixture writers as other app tests.
nonisolated enum SampleWorldFixture {
    static func make() throws -> URL {
        let owner = NBT.intArray([1, 2, 3, 4])
        let blocks = ["air", "stone", "dirt", "grass_block", "sand", "water", "oak_planks",
                      "oak_log", "chest", "oak_sign", "spawner"].map { "minecraft:" + $0 }
        let chest = NBT.compound([
            "id": .string("minecraft:chest"), "x": .int(93), "y": .int(58), "z": .int(109),
            "Items": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(12), "Slot": .byte(0)])]),
        ])
        let sign = NBT.compound([
            "id": .string("minecraft:sign"), "x": .int(107), "y": .int(58), "z": .int(110),
            "front_text": .compound(["messages": .list(["Welcome!", "Find diamonds", "in the cabin", "Enjoy the view"].map(NBT.string))]),
        ])
        let spawner = NBT.compound([
            "id": .string("minecraft:mob_spawner"), "x": .int(166), "y": .int(58), "z": .int(104),
            "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])]),
        ])
        var chunks: [TestWorld.ChunkSpec] = []
        for z in 0..<16 { for x in 0..<16 {
            var chunk = TestWorld.chunk(x: x, z: z, palette: blocks) { bx, y, bz in
                block(x: x * 16 + bx, y: y, z: z * 16 + bz)
            }
            var fields = chunk.nbt.compound!
            var section = fields["sections"]!.list![0].compound!
            section["Y"] = .byte(3)
            fields["sections"] = .list([.compound(section)])
            fields["yPos"] = .int(3)
            fields["InhabitedTime"] = .long(Int64(1_200 + max(0, 16 - abs(x - 6) - abs(z - 7)) * 72_000))
            fields["block_entities"] = .list([chest, sign, spawner].filter {
                $0["x"]!.int! / 16 == x && $0["z"]!.int! / 16 == z
            })
            chunk.nbt = .compound(fields)
            chunks.append(chunk)
        } }
        let root = try TestWorld.make(chunks: chunks)
        let level = NBT.compound(["Data": .compound([
            "LevelName": .string("Sample World"), "DataVersion": .int(5023), "GameType": .int(1),
            "singleplayer_uuid": owner,
            "spawn": .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([120, 58, 120])]),
        ])])
        try gzip(level, to: root.appendingPathComponent("level.dat"))
        let players = root.appendingPathComponent("players/data")
        try FileManager.default.createDirectory(at: players, withIntermediateDirectories: true)
        let player = NBT.compound([
            "DataVersion": .int(5023), "UUID": owner, "Dimension": .string("minecraft:overworld"),
            "Pos": .list([121.5, 58, 112.5].map(NBT.double)), "Health": .float(20),
            "Inventory": .list([.compound(["id": .string("minecraft:compass"), "count": .int(1), "Slot": .byte(0)])]),
        ])
        try gzip(player, to: players.appendingPathComponent("00000001-0000-0002-0000-000300000004.dat"))
        let pets = [("wolf", "Scout", 112.5, 5), ("cat", "Socks", 118.5, 6)].map { kind, name, x, id in
            NBT.compound([
                "id": .string("minecraft:" + kind), "UUID": .intArray([1, 2, 3, Int32(id)]),
                "Owner": owner, "CustomName": .string(name), "Pos": .list([x, 58, 108.5].map(NBT.double)),
                "Health": .float(8), "Sitting": .byte(1), "CollarColor": .byte(14),
            ])
        }
        let entities = root.appendingPathComponent("dimensions/minecraft/overworld/entities")
        try FileManager.default.createDirectory(at: entities, withIntermediateDirectories: true)
        let entityChunk = TestWorld.ChunkSpec(x: 7, z: 6, nbt: .compound([
            "DataVersion": .int(5023), "Position": .intArray([7, 6]), "Entities": .list(pets),
        ]))
        try Data(TestWorld.regionFile([entityChunk])).write(to: entities.appendingPathComponent("r.0.0.mca"))
        return root
    }

    private static func gzip(_ nbt: NBT, to url: URL) throws {
        try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: url)
    }

    private static func block(x: Int, y: Int, z: Int) -> Int {
        if y == 10 {
            if x == 93 && z == 109 { return 8 }
            if x == 107 && z == 110 { return 9 }
            if x == 166 && z == 104 { return 10 }
        }
        if (87...106).contains(x), (99...115).contains(z), y == 14 { return 6 }
        if (88...105).contains(x), (100...114).contains(z) {
            if y == 9 { return 6 }
            if (10...13).contains(y), x == 88 || x == 105 || z == 100 || z == 114 {
                return z == 100 && (96...97).contains(x) && y < 13 ? 0 : 7
            }
        }
        let shore = min(x, z, 255 - x, 255 - z)
        let river = abs(x - (145 + Int(10 * sin(Double(z) / 22)))) < 5
        if shore < 24 || river { return y < 5 ? 1 : y <= 7 ? 5 : 0 }
        let height = shore < 32 ? 8 : 9 + (x > 170 && z > 170 ? min(4, (x - 170) / 20 + (z - 170) / 20) : 0)
        guard y <= height else { return 0 }
        if y == height { return shore < 32 ? 4 : 3 }
        return y < height - 2 ? 1 : 2
    }
}
