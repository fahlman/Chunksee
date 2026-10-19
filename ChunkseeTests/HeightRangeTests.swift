import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct HeightRangeTests {
    private final class Fixture {
        let url: URL
        let defaults = TestDefaults.make()
        var resources: WorldResources?
        var sessions: [WorldSession] = []

        init() throws { url = try TestWorld.make(chunks: []) }

        func metadata(_ types: [String: NBT], version: Int32 = 5023) throws {
            let level = NBT.compound(["Data": .compound(["LevelName": .string("Height Ranges"),
                "DataVersion": .int(version), "DataPacks": .compound(["Enabled": .list([.string("vanilla")])])])])
            try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: url.appendingPathComponent("level.dat"))
            let folder = url.appendingPathComponent("data/minecraft")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let saved = NBT.compound(["DataVersion": .int(version), "data": .compound([
                "dimensions": .compound(types.mapValues { .compound(["type": $0]) })])])
            try Data(Compression.deflate(saved.serialized(), gzip: true)).write(to: folder.appendingPathComponent("world_gen_settings.dat"))
        }

        func dimension(_ id: String) throws {
            let path = id.replacingOccurrences(of: ":", with: "/")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/\(path)/region"),
                                                     withIntermediateDirectories: true)
        }

        func open() async throws -> WorldResources {
            let opened = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
            resources = opened
            return opened
        }

        func session(in resources: WorldResources, dimensionID: String? = nil) -> WorldSession {
            let session = WorldSession(resources: resources, dimensionID: dimensionID)
            sessions.append(session)
            return session
        }

        func close() async {
            sessions.forEach { $0.close() }
            resources?.close()
            for session in sessions { await session.waitUntilClosed() }
            await resources?.waitUntilClosed()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let f = try Fixture()
        do { try await body(f) }
        catch { await f.close(); throw error }
        await f.close()
    }

    private var deepType: NBT {
        .compound(["min_y": .int(-128), "height": .int(256), "logical_height": .int(64), "has_ceiling": .byte(1)])
    }

    @Test func savedTypesSetEachTabsRangeWithoutClampingRememberedDepth() async throws {
        try await withFixture { f in
            try f.metadata(["minecraft:overworld": .string("minecraft:overworld"),
                "minecraft:the_nether": .string("minecraft:the_nether"), "minecraft:the_end": .string("minecraft:the_end"),
                "example:deep": deepType, "example:sky": .string("minecraft:the_nether")])
            let ranges = ["minecraft:overworld": -64...319, "minecraft:the_nether": 0...255,
                          "minecraft:the_end": 0...255, "example:deep": -128...127, "example:sky": 0...255]
            for id in ranges.keys { try f.dimension(id) }
            let resources = try await f.open()
            let sessions = ranges.keys.sorted().map { f.session(in: resources, dimensionID: $0) }
            for session in sessions {
                let id = try #require(session.selectedDimensionID), map = try #require(session.map)
                #expect(session.presentation.heightRange == ranges[id])
                for y in [-900, 900, Int.min, Int.max] {
                    map.setDepth(MapDepth(y: y, isSurface: false))
                    session.saveView()
                    #expect(map.depth.cutawayY == y)
                    #expect(session.presentation.heightRange == ranges[id])
                    #expect(resources.views.depth(for: id) == map.depth)
                }
                let reopened = f.session(in: resources, dimensionID: id)
                #expect(reopened.map?.depth.cutawayY == Int.max)
                #expect(reopened.presentation.heightRange == ranges[id])
                reopened.close()
                await reopened.waitUntilClosed()
            }
        }
    }

    @Test func unavailableTypesLeaveNumericEntryWithoutGuessedBounds() async throws {
        for example in ["missing", "unresolved", "unverified", "unreadable"] {
            try await withFixture { f in
                if example != "missing" {
                    try f.metadata(["minecraft:overworld": .string(example == "unresolved" ? "example:unknown" : "minecraft:overworld")],
                                   version: example == "unverified" ? 9999 : 5023)
                }
                if example == "unreadable" {
                    try Data("invalid saved metadata".utf8).write(to: f.url.appendingPathComponent("data/minecraft/world_gen_settings.dat"))
                }
                let resources = try await f.open()
                let session = f.session(in: resources)
                #expect(session.presentation.heightRange == nil)
                let map = try #require(session.map)
                map.setDepth(MapDepth(y: -900, isSurface: false))
                #expect(map.depth.cutawayY == -900 && session.presentation.heightRange == nil)
            }
        }
    }

    @Test func aNewDimensionUsesFreshLimitsWithoutReplacingAnExistingTabsState() async throws {
        try await withFixture { f in
            try f.metadata(["minecraft:overworld": .string("minecraft:overworld"), "example:deep": .string("minecraft:the_end")])
            let resources = try await f.open()
            let original = f.session(in: resources)
            let map = try #require(original.map)
            map.setDepth(MapDepth(y: 900, isSurface: false))
            try f.dimension("example:deep")
            try f.metadata(["minecraft:overworld": .string("minecraft:the_nether"), "example:deep": deepType])
            let fresh = try await WorldSnapshot.read(f.url)
            resources.includeDimensions(from: fresh)
            fresh.access.release()
            let added = f.session(in: resources, dimensionID: "example:deep")
            #expect(added.map != nil && added.presentation.heightRange == -128...127)
            #expect(original.map === map && map.depth.cutawayY == 900)
            #expect(original.presentation.heightRange == -64...319)
        }
    }
}
