import AppKit
import ChunkseeKit
import Foundation
import SwiftUI
import Testing
@testable import Chunksee

@Suite(.timeLimit(.minutes(1))) struct PortalAvailabilityTests {
    private final class Fixture {
        let url: URL
        let suite: String
        let defaults: UserDefaults
        let names: PlayerNames
        let searches: SavedSearches
        var sessions: [WorldSession] = []

        init() throws {
            let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            url = try TestWorld.make(chunks: [chunk])
            suite = "ChunkseeTests-\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            names = PlayerNames(defaults: defaults)
            searches = SavedSearches(defaults: defaults)
            let poi = NBT.compound(["Sections": .compound(["0": .compound([
                "Valid": .byte(1), "Records": .list([.compound([
                    "type": .string("minecraft:nether_portal"), "pos": .intArray([8, 2, 8]), "free_tickets": .int(0),
                ])]),
            ])])])
            let folder = url.appendingPathComponent("dimensions/minecraft/overworld/poi")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(TestWorld.regionFile([TestWorld.ChunkSpec(x: 0, z: 0, nbt: poi)])).write(to: folder.appendingPathComponent("r.0.0.mca"))
        }

        func open() async throws -> WorldSession {
            let session = WorldSession(snapshot: try await WorldSnapshot.read(url), names: names,
                                       savedSearches: searches, defaults: defaults, cacheRoot: nil)
            sessions.append(session)
            return session
        }

        func close() async {
            sessions.forEach { $0.close() }
            for session in sessions { await session.waitUntilClosed() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func completedMissingTargetShowsAnUnavailableMessageRatherThanPermanentLoading() async throws {
        try await withFixture { f in
            let session = try await f.open()
            await session.resources.index.waitForIndex()
            let portal = try #require(session.portalsByDimension["minecraft:overworld"]?.first)
            #expect(session.dimensions.map(\.id) == ["minecraft:overworld"])
            #expect(!session.resources.index.isIndexing && session.link(for: portal) == nil)
            let hosting = NSHostingView(rootView: PortalDetailView(session: session, portal: portal)
                .environment(\.locale, Locale(identifier: "en")))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Portal Availability Test"
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            let text = Self.accessibilityText(hosting)
            #expect(text.contains("Link"), "The actual hosted portal form must be inspectable")
            #expect(text.contains("Portal links aren’t available for this dimension."))
            #expect(!text.contains("Predicted with Minecraft’s linking rule from the portal’s bottom center."))
        }
    }

    @MainActor
    private static func accessibilityText(_ element: Any, depth: Int = 0) -> Set<String> {
        guard depth < 30, let object = element as? NSObject else { return [] }
        func value(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var text: Set<String> = []
        for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
            if let string = value(key) as? String { text.insert(string) }
            if let attributed = value(key) as? NSAttributedString { text.insert(attributed.string) }
        }
        for child in value("accessibilityChildren") as? [Any] ?? [] {
            text.formUnion(accessibilityText(child, depth: depth + 1))
        }
        return text
    }
}
