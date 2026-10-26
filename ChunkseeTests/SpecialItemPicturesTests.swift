import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SpecialItemPicturesTests {
    @Test func staticModelsUseSharedPixelsAndWarmCacheIdentity() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        for name in Self.staticItems {
            let stack = ItemStack(id: "test:" + name)
            #expect(library.cachedPicture(for: stack) == nil)
            let image = try #require(try await library.picture(for: stack))
            #expect(Self.count(Self.skinColor, in: try ItemPictureFixture.pixels(image)) > 0)
            #expect(library.cachedPicture(for: stack) === image)
            var renamed = stack; renamed.customName = "same model"; renamed.count = 12
            #expect(try await library.picture(for: renamed) === image)
        }
        let standing = try ItemPictureFixture.pixels(#require(try await library.picture(for: ItemStack(id: "test:standing"))))
        let sitting = try ItemPictureFixture.pixels(#require(try await library.picture(for: ItemStack(id: "test:sitting"))))
        #expect(standing.bytes != sitting.bytes)
        await library.close()
        #expect(library.cachedPicture(for: ItemStack(id: "test:skeleton")) == nil)
    }

    @Test func potSidesKeepTheirOwnPicturesThroughColdAndWarmCaches() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let first = Self.pot(front: "red", left: "blue"), reversed = Self.pot(front: "blue", left: "red")
        let image = try #require(try await library.picture(for: first))
        let other = try #require(try await library.picture(for: reversed))
        let pixels = try ItemPictureFixture.pixels(image), otherPixels = try ItemPictureFixture.pixels(other)
        #expect(Self.count([255, 0, 0, 255], in: pixels) > 0 && Self.count([0, 0, 255, 255], in: pixels) > 0)
        #expect(pixels.bytes != otherPixels.bytes)
        #expect(library.cachedPicture(for: first) === image && library.cachedPicture(for: reversed) === other)
        var renamed = first; renamed.count = 64; renamed.customName = "same pot"
        #expect(try await library.picture(for: renamed) === image)
        let missing = Self.pot(front: "missing")
        #expect(try await library.picture(for: missing) == nil && library.cachedPicture(for: missing) == nil)
        #expect(library.cachedPicture(for: first) === image)
    }

    @Test func playerProfilesHaveDistinctPicturesAndUnresolvedSkinsKeepTheFallback() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let plain = ItemStack(id: "test:player_head")
        let defaultImage = try #require(try await library.picture(for: plain))
        func head(_ profile: NBT) -> ItemStack {
            ItemStack(id: plain.id, components: .compound(["minecraft:profile": profile]))
        }
        let red = head(.compound(["texture": .string("test:heads/red")])),
            blue = head(.compound(["texture": .string("test:heads/blue")]))
        let redImage = try #require(try await library.picture(for: red)),
            blueImage = try #require(try await library.picture(for: blue))
        #expect(Self.count([255, 0, 0, 255], in: try ItemPictureFixture.pixels(redImage)) > 0)
        #expect(Self.count([0, 0, 255, 255], in: try ItemPictureFixture.pixels(blueImage)) > 0)
        #expect(library.cachedPicture(for: red) === redImage && library.cachedPicture(for: blue) === blueImage)
        let same = head(.compound(["texture": .string("test:heads/red"), "name": .string("Other name"),
                                  "cape": .string("test:other"), "model": .string("wide")]))
        #expect(try await library.picture(for: same) === redImage)
        for profile: NBT in [.string("Someone"), .compound(["id": .intArray([1, 2, 3, 4])]),
                             .compound(["texture": .int(1)]), .compound(["texture": .string("test:missing")])] {
            let item = head(profile)
            #expect(try await library.picture(for: item) == nil && library.cachedPicture(for: item) == nil)
        }
        let removed = ItemStack(id: plain.id, components: .compound([
            "minecraft:profile": .string("Someone"), "!minecraft:profile": .compound([:])
        ]))
        let removedImage = try #require(try await library.picture(for: removed))
        #expect(try ItemPictureFixture.pixels(removedImage).bytes == ItemPictureFixture.pixels(defaultImage).bytes)
        #expect(library.cachedPicture(for: removed) === removedImage)
        #expect(library.cachedPicture(for: plain) === defaultImage)
        await library.close()
        #expect(library.cachedPicture(for: red) == nil)
    }

    @Test func oversizedLocalSkinIdentityIsChargedEvenWhenTheSelectedModelDoesNotUseIt() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        // Components may remain after an item_model override. A valid but unused skin ID
        // still belongs to the cache key, and must not escape its 8 MiB image budget.
        let item = ItemStack(id: "test:player_head", components: .compound([
            "minecraft:item_model": .string("test:plain_picture"),
            "minecraft:profile": .compound(["texture": .string("test:" + String(repeating: "a", count: 9 * 1024 * 1024))])
        ]))
        let image = try #require(try await library.picture(for: item))
        #expect(Self.count(Self.skinColor, in: try ItemPictureFixture.pixels(image)) > 0)
        #expect(library.cachedPicture(for: item) == nil)
        await library.close()
    }

    @Test func rectangularStaticSkinsAcceptMatchingResolutionButRejectUnknownStrips() async throws {
        let ordinary = try Self.fixture()
        defer { ordinary.remove() }
        let doubled = try Self.fixture(overrides: ["assets/test/textures/entity/heads/skeleton.png":
            Self.png(Self.skinColor, width: 128, height: 64)])
        defer { doubled.remove() }
        let mismatch = try Self.fixture(overrides: ["assets/test/textures/entity/heads/skeleton.png":
            Self.png(Self.skinColor, width: 64, height: 64)])
        defer { mismatch.remove() }
        let first = try ordinary.library(), second = try doubled.library(), invalid = try mismatch.library()
        let stack = ItemStack(id: "test:skeleton")
        let firstPixels = try ItemPictureFixture.pixels(#require(try await first.picture(for: stack)))
        let secondPixels = try ItemPictureFixture.pixels(#require(try await second.picture(for: stack)))
        #expect(firstPixels.bytes == secondPixels.bytes)
        #expect(try await invalid.picture(for: stack) == nil)
        for name in ["ordinary_strip", "missing_head", "animated_head"] {
            let unsupported = ItemStack(id: "test:" + name)
            #expect(try await first.picture(for: unsupported) == nil && first.cachedPicture(for: unsupported) == nil)
        }
    }

    @Test func oversizedPotIdentityCanDrawWithoutBeingRetainedAsAnImage() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        // The explicit known pattern makes the long template ID valid but irrelevant to pixels.
        // Its retained bytes still exceed the image cache's 8 MiB budget.
        let longID = "test:" + String(repeating: "a", count: 9 * 1024 * 1024)
        let stack = Self.pot(front: "red", itemID: longID)
        let image = try #require(try await library.picture(for: stack))
        #expect(Self.count([255, 0, 0, 255], in: try ItemPictureFixture.pixels(image)) > 0)
        #expect(library.cachedPicture(for: stack) == nil)
        await library.close()
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeIconsUseTheSameStaticSkinAndPotPictures(appearance: ColorScheme) async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let redHead = ItemStack(id: "test:player_head", components: .compound([
            "minecraft:profile": .compound(["texture": .string("test:heads/red")])
        ]))
        let red: [UInt8] = [255, 0, 0, 255]
        for (stack, color) in [(ItemStack(id: "test:conduit"), Self.skinColor),
                               (ItemStack(id: "test:skeleton"), Self.skinColor),
                               (ItemStack(id: "test:dragon"), Self.skinColor),
                               (ItemStack(id: "test:player_head"), Self.skinColor), (redHead, red),
                               (Self.pot(front: "red", left: "blue"), red)] {
            _ = try #require(try await library.picture(for: stack))
            let renderer = ImageRenderer(content: ItemIcon(item: stack)
                .environment(\.gameAssetLibrary, library).environment(\.colorScheme, appearance))
            renderer.scale = 4
            let pixels = try ItemPictureFixture.pixels(#require(renderer.cgImage))
            #expect(Self.count(color, in: pixels) > 0)
        }
    }

    private static let skinColor: [UInt8] = [70, 170, 110, 255]
    private static let staticItems = ["conduit", "skeleton", "wither_skeleton", "zombie", "creeper", "dragon", "piglin", "player_head", "standing", "sitting"]

    private static func count(_ color: [UInt8], in pixels: ItemPictureFixture.Pixels) -> Int {
        stride(from: 0, to: pixels.bytes.count, by: 4).reduce(0) { total, offset in
            total + (Array(pixels.bytes[offset..<offset + 4]) == color ? 1 : 0)
        }
    }

    private static func pot(front: String, left: String? = nil, itemID: String = "test:template") -> ItemStack {
        func side(_ pattern: String) -> NBT {
            .compound(["id": .string(itemID), "components": .compound([
                "minecraft:provides_pottery_pattern": .string("test:" + pattern)
            ])])
        }
        var sides: [String: NBT] = ["front": side(front)]
        if let left { sides["left"] = side(left) }
        return ItemStack(id: "test:pot", components: .compound(["minecraft:pot_decorations": .compound(sides)]))
    }

    private static func png(_ color: [UInt8], width: Int, height: Int) throws -> Data {
        try ItemPictureFixture.png(Array(repeating: color, count: width * height).flatMap { $0 }, width: width, height: height)
    }

    private static func fixture(overrides: [String: Data] = [:]) throws -> ItemPictureFixture {
        var files: [String: Data] = [:]
        let identity: [String: Any] = ["left_rotation": [0, 0, 0, 1], "right_rotation": [0, 0, 0, 1],
                                      "scale": [1, 1, 1], "translation": [0, 0, 0]]
        func item(_ name: String, definition: [String: Any], transform: [String: Any], gui: [String: Any]? = nil) throws {
            files["assets/test/items/\(name).json"] = try ItemPictureFixture.json(["model": [
                "type": "special", "base": "test:item/" + name, "model": definition, "transformation": transform
            ]])
            files["assets/test/models/item/\(name).json"] = try ItemPictureFixture.json([
                "gui_light": "front", "display": ["gui": gui ?? ["rotation": [30, 45, 0], "translation": [0, 2, 0], "scale": [0.6, 0.6, 0.6]]]
            ])
        }
        var centered = identity; centered["translation"] = [0.5, 0.5, 0.5]
        try item("conduit", definition: ["type": "conduit"], transform: centered)
        files["assets/minecraft/textures/entity/conduit/base.png"] = try png(skinColor, width: 32, height: 16)
        var head = identity; head["left_rotation"] = [1, 0, 0, 0]; head["translation"] = [0.5, 0, 0.5]
        for kind in ["skeleton", "wither_skeleton", "zombie", "creeper", "dragon", "piglin"] {
            try item(kind, definition: ["type": "head", "kind": kind, "texture": "test:heads/" + kind], transform: head)
            let width = kind == "dragon" ? 256 : 64
            let height = ["skeleton", "wither_skeleton", "creeper"].contains(kind) ? 32 : width
            files["assets/test/textures/entity/heads/\(kind).png"] = try png(skinColor, width: width, height: height)
        }
        try item("missing_head", definition: ["type": "head", "kind": "skeleton", "texture": "test:missing"], transform: head)
        try item("animated_head", definition: ["type": "head", "kind": "skeleton", "animation": 1], transform: head)
        try item("player_head", definition: ["type": "player_head"], transform: head)
        files["assets/minecraft/textures/entity/player/slim/steve.png"] = try png(skinColor, width: 64, height: 64)
        for (name, color) in [("red", [UInt8(255), 0, 0, 255]), ("blue", [UInt8(0), 0, 255, 255])] {
            files["assets/test/textures/heads/\(name).png"] = try png(color, width: 64, height: 64)
        }
        var statue = identity; statue["scale"] = [1, -1, -1]; statue["translation"] = [0.5, 1.5, 0.5]
        for pose in ["standing", "sitting"] {
            try item(pose, definition: ["type": "copper_golem_statue", "pose": pose, "texture": "test:textures/statue.png"],
                     transform: statue, gui: ["rotation": [30, 45, 180], "translation": [0, 2, 0], "scale": [0.55, 0.55, 0.55]])
        }
        files["assets/test/textures/statue.png"] = try png(skinColor, width: 64, height: 64)
        try item("pot", definition: ["type": "decorated_pot"], transform: identity)
        files["assets/minecraft/textures/entity/decorated_pot/decorated_pot_base.png"] = try png([80, 50, 30, 255], width: 32, height: 32)
        files["assets/minecraft/textures/entity/decorated_pot/decorated_pot_side.png"] = try png([204, 128, 64, 255], width: 16, height: 16)
        for (name, color) in [("red", [UInt8(255), 0, 0, 255]), ("blue", [UInt8(0), 0, 255, 255])] {
            files["data/test/decorated_pot_pattern/\(name).json"] = try ItemPictureFixture.json(["asset_id": "test:" + name])
            files["assets/test/textures/entity/decorated_pot/\(name).png"] = try png(color, width: 16, height: 16)
        }
        files["assets/test/items/ordinary_strip.json"] = try ItemPictureFixture.json(["model": ["type": "model", "model": "test:item/ordinary_strip"]])
        files["assets/test/models/item/ordinary_strip.json"] = try ItemPictureFixture.json([
            "parent": "builtin/generated", "textures": ["layer0": "test:ordinary_strip"]
        ])
        files["assets/test/textures/ordinary_strip.png"] = try png(skinColor, width: 16, height: 32)
        files["assets/test/items/plain_picture.json"] = try ItemPictureFixture.json(["model": ["type": "model", "model": "test:item/plain_picture"]])
        files["assets/test/models/item/plain_picture.json"] = try ItemPictureFixture.json([
            "parent": "builtin/generated", "textures": ["layer0": "test:plain_picture"]
        ])
        files["assets/test/textures/plain_picture.png"] = try png(skinColor, width: 16, height: 16)
        files.merge(overrides) { _, replacement in replacement }
        return try ItemPictureFixture(extraFiles: files)
    }
}
