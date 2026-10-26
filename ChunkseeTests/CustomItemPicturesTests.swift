import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct CustomItemPicturesTests {
    @Test(arguments: ["floats", "flags", "strings"])
    func savedModelChoicesHaveSeparateColdAndWarmPictures(field: String) async throws {
        let node: [String: Any]
        let firstValue: NBT, secondValue: NBT
        switch field {
        case "floats":
            node = ["type": "range_dispatch", "property": "custom_model_data", "fallback": Self.model("red"),
                    "entries": [["threshold": 0, "model": Self.model("red")], ["threshold": 1, "model": Self.model("blue")]]]
            firstValue = .intArray([0]); secondValue = .intArray([1])
        case "flags":
            node = ["type": "condition", "property": "custom_model_data", "on_false": Self.model("red"), "on_true": Self.model("blue")]
            firstValue = .byteArray([0]); secondValue = .byteArray([1])
        default:
            node = ["type": "select", "property": "custom_model_data", "fallback": Self.model("red"),
                    "cases": [["when": "blue", "model": Self.model("blue")]]]
            firstValue = .list(.string, [.string("")]); secondValue = .list(.string, [.string("blue")])
        }
        let fixture = try Self.fixture(node)
        defer { fixture.remove() }
        let library = try fixture.library()
        let first = Self.stack([field: firstValue]), second = Self.stack([field: secondValue])
        let red = try #require(try await library.picture(for: first))
        #expect(library.cachedPicture(for: second) == nil)
        let blue = try #require(try await library.picture(for: second))
        #expect(try ItemPictureFixture.pixels(red).color(32, 32) == [255, 0, 0, 255])
        #expect(try ItemPictureFixture.pixels(blue).color(32, 32) == [0, 0, 255, 255])
        #expect(library.cachedPicture(for: first) === red)
        #expect(library.cachedPicture(for: second) === blue)
        #expect(try await library.picture(for: first) === red)
        var renamed = second
        renamed.count = 64; renamed.customName = "Same appearance"
        #expect(library.cachedPicture(for: renamed) === blue)
        await library.close()
        #expect(library.cachedPicture(for: first) == nil)
        #expect(try await library.picture(for: second) == nil)
    }

    @Test func customColorsDoNotReuseAnotherStacksCachedModelTint() async throws {
        let fixture = try Self.fixture(Self.model("white", tints: [["type": "custom_model_data", "default": 0x00ff00]]))
        defer { fixture.remove() }
        let library = try fixture.library()
        let red = Self.stack(["colors": .intArray([0xff0000])])
        let blue = Self.stack(["colors": .intArray([0x0000ff])])
        let redImage = try #require(try await library.picture(for: red))
        #expect(library.cachedPicture(for: blue) == nil)
        let blueImage = try #require(try await library.picture(for: blue))
        let ordinary = Self.stack([:])
        let greenImage = try #require(try await library.picture(for: ordinary))
        for (stack, image, color) in [(red, redImage, [UInt8(255), 0, 0, 255]),
                                       (blue, blueImage, [0, 0, 255, 255]), (ordinary, greenImage, [0, 255, 0, 255])] {
            #expect(try ItemPictureFixture.pixels(image).color(32, 32) == color)
            #expect(library.cachedPicture(for: stack) === image)
            #expect(try await library.picture(for: stack) === image)
        }
        let removed = ItemStack(id: "test:custom", components: .compound([
            "!minecraft:custom_model_data": .compound([:]), "CustomModelData": .int(1)
        ]))
        #expect(library.cachedPicture(for: removed) == nil)
        let removedImage = try #require(try await library.picture(for: removed))
        #expect(try ItemPictureFixture.pixels(removedImage).bytes == ItemPictureFixture.pixels(greenImage).bytes)
        #expect(library.cachedPicture(for: removed) === removedImage)
        let bad = ItemStack(id: "test:custom", components: .compound(["minecraft:custom_model_data": .string("bad")]))
        #expect(library.cachedPicture(for: bad) == nil)
        #expect(try await library.picture(for: bad) == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeItemIconUsesItsOwnSavedChoiceImmediately(appearance: ColorScheme) async throws {
        let fixture = try Self.fixture(Self.model("white", tints: [["type": "custom_model_data", "default": 0]]))
        defer { fixture.remove() }
        let library = try fixture.library()
        let other = Self.stack(["colors": .intArray([0xff0000])]), selected = Self.stack(["colors": .intArray([0x0000ff])])
        _ = try #require(try await library.picture(for: other))
        _ = try #require(try await library.picture(for: selected))
        let renderer = ImageRenderer(content: ItemIcon(item: selected)
            .environment(\.gameAssetLibrary, library).environment(\.colorScheme, appearance))
        renderer.scale = 4
        let pixels = try ItemPictureFixture.pixels(try #require(renderer.cgImage))
        #expect(pixels.color(40, 40) == [0, 0, 255, 255])
    }

    @Test func exactUnicodeSelectionKeysDoNotCollapseVisuallySimilarStrings() async throws {
        let node: [String: Any] = ["type": "select", "property": "custom_model_data", "fallback": Self.model("white"),
            "cases": [["when": "é", "model": Self.model("red")], ["when": "e\u{301}", "model": Self.model("blue")]]]
        let fixture = try Self.fixture(node)
        defer { fixture.remove() }
        let library = try fixture.library()
        let composed = Self.stack(["strings": .list(.string, [.string("é")])])
        let decomposed = Self.stack(["strings": .list(.string, [.string("e\u{301}")])])
        let red = try #require(try await library.picture(for: composed))
        #expect(library.cachedPicture(for: decomposed) == nil)
        let blue = try #require(try await library.picture(for: decomposed))
        #expect(try ItemPictureFixture.pixels(red).color(32, 32) == [255, 0, 0, 255])
        #expect(try ItemPictureFixture.pixels(blue).color(32, 32) == [0, 0, 255, 255])
        #expect(library.cachedPicture(for: composed) === red)
        #expect(library.cachedPicture(for: decomposed) === blue)
    }

    private static func stack(_ fields: [String: NBT]) -> ItemStack {
        ItemStack(id: "test:custom", components: .compound(["minecraft:custom_model_data": .compound(fields)]))
    }

    private static func model(_ texture: String, tints: [[String: Any]] = []) -> [String: Any] {
        ["type": "model", "model": "test:item/custom_" + texture, "tints": tints]
    }

    private static func fixture(_ node: [String: Any]) throws -> ItemPictureFixture {
        var files = ["assets/test/items/custom.json": try ItemPictureFixture.json(["model": node])]
        for color in ["red", "blue", "white"] {
            files["assets/test/models/item/custom_\(color).json"] = try ItemPictureFixture.json([
                "parent": "builtin/generated", "textures": ["layer0": "test:item/" + color]
            ])
        }
        return try ItemPictureFixture(extraFiles: files)
    }
}
