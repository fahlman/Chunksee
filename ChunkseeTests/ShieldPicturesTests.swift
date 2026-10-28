import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ShieldPicturesTests {
    @Test func premultipliedLayersKeepAlphaOrderAndUntintedInputIntact() throws {
        let base = ItemTexture(width: 1, height: 1, pixels: [0, 0, 255, 255])
        let halfWhite = ItemTexture(width: 1, height: 1, pixels: [128, 128, 128, 128])
        let red = try #require(try base.compositing(halfWhite, color: 0xff0000))
        #expect(red.pixels == [128, 0, 127, 255])
        #expect(base.pixels == [0, 0, 255, 255] && halfWhite.pixels == [128, 128, 128, 128])
        let clear = ItemTexture(width: 1, height: 1, pixels: [0, 0, 0, 0])
        #expect(try clear.compositing(halfWhite, color: 0x00ff00)?.pixels == [0, 128, 0, 128])
        #expect(try red.compositing(clear, color: 0xffffff)?.pixels == red.pixels)
        #expect(try base.compositing(ItemTexture(width: 2, height: 1, pixels: [UInt8](repeating: 0, count: 8)), color: 0xffffff) == nil)
        #expect(try base.compositing(ItemTexture(width: 1, height: 1, pixels: []), color: 0xffffff) == nil)
        #expect(try ItemTexture(width: Int.max, height: 1, pixels: []).compositing(base, color: 0xffffff) == nil)
    }

    @Test func cancelledCompositingPropagatesCancellation() async throws {
        let image = ItemTexture(width: 1, height: 1, pixels: [255, 255, 255, 255])
        let task = Task { try image.compositing(image, color: 0xffffff) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled compositing must throw") }
        catch is CancellationError { }
    }

    @Test func patternsAndBaseColorsHaveSeparateColdAndWarmPictures() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let plainStack = ItemStack(id: "test:shield_front")
        let plain = try #require(try await library.picture(for: plainStack))
        let blue = Self.stack(base: "blue"), striped = Self.stack(base: "blue", layers: [Self.layer("left", color: "red")])
        #expect(library.cachedPicture(for: blue) == nil && library.cachedPicture(for: striped) == nil)
        let blueImage = try #require(try await library.picture(for: blue))
        let stripeImage = try #require(try await library.picture(for: striped))
        #expect(try ItemPictureFixture.pixels(plain).color(24, 32) == [80, 80, 80, 255])
        #expect(try ItemPictureFixture.pixels(blueImage).color(24, 32) == [60, 68, 170, 255])
        let pixels = try ItemPictureFixture.pixels(stripeImage)
        #expect(pixels.color(24, 32) == [176, 46, 38, 255])
        #expect(pixels.color(40, 32) == [60, 68, 170, 255])
        #expect(library.cachedPicture(for: plainStack) === plain)
        #expect(library.cachedPicture(for: blue) === blueImage)
        #expect(library.cachedPicture(for: striped) === stripeImage)
        var renamed = striped
        renamed.count = 64; renamed.customName = "same design"
        #expect(try await library.picture(for: renamed) === stripeImage)
        let first = Self.stack(layers: [Self.layer("full", color: "red"), Self.layer("full", color: "green")])
        let reversed = Self.stack(layers: [Self.layer("full", color: "green"), Self.layer("full", color: "red")])
        let firstImage = try #require(try await library.picture(for: first))
        let reversedImage = try #require(try await library.picture(for: reversed))
        #expect(try ItemPictureFixture.pixels(firstImage).color(24, 32) == [94, 124, 22, 255])
        #expect(try ItemPictureFixture.pixels(reversedImage).color(24, 32) == [176, 46, 38, 255])
        #expect(library.cachedPicture(for: first) === firstImage && library.cachedPicture(for: reversed) === reversedImage)
        await library.close()
        #expect(library.cachedPicture(for: striped) == nil)
        #expect(try await library.picture(for: striped) == nil)
    }

    @Test func patternedPlateNeverPaintsOverTheNearerHandle() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        for back in [false, true] {
            let stack = Self.stack(base: "blue", layers: [Self.layer("full", color: "red")], back: back)
            let picture = try #require(try await library.picture(for: stack))
            let pixels = try ItemPictureFixture.pixels(picture)
            #expect(pixels.color(32, 32) == (back ? [0, 0, 255, 255] : [176, 46, 38, 255]))
            #expect(pixels.color(22, 32) == [176, 46, 38, 255])
            #expect(pixels.color(8, 32) == [0, 0, 0, 0])
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func warmNativeIconRetainsTheSharedPatternedPicture(appearance: ColorScheme) async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library(), stack = Self.stack(base: "blue", layers: [Self.layer("left", color: "red")])
        _ = try #require(try await library.picture(for: stack))
        let renderer = ImageRenderer(content: ItemIcon(item: stack)
            .environment(\.gameArtworkLibrary, library).environment(\.colorScheme, appearance))
        renderer.scale = 4
        let pixels = try ItemPictureFixture.pixels(try #require(renderer.cgImage))
        #expect(pixels.color(30, 40) == [176, 46, 38, 255])
        #expect(pixels.color(50, 40) == [60, 68, 170, 255])
    }

    @Test func missingOrMismatchedLayersNeverReuseAnOrdinaryCachedPicture() async throws {
        for bytes in [Data(), try ItemPictureFixture.png([255, 255, 255, 255], width: 1, height: 1)] {
            let fixture = try Self.fixture(extraFiles: ["assets/test/textures/entity/shield/left.png": bytes])
            defer { fixture.remove() }
            let library = try fixture.library()
            let plainStack = ItemStack(id: "test:shield_front")
            let plain = try #require(try await library.picture(for: plainStack))
            let broken = Self.stack(base: "blue", layers: [Self.layer("left", color: "red")])
            #expect(try await library.picture(for: broken) == nil)
            #expect(library.cachedPicture(for: broken) == nil)
            #expect(library.cachedPicture(for: plainStack) === plain)
            let missing = Self.stack(layers: [Self.layer("unknown", color: "red")])
            #expect(try await library.picture(for: missing) == nil)
            let removed = ItemStack(id: "test:shield_front", components: .compound([
                "minecraft:base_color": .string("blue"), "minecraft:banner_patterns": .list(.compound, [Self.layer("left", color: "red")]),
                "!minecraft:base_color": .compound([:]), "!minecraft:banner_patterns": .compound([:])
            ]))
            let removedImage = try #require(try await library.picture(for: removed))
            #expect(try ItemPictureFixture.pixels(removedImage).bytes == ItemPictureFixture.pixels(plain).bytes)
            #expect(library.cachedPicture(for: removed) === removedImage)
        }
    }

    @Test func composedSkinAndSourceTexturesShareTheExistingRetentionBudget() throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let assets = try #require(try GameAssets(contentsOf: fixture.jar))
        let stack = Self.stack(layers: [Self.layer("left", color: "red"), Self.layer("full", color: "green")])
        let selection = try #require(stack.itemModelSelection)
        let item = try #require(assets.itemModel(for: selection))
        let large = ItemTexture(width: 1024, height: 1024, pixels: [UInt8](repeating: 255, count: 1024 * 1024 * 4))
        // Base, composed output and three distinct layer sources would retain twenty MiB.
        #expect(try GameModelRenderer.render(item, colors: [[]], texture: { _ in large }) == nil)
    }

    private static func layer(_ name: String, color: String) -> NBT {
        .compound(["pattern": .string("test:" + name), "color": .string(color)])
    }

    private static func stack(base: String? = nil, layers: [NBT] = [], back: Bool = false) -> ItemStack {
        var components: [String: NBT] = ["minecraft:banner_patterns": .list(.compound, layers)]
        if let base { components["minecraft:base_color"] = .string(base) }
        return ItemStack(id: back ? "test:shield_back" : "test:shield_front", components: .compound(components))
    }

    private static func fixture(extraFiles: [String: Data] = [:]) throws -> ItemPictureFixture {
        var files = [String: Data]()
        for (view, rotation, translation) in [("front", [0, 0, 0], [4, 4, 0]), ("back", [0, 180, 0], [-4, 4, 0])] {
            let id = "shield_" + view
            files["assets/test/items/\(id).json"] = try ItemPictureFixture.json(["model": [
                "type": "condition", "property": "using_item", "transformation": [
                    "left_rotation": [0, 0, 0, 1], "right_rotation": [0, 0, 0, 1],
                    "scale": [1, -1, -1], "translation": [0, 0, 0]
                ], "on_false": ["type": "special", "base": "test:item/" + id, "model": ["type": "shield"]]
            ]])
            files["assets/test/models/item/\(id).json"] = try ItemPictureFixture.json([
                "gui_light": "front", "display": ["gui": ["rotation": rotation, "translation": translation, "scale": [0.5, 0.5, 0.5]]]
            ])
        }
        var skin = [UInt8](repeating: 0, count: 64 * 64 * 4), mask = skin, left = skin
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                let handle = (6..<12).contains(y) && ((32..<34).contains(x) || (40..<42).contains(x))
                skin.replaceSubrange(i..<i + 4, with: handle ? [0, 0, 255, 255] : [80, 80, 80, 255])
                if !handle {
                    mask.replaceSubrange(i..<i + 4, with: [255, 255, 255, 255])
                    if x < 7 { left.replaceSubrange(i..<i + 4, with: [255, 255, 255, 255]) }
                }
            }
        }
        for name in ["shield_base_nopattern", "shield_base"] {
            files["assets/minecraft/textures/entity/shield/\(name).png"] = try ItemPictureFixture.png(skin, width: 64, height: 64)
        }
        files["assets/minecraft/textures/entity/shield/base.png"] = try ItemPictureFixture.png(mask, width: 64, height: 64)
        for (name, pixels) in [("full", mask), ("left", left)] {
            files["data/test/banner_pattern/\(name).json"] = try ItemPictureFixture.json(["asset_id": "test:" + name, "translation_key": "test." + name])
            files["assets/test/textures/entity/shield/\(name).png"] = try ItemPictureFixture.png(pixels, width: 64, height: 64)
        }
        files.merge(extraFiles) { _, replacement in replacement }
        return try ItemPictureFixture(extraFiles: files)
    }
}
