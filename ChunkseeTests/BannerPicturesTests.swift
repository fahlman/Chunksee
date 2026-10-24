import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct BannerPicturesTests {
    @Test func definitionColorAndOrderedPatternsShareTheExistingPictureCache() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let blue = Self.stack(), striped = Self.stack(layers: [Self.layer("left", color: "red")])
        #expect(library.cachedPicture(for: blue) == nil && library.cachedPicture(for: striped) == nil)
        let plain = try #require(try await library.picture(for: blue))
        let patterned = try #require(try await library.picture(for: striped))
        let plainPixels = try ItemPictureFixture.pixels(plain), patternedPixels = try ItemPictureFixture.pixels(patterned)
        #expect(Self.count([60, 68, 170, 255], in: plainPixels) > 0)
        #expect(Self.count([80, 48, 16, 255], in: plainPixels) > 0)
        #expect(Self.count([176, 46, 38, 255], in: patternedPixels) > 0)
        #expect(Self.count([60, 68, 170, 255], in: patternedPixels) > 0)
        let offsets = stride(from: 0, to: plainPixels.bytes.count, by: 4)
        #expect(offsets.allSatisfy { plainPixels.bytes[$0 + 3] == patternedPixels.bytes[$0 + 3] })
        #expect(offsets.filter { Array(plainPixels.bytes[$0..<$0 + 4]) == [80, 48, 16, 255] }
            .allSatisfy { Array(patternedPixels.bytes[$0..<$0 + 4]) == [80, 48, 16, 255] },
            "Patterns leave the wooden support unchanged")
        #expect(library.cachedPicture(for: blue) === plain && library.cachedPicture(for: striped) === patterned)
        var renamed = striped
        renamed.count = 64; renamed.customName = "same banner"
        #expect(try await library.picture(for: renamed) === patterned)
        let greenLast = Self.stack(layers: [Self.layer("full", color: "red"), Self.layer("full", color: "green")])
        let redLast = Self.stack(layers: [Self.layer("full", color: "green"), Self.layer("full", color: "red")])
        let greenPixels = try ItemPictureFixture.pixels(#require(try await library.picture(for: greenLast)))
        let redPixels = try ItemPictureFixture.pixels(#require(try await library.picture(for: redLast)))
        #expect(Self.count([94, 124, 22, 255], in: greenPixels) > 0 && Self.count([176, 46, 38, 255], in: greenPixels) == 0)
        #expect(Self.count([176, 46, 38, 255], in: redPixels) > 0 && Self.count([94, 124, 22, 255], in: redPixels) == 0)
        await library.close()
        #expect(library.cachedPicture(for: striped) == nil)
        #expect(try await library.picture(for: striped) == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeIconDrawsTheSharedBannerPicture(appearance: ColorScheme) async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library(), stack = Self.stack(layers: [Self.layer("left", color: "red")])
        _ = try #require(try await library.picture(for: stack))
        let renderer = ImageRenderer(content: ItemIcon(item: stack)
            .environment(\.gameAssetLibrary, library).environment(\.colorScheme, appearance))
        renderer.scale = 4
        let pixels = try ItemPictureFixture.pixels(#require(renderer.cgImage))
        #expect(Self.count([176, 46, 38, 255], in: pixels) > 0)
        #expect(Self.count([60, 68, 170, 255], in: pixels) > 0)
        #expect(Self.count([80, 48, 16, 255], in: pixels) > 0)
    }

    @Test func unavailablePatternKeepsItsFallbackInsteadOfReusingThePlainBanner() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library(), plain = Self.stack()
        let picture = try #require(try await library.picture(for: plain))
        for name in ["missing_definition", "missing_texture"] {
            let unavailable = Self.stack(layers: [Self.layer(name, color: "red")])
            #expect(try await library.picture(for: unavailable) == nil)
            #expect(library.cachedPicture(for: unavailable) == nil)
        }
        #expect(library.cachedPicture(for: plain) === picture)
    }

    private static func count(_ color: [UInt8], in pixels: ItemPictureFixture.Pixels) -> Int {
        stride(from: 0, to: pixels.bytes.count, by: 4).reduce(0) { total, offset in
            total + (Array(pixels.bytes[offset..<offset + 4]) == color ? 1 : 0)
        }
    }

    private static func layer(_ name: String, color: String) -> NBT {
        .compound(["pattern": .string("test:" + name), "color": .string(color)])
    }

    private static func stack(layers: [NBT] = []) -> ItemStack {
        ItemStack(id: "test:banner", components: .compound([
            "minecraft:banner_patterns": .list(.compound, layers)
        ]))
    }

    private static func fixture() throws -> ItemPictureFixture {
        var files: [String: Data] = [
            "assets/test/items/banner.json": try ItemPictureFixture.json(["model": [
                "type": "special", "base": "test:item/banner", "model": ["type": "banner", "color": "blue"],
                "transformation": ["left_rotation": [0, 0, 0, 1], "right_rotation": [0, 0, 0, 1],
                                   "scale": [0.6666667, -0.6666667, -0.6666667], "translation": [0.5, 0, 0.5]]
            ]]),
            "assets/test/models/item/banner.json": try ItemPictureFixture.json([
                "gui_light": "front", "display": ["gui": ["translation": [0, -3.25, 0], "scale": [0.5325, 0.5325, 0.5325]]]
            ])
        ]
        let woodColor: [UInt8] = [80, 48, 16, 255]
        let wood = Array(repeating: woodColor, count: 64 * 64).flatMap { $0 }
        let white = [UInt8](repeating: 255, count: 64 * 64 * 4)
        var left = [UInt8](repeating: 0, count: white.count)
        for y in 0..<64 {
            for x in 0..<11 {
                let offset = (y * 64 + x) * 4
                left.replaceSubrange(offset..<offset + 4, with: [255, 255, 255, 255])
            }
        }
        files["assets/minecraft/textures/entity/banner/banner_base.png"] = try ItemPictureFixture.png(wood, width: 64, height: 64)
        files["assets/minecraft/textures/entity/banner/base.png"] = try ItemPictureFixture.png(white, width: 64, height: 64)
        for (name, pixels) in [("left", left), ("full", white)] {
            files["assets/test/textures/entity/banner/\(name).png"] = try ItemPictureFixture.png(pixels, width: 64, height: 64)
        }
        for name in ["left", "full", "missing_texture"] {
            files["data/test/banner_pattern/\(name).json"] = try ItemPictureFixture.json([
                "asset_id": "test:" + name, "translation_key": "test." + name
            ])
        }
        return try ItemPictureFixture(extraFiles: files)
    }
}
