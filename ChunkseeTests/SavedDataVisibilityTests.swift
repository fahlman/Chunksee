import AppKit
import ApplicationServices
import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(1))) struct SavedDataVisibilityTests {
    private func session(_ root: URL) async throws -> WorldSession {
        let defaults = TestDefaults.make()
        return try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
    }

    private func writeMap(_ id: Int, dimension: NBT?, drawn: Bool, root: URL) throws {
        var colors = [Int8](repeating: 0, count: MapItem.size * MapItem.size)
        if drawn { colors[0] = 50 }
        var data: [String: NBT] = ["colors": .byteArray(colors), "xCenter": .int(24), "zCenter": .int(40)]
        data["dimension"] = dimension
        try Fixtures.writeGzippedNBT(.compound(["data": .compound(data)]),
                                    to: root.appendingPathComponent("data/minecraft/maps/\(id).dat"))
    }

    @Test func blankAndUnlocatedMapsReachTheActualSidebarAndInspectorWithoutInventingNavigation() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(1, dimension: .string("minecraft:overworld"), drawn: false, root: root)
        try writeMap(2, dimension: .int(42), drawn: true, root: root)
        try writeMap(3, dimension: .string("test:missing"), drawn: true, root: root)
        try writeMap(4, dimension: .string("minecraft:overworld"), drawn: true, root: root)
        try writeMap(5, dimension: nil, drawn: false, root: root)
        let session = try await session(root)
        defer { session.close() }
        #expect(session.details.maps.map(\.id) == [1, 2, 3, 4, 5])
        #expect(session.presentation.inGameMaps.map(\.id) == [1, 2, 3, 4, 5])
        let map = try #require(session.map), viewport = map.viewport
        for id in [2, 3, 5] {
            session.selection.choose(.inGameMap(id))
            guard case .inGameMap(let item)? = session.selection.inspectorItem else {
                Issue.record("An unlocated map lost its inspector"); continue
            }
            #expect(item.id == id && map.viewport == viewport)
            #expect(!session.presentation.canShow(item) && MapContent(session: session).inGameMap == nil)
            #expect(session.selection.image(for: item) != nil)
        }
        let unrecognized = try #require(session.details.maps.first { $0.id == 2 })
        #expect(unrecognized.dimension == nil && unrecognized.unrecognizedDimension == "42")
        let text = try await nativeText(InGameMapDetailView(session: session, map: unrecognized))
        #expect(text.contains("Saved Dimension") && text.contains("42") && text.contains("Saved Map Picture"))
        let blank = try #require(session.details.maps.first { $0.id == 1 })
        #expect(blank.isBlank && session.presentation.canShow(blank))
        let blankText = try await nativeText(InGameMapDetailView(session: session, map: blank))
        #expect(blankText.contains("Nothing is drawn on this map."))
        session.selection.choose(.inGameMap(4))
        #expect(MapContent(session: session).inGameMap?.map.id == 4)
        session.close(); await session.waitUntilClosed()
    }

    @Test func untamedMobInspectorShowsSavedEquipmentAppearanceAndCollar() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let creature = try #require(Creature(Fixtures.mob([
            "id": .string("minecraft:wolf"), "Pos": .list([.double(1), .double(64), .double(2)]),
            "variant": .string("test:moon"), "CollarColor": .int(11),
            "equipment": .compound(["head": .compound(["id": .string("minecraft:diamond_helmet"), "count": .int(1)])])
        ]), dataVersion: 5023))
        #expect(creature.owner == nil)
        #expect(creature.equipment?["head"]?.id == "minecraft:diamond_helmet")
        let appearance = try #require(creature.appearance), collar = try #require(creature.collarColor)
        let session = try await session(root)
        defer { session.close() }
        let text = try await nativeText(Form {
            CreatureDetailSections(session: session, creature: creature,
                header: { Text("Saved Wolf") }, location: { EmptyView() })
        }.formStyle(.grouped))
        #expect(text.contains("Equipment") && text.contains("Head") && text.contains("Diamond Helmet"))
        #expect(text.contains("Appearance") && text.contains(PetDetailText.appearance(appearance, species: creature.id)))
        #expect(text.contains("Collar Color") && text.contains(PetDetailText.name(collar)))
        #expect(!text.contains("Tamed By"))
        session.close(); await session.waitUntilClosed()
    }

    @Test(arguments: [nil, 2_865, 6_001] as [Int?])
    func savedSeedEnablesBiomeSamplingWithoutAVersionGate(_ version: Int?) throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        var data: [String: NBT] = ["WorldGenSettings": .compound(["seed": .long(123)])]
        data["DataVersion"] = version.map { .int(Int32($0)) }
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound(data)]), to: root.appendingPathComponent("level.dat"))
        let world = try World(contentsOf: root)
        let colors = try MapBiomeColors.read(in: world, source: .init(data: "fixture", artwork: .unavailable), assets: nil)
        let sampler = try #require(colors.sampler)
        let point = BlockPosition(blockX: 31, blockY: 63, blockZ: -1)
        #expect(sampler.cellOrigin(at: point) == BiomeSampler(seed: 123).cellOrigin(at: point))
    }

    /// Inspect the actual native SwiftUI rows, so an owner check in the view cannot silently
    /// discard data that passed a reader or formatting-only test.
    private func nativeText<Content: View>(_ content: Content) async throws -> String {
        let appeared = AsyncStream<Void>.makeStream()
        let host = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: 360, height: 800)
            .onAppear { appeared.continuation.yield(()); appeared.continuation.finish() })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 800),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for await _ in appeared.stream { }
        let activation = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows).rawValue
        }.value
        try #require(activation == AXError.success.rawValue)
        func strings(_ node: AnyObject) -> [String] {
            let label = node.accessibilityLabel?() ?? ""
            // The public selector returns either text or a number. AnyObject's String overload
            // incorrectly bridges numeric control values as NSString before a Swift cast.
            let selector = NSSelectorFromString("accessibilityValue")
            let object = node as? NSObject
            let value = object?.responds(to: selector) == true
                ? object?.perform(selector)?.takeUnretainedValue() as? String : nil
            let children = node.accessibilityChildren?() ?? []
            return [label, value ?? ""] + children.flatMap { strings($0 as AnyObject) }
        }
        return strings(host).joined(separator: "\n")
    }
}
