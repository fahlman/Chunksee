import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct InspectorPicturesTests {
    @Test func gameRelationshipsFeedTheExistingPictureRenderer() async throws {
        var files: [String: Data] = [:]
        for item in ["parrot_spawn_egg", "villager_spawn_egg", "oak_sign", "red_bed", "spawner", "filled_map"] {
            files["assets/minecraft/items/\(item).json"] = try ItemPictureFixture.json([
                "model": ["type": "minecraft:model", "model": "test:item/flat"]
            ])
        }
        let fixture = try ItemPictureFixture(dataVersion: 5024, extraFiles: files)
        defer { fixture.remove() }
        let library = try fixture.library()
        let parrot = try #require(try await library.data.spawnEgg(for: "minecraft:parrot"))
        let villager = try #require(try await library.data.spawnEgg(for: "minecraft:villager"))
        let sign = try #require(try await library.data.blockItem(for: BlockState("minecraft:oak_wall_sign")))
        let bed = try #require(try await library.data.blockItem(for: BlockState("minecraft:red_bed")))
        let spawner = try #require(try await library.data.blockItem(for: BlockState("minecraft:spawner")))
        #expect(parrot.id == "minecraft:parrot_spawn_egg")
        #expect(villager.id == "minecraft:villager_spawn_egg")
        #expect(sign.id == "minecraft:oak_sign")
        #expect(bed.id == "minecraft:red_bed")
        #expect(spawner.id == "minecraft:spawner")
        for item in [parrot, villager, sign, bed, spawner, ItemStack(id: "minecraft:filled_map")] {
            let picture = try #require(try await library.picture(for: item))
            #expect(library.cachedPicture(for: item) === picture)
            #expect(try ItemPictureFixture.pixels(picture).color(8, 8) == [255, 0, 0, 255])
        }
        #expect(try await library.data.spawnEgg(for: "minecraft:player") == nil)
        #expect(try await library.data.spawnEgg(for: "test:mob_without_an_egg") == nil)
        #expect(try await library.data.spawnEgg(for: "minecraft:zombie") == nil, "An unreadable egg definition keeps the concept symbol")
        #expect(try await library.data.blockItem(for: BlockState("minecraft:nether_portal")) == nil)
        #expect(try await library.data.blockItem(for: BlockState("test:unknown")) == nil)
        await library.close()
    }

    @Test func headingUsesThePictureAndKeepsItsConceptFallbackInBothAppearances() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library(), item = ItemStack(id: "test:flat")
        _ = try #require(try await library.picture(for: item))
        for appearance in [ColorScheme.light, .dark] {
            func render(_ picture: InspectorHeading.Picture?, library: GameArtworkLibrary?) throws -> ItemTexture {
                let renderer = ImageRenderer(content: InspectorHeading(title: Text("Heading"), symbol: "pawprint.fill", picture: picture)
                    .environment(\.gameArtworkLibrary, library).environment(\.colorScheme, appearance))
                renderer.scale = 4
                let image = try #require(renderer.cgImage)
                return try #require(ItemTexture(png: ItemPictureFixture.png(image)))
            }
            let fallback = try render(nil, library: nil)
            let absent = try render(.item(item), library: nil)
            #expect(absent.pixels == fallback.pixels)
            let loaded = try render(.item(item), library: library)
            #expect(loaded.pixels != fallback.pixels)
            #expect(loaded.width == fallback.width && loaded.height == fallback.height)
            let colors = Set(stride(from: 0, to: loaded.pixels.count, by: 4).map { Array(loaded.pixels[$0..<$0 + 4]) })
            #expect(colors.contains([255, 0, 0, 255]) && colors.contains([0, 255, 0, 255]))
        }
        await library.close()
    }

    @Test func blockHeadingReadsTheSavedBlockInsteadOfThePOIType() async throws {
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: -1, z: 0, palette: ["minecraft:red_bed"]) { _, _, _ in 0 }])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let marker = PlaceMarker(PointOfInterest(type: "minecraft:home", x: -2, y: 3, z: 4, freeTickets: 0))
        let position = try #require(marker.blockPosition)
        #expect(position == BlockPosition(blockX: -2, blockY: 3, blockZ: 4))
        let block = await session.resources.headingBlock(at: position, in: "minecraft:overworld")
        #expect(block?.id == "minecraft:red_bed")
        session.close()
        await session.waitUntilClosed()
        #expect(await session.resources.headingBlock(at: position, in: "minecraft:overworld") == nil)
    }

    @Test func artworkChoiceUpdatesTheHeadingOfAnOpenWorld() async throws {
        let root = try TestWorld.make(chunks: []), fixture = try ItemPictureFixture()
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(fixture.root)
        let world = try WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
        defer { world.close() }
        world.refreshGameAssets()
        await world.waitForRefresh()
        let source = WorldGameAssetSource(generation: names.minecraft.generation)
        let artwork = try #require(world.gameArtworkLibrary(for: source)), item = ItemStack(id: "test:flat")
        _ = try #require(try await artwork.picture(for: item))

        func render(_ picture: InspectorHeading.Picture?) throws -> ItemTexture {
            let renderer = ImageRenderer(content: InspectorHeading(title: Text("Heading"), symbol: "pawprint.fill", picture: picture)
                .modifier(WorldGameAssets(world: world)))
            renderer.scale = 4
            let image = try #require(renderer.cgImage)
            return try #require(ItemTexture(png: ItemPictureFixture.png(image)))
        }
        let fallback = try render(nil), original = try render(.item(item))
        #expect(original.pixels != fallback.pixels)
        names.minecraft.usesGameArtwork = false
        await world.waitForRefresh()
        #expect(world.gameArtworkLibrary(for: source) == nil)
        #expect(try render(.item(item)).pixels == fallback.pixels)
        // The data owner remains live even though pictures are no longer exposed.
        try await artwork.data.checkAvailable()
        names.minecraft.usesGameArtwork = true
        await world.waitForRefresh()
        #expect(world.gameArtworkLibrary(for: source) === artwork)
        #expect(try render(.item(item)).pixels == original.pixels)
        world.close()
        await world.waitUntilClosed()
        names.minecraft.forget()
        await names.minecraft.waitUntilIdle()
    }

    @Test func movingLootContainersHaveNoBlockPictureLocation() throws {
        let containers = ItemContainer.containers(inEntityChunk: .compound(["Entities": .list([.compound([
            "id": .string("minecraft:chest_minecart"), "Pos": .list([.double(-2.5), .double(3), .double(4)]),
            "LootTable": .string("test:unopened")
        ])])]))
        let container = try #require(containers.first)
        let marker = try #require(PlaceMarker(unopened: container))
        #expect(marker.blockPosition == nil)
    }

    @Test func closingTheWorldCancelsAndDiscardsAnInFlightHeadingRead() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let gate = AsyncReadGate<BlockState?>()
        session.resources.readHeadingBlock = { _, _ in await gate.read("block") }
        let read = Task { await session.resources.headingBlock(at: .init(blockX: 0, blockY: 1, blockZ: 0), in: "minecraft:overworld") }
        await gate.waitForRequest("block")
        session.close()
        await gate.waitForCancellation("block")
        await gate.finish("block", with: BlockState("minecraft:spawner"))
        #expect(await read.value == nil)
        await session.waitUntilClosed()
    }

    @Test func cancelingOneHeadingDoesNotCancelItsSibling() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let gate = AsyncReadGate<BlockState?>()
        session.resources.readHeadingBlock = { _, position in await gate.read(String(position.x)) }
        let first = Task { await session.resources.headingBlock(at: .init(blockX: 1, blockY: 1, blockZ: 0), in: "minecraft:overworld") }
        let second = Task { await session.resources.headingBlock(at: .init(blockX: 2, blockY: 1, blockZ: 0), in: "minecraft:overworld") }
        await gate.waitForRequest("1")
        await gate.waitForRequest("2")
        first.cancel()
        await gate.waitForCancellation("1")
        await gate.finish("2", with: BlockState("minecraft:red_bed"))
        #expect(await second.value?.id == "minecraft:red_bed")
        await gate.finish("1", with: BlockState("minecraft:spawner"))
        #expect(await first.value == nil)
        #expect(!session.resources.isClosed)
        session.close()
        await session.waitUntilClosed()
    }
}
