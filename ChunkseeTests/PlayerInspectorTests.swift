import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct PlayerInspectorTests {
    let owner = UUID(uuidString: "00000001-0000-0002-0000-000300000004")!
    let otherOwner = UUID(uuidString: "00000005-0000-0006-0000-000700000008")!

    func pet(_ name: String, owner: UUID, x: Double, entityID: UUID = UUID()) -> NBT {
        .compound(["id": .string("minecraft:wolf"), "Health": .float(40), "CustomName": .string(name),
                   "UUID": .string(entityID.uuidString), "Owner": .string(owner.uuidString),
                   "Pos": .list([.double(x), .double(64), .double(4)])])
    }

    @discardableResult func savePets(_ pets: [NBT], in world: URL, dimension: String = "overworld") throws -> URL {
        let directory = world.appendingPathComponent("dimensions/minecraft/\(dimension)/entities")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("r.0.0.mca")
        let nbt = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list(pets)])
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: nbt)])).write(to: file)
        return file
    }

    func makeWorld() throws -> URL {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk])
        let nether = url.appendingPathComponent("dimensions/minecraft/the_nether/region")
        try FileManager.default.createDirectory(at: nether, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([chunk])).write(to: nether.appendingPathComponent("r.0.0.mca"))
        try savePets([pet("Summer", owner: owner, x: 4), pet("Summer", owner: otherOwner, x: 8)], in: url)
        try savePets([pet("Nether Wolf", owner: owner, x: 12)], in: url, dimension: "the_nether")
        return url
    }

    func open(_ url: URL) async throws -> WorldSession {
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        await session.search.waitForIndex()
        return session
    }

    @Test func linkedPetsUseOwnerIDsAcrossDimensionsAndStayInTheirWorld() async throws {
        let firstURL = try makeWorld(), secondURL = try makeWorld()
        defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
        try savePets([pet("Other World", owner: owner, x: 4)], in: secondURL)
        let first = try await open(firstURL), second = try await open(secondURL)
        defer { first.close(); second.close() }
        #expect(Set(first.linkedPets(to: owner).map(\.name)) == ["Summer", "Nether Wolf"])
        #expect(first.linkedPets(to: otherOwner).map(\.name) == ["Summer"])
        #expect(first.linkedPets(to: UUID()).isEmpty)
        #expect(second.linkedPets(to: owner).contains { $0.name == "Other World" })
        #expect(!first.linkedPets(to: owner).contains { $0.name == "Other World" })
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed()
    }

    @Test func linkedPetJumpOpensAndSelectsInTheDestinationDocument() async throws {
        let url = try makeWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await open(url)
        let target = WorldSession(resources: source.resources, dimensionID: "minecraft:the_nether")
        defer { source.close(); target.close() }
        let initial = MapViewport(center: CGPoint(x: 100, y: 200), scale: 0.5)
        let targetInitial = MapViewport(center: CGPoint(x: 20, y: 30), scale: 4)
        source.map?.viewport = initial
        target.map?.viewport = targetInitial
        source.inspector = .player(owner)
        let (opens, continuation) = AsyncStream.makeStream(of: URL.self)
        source.openDocument = { continuation.yield($0) }
        var opened = opens.makeAsyncIterator()
        let pet = try #require(source.linkedPets(to: owner).first { $0.dimension == "minecraft:the_nether" })
        source.showLinkedPet(pet, ownedBy: owner)
        let requested = await opened.next(isolation: #isolation)
        #expect(requested == source.resources.documentURL(for: "minecraft:the_nether"))
        #expect(source.selectedDimensionID == "minecraft:overworld" && source.map?.viewport == initial)
        #expect(source.inspector == .player(owner))
        #expect(source.sidebarRevealRequest == nil && target.sidebarRevealRequest != nil)
        #expect(target.currentSelection == .creature(pet) && target.sidebarSelection == .creature(pet.id))
        #expect(target.map?.viewport.center == pet.position && target.map?.viewport.scale == 4)
        #expect(target.visibility.creatures.contains(.pet))
        target.goBack()
        #expect(target.map?.viewport == targetInitial)
        source.close(); target.close()
        await source.waitUntilClosed(); await target.waitUntilClosed()
    }

    @Test func aPetJumpWaitsForItsDocumentAndRepeatedLinksRequestRevealAgain() async throws {
        let url = try makeWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await open(url)
        defer { source.close() }
        let (opens, continuation) = AsyncStream.makeStream(of: URL.self)
        source.openDocument = { continuation.yield($0) }
        var opened = opens.makeAsyncIterator()
        let pet = try #require(source.linkedPets(to: owner).first { $0.dimension == "minecraft:the_nether" })
        source.showLinkedPet(pet, ownedBy: owner)
        let requested = await opened.next(isolation: #isolation)
        #expect(requested == source.resources.documentURL(for: pet.dimension))
        #expect(source.sidebarRevealRequest == nil && source.sidebarSelection == nil)

        // The destination receives the queued jump during creation, before its SwiftUI view exists.
        let target = WorldSession(resources: source.resources, dimensionID: pet.dimension)
        defer { target.close() }
        let firstReveal = try #require(target.sidebarRevealRequest)
        #expect(target.sidebarSelection == .creature(pet.id) && target.currentSelection == .creature(pet))
        target.showLinkedPet(pet, ownedBy: owner)
        #expect(target.sidebarRevealRequest != firstReveal)
        #expect(target.sidebarSelection == .creature(pet.id) && target.currentSelection == .creature(pet))
        source.close(); target.close()
        await source.waitUntilClosed(); await target.waitUntilClosed()
    }

    @Test func linkedPetActivationRechecksRefreshedOwnership() async throws {
        let url = try makeWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await open(url)
        defer { session.close() }
        let old = try #require(session.linkedPets(to: owner).first { $0.dimension == "minecraft:overworld" })
        let initial = session.map?.viewport
        let file = try savePets([pet("Summer", owner: otherOwner, x: 4, entityID: try #require(old.creature.uuid))], in: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        session.search.rebuild(firstDimension: session.selectedDimensionID)
        await session.search.waitForIndex()
        #expect(!session.linkedPets(to: owner).contains { $0.dimension == "minecraft:overworld" })
        session.showLinkedPet(old, ownedBy: owner)
        #expect(session.selection == nil && session.map?.viewport == initial && session.sidebarRevealRequest == nil)
        session.close()
        session.showLinkedPet(old, ownedBy: otherOwner)
        #expect(session.selection == nil && session.sidebarRevealRequest == nil)
        await session.waitUntilClosed()
    }

    @Test func itemDetailsNameEnchantmentsAndSavedWearAndEffectsUseSavedDurations() throws {
        let item = try #require(ItemStack(.compound(["id": .string("minecraft:diamond_sword"), "components": .compound([
            "minecraft:damage": .int(61), "minecraft:enchantments": .compound(["minecraft:sharpness": .int(5), "minecraft:mending": .int(1)]),
        ])])))
        let text = ItemAppearance.details(of: item)
        // The user's locale can group durability counts (for example, 1,500).
        let expectedWear = String(localized: "Durability: \(1500) of \(1561)")
        #expect(text.contains("Sharpness V") && text.contains("Mending") && text.contains(expectedWear))
        #expect(!ItemAppearance.details(of: ItemStack(id: "minecraft:apple")).contains("Durability"))
        #expect(PlayerEffectText.duration(.init(id: "minecraft:strength", amplifier: 1, durationTicks: 1680)) == "1:24")
        #expect(PlayerEffectText.duration(.init(id: "minecraft:strength", amplifier: 0, durationTicks: 1)) == "0:01")
        #expect(PlayerEffectText.duration(.init(id: "minecraft:strength", amplifier: 0, durationTicks: 72000)) == "1:00:00")
        #expect(PlayerEffectText.duration(.init(id: "minecraft:night_vision", amplifier: 0, durationTicks: -1)) == "Infinite")
    }

    @Test func coLocatedPetsStayDistinctAndSavedMovementKeepsSelectionAndLinks() async throws {
        let url = try makeWorld(), firstID = UUID(), secondID = UUID()
        defer { try? FileManager.default.removeItem(at: url) }
        try savePets([pet("Summer", owner: owner, x: 4, entityID: firstID), pet("Luna", owner: owner, x: 4, entityID: secondID)], in: url)
        let session = try await open(url)
        defer { session.close() }
        let first = try #require(session.linkedPets(to: owner).first { $0.creature.uuid == firstID })
        let second = try #require(session.linkedPets(to: owner).first { $0.creature.uuid == secondID })
        #expect(first.id != second.id && first.position == second.position)
        session.showLinkedPet(second, ownedBy: owner)
        #expect(session.currentSelection == .creature(second))
        session.showLinkedPet(first, ownedBy: owner)
        let file = try savePets([pet("Renamed", owner: owner, x: 12, entityID: firstID), pet("Luna", owner: owner, x: 4, entityID: secondID)], in: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        session.search.rebuild(firstDimension: session.selectedDimensionID)
        await session.search.waitForIndex()
        let moved = try #require(session.linkedPets(to: owner).first { $0.creature.uuid == firstID })
        #expect(moved.id == first.id && moved.position != first.position && moved.name == "Renamed")
        #expect(session.currentSelection == .creature(moved))
        session.showLinkedPet(first, ownedBy: owner)
        #expect(session.map?.viewport.center == moved.position && session.currentSelection == .creature(moved))
        session.close()
        await session.waitUntilClosed()
    }

    @Test func selectedPlayerDetailsRefreshFromSavedPlayerData() async throws {
        let url = try makeWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("players/data/\(owner.uuidString.lowercased()).dat")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func save(health: Float, effects: [NBT], healthBoost: Double = 0) throws {
            let nbt = NBT.compound(["DataVersion": .int(5023), "Health": .float(health), "active_effects": .list(effects),
                "attributes": .list([.compound(["id": .string("minecraft:max_health"), "base": .double(20),
                    "modifiers": .list(healthBoost == 0 ? [] : [.compound(["id": .string("minecraft:effect.health_boost"),
                        "amount": .double(healthBoost), "operation": .string("add_value")])])])]),
                "Dimension": .string("minecraft:overworld"), "Pos": .list([.double(0), .double(64), .double(0)]),
                "SelectedItemSlot": .int(0), "Inventory": .list([.compound(["id": .string("minecraft:diamond_sword"), "Slot": .byte(0),
                    "components": .compound(["minecraft:damage": .int(61)])])]),
            ])
            try Data(Compression.deflate(nbt.serialized(), gzip: true)).write(to: file)
        }
        try save(health: 20, effects: [])
        let session = try await open(url)
        defer { session.close() }
        session.inspector = .player(owner)
        let old = try #require(session.players.first { $0.uuid == owner })
        #expect(old.maxHealth == 20 && old.activeEffects.isEmpty)
        try save(health: 28, effects: [.compound(["id": .string("minecraft:health_boost"), "amplifier": .byte(2), "duration": .int(1200)])], healthBoost: 12)
        session.resources.refreshDelay = .zero
        session.resources.worldChanged([file])
        await session.resources.waitForRefresh()
        let current = try #require(session.players.first { $0.uuid == owner })
        #expect(session.inspector == .player(owner))
        #expect(current.health == 28 && current.maxHealth == 32 && current.activeEffects.first?.level == 3)
        #expect(current.mainHandItem?.durability?.remaining == 1500)
        #expect(old.health == 20 && old.activeEffects.isEmpty)
        session.close()
        await session.waitUntilClosed()
    }
}
