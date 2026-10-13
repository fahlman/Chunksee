import ChunkseeKit
import Foundation
import Testing
@testable import Chunksee

@Suite struct SavedWorldsTests {
    private func world(_ path: String, name: String, lastPlayed: Int64, in root: URL) throws {
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let level = NBT.compound(["Data": .compound(["LevelName": .string(name), "LastPlayed": .long(lastPlayed)])])
        try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: folder.appendingPathComponent("level.dat"))
    }

    @Test func listsEveryInstallationsWorldsMostRecentlyPlayedFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseeMinecraft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try world("saves/Survival", name: "Survival", lastPlayed: 1_700_000_000_000, in: root)
        try world("vanilla/release/saves/Ryan's Realm", name: "Ryan's Realm", lastPlayed: 1_790_000_000_000, in: root)
        try world("vanilla/aprilfools/blue/saves/blue", name: "Survival", lastPlayed: 1_750_000_000_000, in: root)
        try world("vanilla/release/backups/Ryan's Realm-old", name: "Ryan's Realm", lastPlayed: 1_600_000_000_000, in: root)
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let names = PlayerNames(defaults: defaults)
        let worlds = SavedWorlds(names: names)
        #expect(!worlds.hasMinecraftFolder)
        await names.chooseMinecraftFolder(root)
        worlds.reload()
        await worlds.waitForReload()
        #expect(worlds.all.map(\.name) == ["Ryan's Realm", "Survival", "Survival"])
        // Worlds sharing a name show their installation.
        #expect(worlds.all.map(worlds.title(for:)) == ["Ryan's Realm", "Survival (vanilla/aprilfools/blue)", "Survival (Minecraft folder)"])
        names.forgetMinecraftFolder()
        worlds.reload()
        #expect(worlds.all.isEmpty)
    }
}
