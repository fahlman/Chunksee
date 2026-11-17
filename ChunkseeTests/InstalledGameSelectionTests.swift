import ChunkseeKit
import ChunkseeIndex
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct InstalledGameSelectionTests {
    private func install(_ metadata: [String: Any], as directory: String, under root: URL,
                         entries: [TestZIP.Entry] = []) throws -> URL {
        let file = root.appendingPathComponent("versions/\(directory)/\(directory).jar")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: metadata)
        try Data(TestZIP.zip([.init(path: "version.json", text: String(decoding: json, as: UTF8.self))] + entries)).write(to: file)
        return file
    }

    @Test func newestDeclaredReleaseWinsRegardlessOfDirectoryNameOrWorldVersion() async throws {
        let root = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try install(["id": "old", "world_version": 900, "stable": true, "build_time": "2025-01-01T00:00:00Z"], as: "z-release", under: root)
        _ = try install(["id": "latest-release", "world_version": 800, "stable": true, "build_time": "2026-01-01T00:00:00Z"], as: "named-like-snapshot", under: root)
        _ = try install(["id": "future-preview", "world_version": 999999, "stable": false, "build_time": "2027-01-01T00:00:00Z"], as: "named-like-release", under: root)
        let resources = MinecraftResources(defaults: TestDefaults.make())
        resources.choose(root)
        let first = try #require(await resources.library())
        #expect(first.version.id == "latest-release")
        #expect(await resources.library() === first)
        resources.forget()
        await resources.waitUntilIdle()
    }

    @Test func newestAnyFallbackUsesMetadataAndSkipsUnreadableArchives() async throws {
        let root = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try install(["id": "earlier", "world_version": 8, "stable": false, "build_time": "2026-01-01T00:00:00Z"], as: "earlier", under: root)
        let latest = try install(["id": "newest", "world_version": 7, "build_time": "2026-02-01T00:00:00Z"], as: "newest", under: root)
        _ = try install(["id": "unreadable"], as: "bad", under: root)
        let libraries = GameResourceLibraries()
        #expect(try await libraries.library(under: root)?.version.id == "newest")
        try Data([0xFF]).write(to: latest)
        #expect(try await libraries.library(under: root)?.version.id == "earlier")
        await libraries.close()
    }

    @Test func missingDatesUseSavedFormatRevisionWithoutANameHeuristic() async throws {
        let root = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try install(["id": "999", "world_version": 7], as: "z", under: root)
        _ = try install(["id": "1", "world_version": 8], as: "a", under: root)
        let libraries = GameResourceLibraries()
        #expect(try await libraries.library(under: root)?.version.id == "1")
        await libraries.close()
    }

    @Test(.timeLimit(.minutes(1))) func olderGameWithoutAnOreRootStillOpensANewerWorld() async throws {
        let game = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: game) }
        // The real 1.18.2 archive has this child but no minecraft:ores root. This checks
        // selection and the absent root, not support for its legacy tag-folder format.
        _ = try install(["id": "1.18.2", "world_version": 2975, "stable": true,
                         "build_time": "2022-02-28T10:40:37+00:00"], as: "only-release", under: game, entries: [
            .init(path: "data/minecraft/tags/blocks/diamond_ores.json",
                  text: #"{"replace":false,"values":["minecraft:diamond_ore","minecraft:deepslate_diamond_ore"]}"#),
        ])
        try await withNewerWorld(game: game, dataVersion: 5023) { loaded, library, _ in
            #expect(library.version.id == "1.18.2" && library.version.dataVersion == 2975)
            #expect(!loaded.details.definitions.notableBlocks.hasOreDefinitions)
            #expect(loaded.blockCounts.catalog == loaded.details.definitions.notableBlocks)
        }
    }

    @Test(.timeLimit(.minutes(1))) func readableOlderGameTagsReachANewerWorldAndRefreshOreDefinitions() async throws {
        let game = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: game) }
        // A minimal current-format archive supplies the child; the enabled pack controls
        // the root. Its real release metadata is older than this synthetic save's revision.
        _ = try install(["id": "26.3", "world_version": 5023, "stable": true,
                         "build_time": "2026-09-15T11:20:48+00:00"], as: "only-release", under: game, entries: [
            .init(path: "data/minecraft/tags/block/diamond_ores.json",
                  text: #"{"values":["minecraft:diamond_ore","minecraft:deepslate_diamond_ore"]}"#),
        ])
        try await withNewerWorld(game: game, dataVersion: 5024) { loaded, library, root in
            #expect(library.version.id == "26.3" && library.version.dataVersion == 5023)
            #expect(!loaded.details.definitions.notableBlocks.hasOreDefinitions)

            let ores = root.appendingPathComponent("datapacks/catalog/data/minecraft/tags/block/ores.json")
            try Fixtures.write(Array(##"{"values":["#minecraft:diamond_ores"]}"##.utf8), to: ores)
            loaded.worldChanged([ores])
            await loaded.waitForRefresh()
            let known = loaded.details.definitions.notableBlocks
            #expect(known.hasOreDefinitions)
            #expect(known.ids(for: .tag("minecraft:diamond_ores")) == ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"])
            #expect(loaded.blockCounts.catalog == known)

            try Fixtures.write(Array(#"{"replace":true,"values":[]}"#.utf8), to: ores)
            loaded.worldChanged([ores])
            await loaded.waitForRefresh()
            let empty = loaded.details.definitions.notableBlocks
            #expect(empty.hasOreDefinitions && empty.ids(for: .tag("minecraft:diamond_ores")) == nil)
            #expect(loaded.blockCounts.catalog == empty)

            try FileManager.default.removeItem(at: ores)
            loaded.worldChanged([ores])
            await loaded.waitForRefresh()
            let missing = loaded.details.definitions.notableBlocks
            #expect(!missing.hasOreDefinitions && missing.blockIDs == empty.blockIDs)
            #expect(loaded.blockCounts.catalog == missing)
        }
    }

    private func withNewerWorld(game: URL, dataVersion: Int32,
                               check: (WorldResources, GameResourceLibrary, URL) async throws -> Void) async throws {
        let root = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string("Newer save"), "DataVersion": .int(dataVersion),
            "DataPacks": .compound(["Enabled": .list([.string("vanilla"), .string("file/catalog")])]),
        ])]), to: root.appendingPathComponent("level.dat"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/minecraft/overworld/region"),
                                                withIntermediateDirectories: true)
        try Fixtures.write(Array(#"{"pack":{"min_format":121,"max_format":121,"description":"Catalog fixture"}}"#.utf8),
                           to: root.appendingPathComponent("datapacks/catalog/pack.mcmeta"))
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        names.minecraft.choose(game)
        var resources: WorldResources?
        var failure: (any Error)?
        do {
            let loaded = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
                savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                watchWorld: { _, _ in nil })
            resources = loaded
            loaded.refreshDelay = .zero
            await loaded.waitForRefresh()
            let library = try #require(try await names.minecraft.readLibrary())
            #expect(loaded.world.level.dataVersion == Int(dataVersion))
            #expect(library.version.dataVersion < dataVersion)
            #expect(loaded.mapGameResources.data === library.data)
            try await check(loaded, library, root)
            #expect(try await names.minecraft.readLibrary() === library)
        } catch { failure = error }
        resources?.close()
        if let resources { await resources.waitUntilClosed() }
        names.minecraft.forget(); await names.minecraft.waitUntilIdle()
        if let failure { throw failure }
    }
}
