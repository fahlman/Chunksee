import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct InstalledGameSelectionTests {
    private func install(_ metadata: [String: Any], as directory: String, under root: URL) throws -> URL {
        let file = root.appendingPathComponent("versions/\(directory)/\(directory).jar")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: metadata)
        try Data(TestZIP.zip([.init(path: "version.json", text: String(decoding: json, as: UTF8.self))])).write(to: file)
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
}
