import AppKit
import ChunkseeKit
import ChunkseeIndex
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct MobSidebarTests {
    private func marker(_ species: String, x: Double, name: String? = nil, owner: UUID? = nil,
                        appearance: CreatureAppearance? = nil) throws -> CreatureMarker {
        try #require(CreatureMarker(Creature(id: species, x: x, y: 64, z: 0, customName: name, owner: owner,
            appearance: appearance), dimension: "minecraft:overworld"))
    }

    @Test func typesRetainEveryAppearanceAndSortIndividualsWithoutDuplicatingSpecialGroups() async throws {
        let white = try marker("minecraft:sheep", x: 5, name: "Snow", appearance: .init(variant: "minecraft:white"))
        let red = try marker("minecraft:sheep", x: 1, appearance: .init(variant: "minecraft:red"))
        let unknown = try marker("minecraft:sheep", x: -1)
        let fish = try marker("minecraft:tropical_fish", x: 3,
            appearance: .init(variant: "minecraft:kob", traits: ["base_color": "white", "pattern_color": "red"]))
        let otherFish = try marker("minecraft:tropical_fish", x: 4,
            appearance: .init(variant: "minecraft:kob", traits: ["base_color": "white", "pattern_color": "blue"]))
        let custom = try marker("test:sheep", x: 8)
        let catalog = MobTypes([white, red, unknown, fish, otherFish, custom])
        #expect(catalog.kinds.count == 3 && catalog.kinds.reduce(0) { $0 + $1.count } == 6)
        #expect(CreatureGroup.mob.symbol != CreatureGroup.pet.symbol)
        #expect(NSImage(systemSymbolName: CreatureGroup.mob.symbol, accessibilityDescription: nil) != nil)
        #expect(catalog.specialCreatures == [white])
        #expect(catalog.marker(red.id) == red)
        let sheep = try #require(catalog.kind("minecraft:sheep"))
        #expect(sheep.count == 3 && sheep.variants.count == 3)
        #expect(sheep.variants.contains { !$0.appearance.isRecorded && $0.count == 1 })
        #expect(GameNames.unavailable.mobName(sheep.id, in: catalog) != GameNames.unavailable.mobName("test:sheep", in: catalog))
        let fishKind = try #require(catalog.kind("minecraft:tropical_fish"))
        #expect(fishKind.variants.count == 2 && fishKind.variants.allSatisfy { $0.count == 1 })
        #expect(fishKind.variants.map { GameNames.unavailable.creatureAppearance($0.appearance.saved) }.allSatisfy { $0.contains("Base Color: White") })
        let ordered = try await catalog.nearest("minecraft:sheep", to: .zero)
        #expect(Set(ordered.prefix(2).map(\.id)) == [red.id, unknown.id] && ordered.last == white)
        #expect(try await MobTypes([unknown, red, white]).nearest("minecraft:sheep", to: .zero).map(\.id) == ordered.map(\.id))
        let cancelled = Task { try await catalog.nearest("minecraft:sheep", to: .zero) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled row preparation published a result") }
        catch is CancellationError {} catch { Issue.record(error) }
    }

    @Test(arguments: [false, true])
    func typeFiltersKeepNamedAndPetVisibilityIndependent(_ pet: Bool) throws {
        let species = pet ? "minecraft:wolf" : "minecraft:sheep"
        let white = try marker(species, x: 5, name: pet ? nil : "Snow", owner: pet ? UUID() : nil,
                               appearance: .init(variant: pet ? "minecraft:pale" : "minecraft:white"))
        let red = try marker(species, x: 1, appearance: .init(variant: pet ? "minecraft:rusty" : "minecraft:red"))
        var content = MapContent(gameNames: .unavailable)
        content.creatures = [white, red]
        content.shownCreatureGroups = [white.group]
        content.shownMobTypes = [species]
        #expect(content.creatures == [white, red])
        content.mobAppearances[species] = MobAppearance(red.creature.appearance)
        #expect(content.creatures == [white, red])
        let viewport = MapViewport(center: .zero, scale: 1)
        #expect(content.nearbyCreatures(viewport: viewport, size: CGSize(width: 100, height: 100)) == [white, red])
        let locations = content.accessibleLocations(viewport: viewport, size: CGSize(width: 100, height: 100))
        #expect(locations.filter { $0.target == .row(.mobCreature(red.id)) }.count == 1)
        content.shownCreatureGroups = []
        #expect(content.creatures == [red])
        content.shownCreatureGroups = [white.group]
        content.shownMobTypes = []
        #expect(content.creatures == [white])

        let settings = WorldSettings(id: UUID(), defaults: TestDefaults.make())
        let visibility = LayerVisibility(settings: settings, dimension: "minecraft:overworld")
        visibility.mobTypes = [species]
        visibility.mobAppearances[species] = MobAppearance(red.creature.appearance)
        visibility.reveal(white)
        #expect(visibility.mobAppearances[species] == MobAppearance(red.creature.appearance))
        visibility.mobAppearances[species] = MobAppearance(white.creature.appearance)
        #expect(visibility.appearance(for: try #require(MobTypes([red]).kind(species))) == nil)
        visibility.reveal(red, inMobList: true)
        #expect(visibility.mobAppearances[species] == nil)
        let reopened = LayerVisibility(settings: settings, dimension: "minecraft:overworld")
        #expect(reopened.mobTypes == [species] && reopened.mobAppearances.isEmpty)
        #expect(LayerVisibility(settings: settings, dimension: "minecraft:the_nether").mobTypes.isEmpty)
    }

    @Test func realSavedMobsDriveTypeSelectionFilteringAndSearchWithoutGameFiles() async throws {
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        func entity(_ id: String, index: Int32, fields: [String: NBT]) -> NBT {
            Fixtures.mob(["id": .string(id), "UUID": .intArray([1, 2, 3, index]),
                "Pos": .list([.double(Double(index) * 3), .double(64), .double(4)]), "Health": .float(20)]
                .merging(fields) { $1 })
        }
        let entities = [entity("minecraft:sheep", index: 1, fields: ["Color": .byte(0)]),
            entity("minecraft:sheep", index: 2, fields: ["Color": .byte(14), "CustomName": .string("Berry")]),
            entity("minecraft:axolotl", index: 3, fields: ["Variant": .int(0)]),
            entity("minecraft:axolotl", index: 4, fields: ["Variant": .int(1)])]
        let chunk = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list(entities)])
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: chunk)])).write(to: dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca"))
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let catalog = session.presentation.selectedIndex.mobTypes
        #expect(catalog.kinds.map(\.id) == ["minecraft:axolotl", "minecraft:sheep"])
        #expect(catalog.kinds.allSatisfy { $0.count == 2 && $0.variants.count == 2 })
        let red = try #require(catalog.specialCreatures.first)
        let white = try #require(try await catalog.nearest("minecraft:sheep", to: .zero).first { $0.id != red.id })
        #expect(MapContent(session: session).creatures == [red])
        session.selection.choose(.mobType("minecraft:sheep"))
        guard case .mobType(let kind)? = session.selection.inspectorItem else { Issue.record("Type inspector was not selected"); return }
        #expect(kind.count == 2 && MapContent(session: session).creatures.count == 2)
        session.visibility.mobAppearances[kind.id] = MobAppearance(white.creature.appearance)
        #expect(MapContent(session: session).creatures.count == 2) // Named Berry is independently shown.
        session.visibility.creatures.remove(.named)
        #expect(MapContent(session: session).creatures == [white])
        session.selection.choose(.creature(red.id))
        #expect(session.visibility.mobAppearances[kind.id] == MobAppearance(white.creature.appearance))
        #expect(MapContent(session: session).creatures.count == 2)
        session.selection.choose(.mobCreature(red.id))
        #expect(session.visibility.mobAppearances[kind.id] == nil)
        #expect(session.selection.mapSelection == .creature(red) && session.map?.viewport.center == red.position)
        #expect(MapContent(session: session).creatures.count == 2)
        var disclosure = SidebarDisclosure()
        disclosure.collapsedSections.insert(.mobs)
        disclosure.selectOnMap(.row(.mobCreature(red.id)), y: red.creature.y, in: session)
        #expect(!disclosure.collapsedSections.contains(.mobs) && disclosure.mobTypes == [kind.id])
        session.selection.choose(.creature(red.id))
        #expect(MapContent(session: session).creatures.count == 2)
        session.visibility.mobTypes = []
        #expect(MapContent(session: session).creatures == [red])
        session.search.text = "creature:axolotl"
        await session.search.waitForSearch()
        let hit = try #require(session.search.results.first)
        session.selection.choose(.hit(query: session.search.text, id: hit.id))
        #expect(session.visibility.mobTypes == ["minecraft:axolotl"] && !session.visibility.creatures.contains(.mob))
        #expect(MapContent(session: session).creatures.count == 3)
        session.close(); await session.waitUntilClosed()
    }
}
