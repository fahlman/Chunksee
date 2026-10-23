import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ItemTrimPicturesTests {
    @Test func trimAndDyeShareTheirModelButNeverTheirDifferentPictures() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let ordinary = ItemStack(id: "test:armor")
        let gold = Self.stack("gold"), blue = Self.stack("blue")
        let plain = try #require(try await library.picture(for: ordinary))
        #expect(library.cachedPicture(for: gold) == nil)
        let golden = try #require(try await library.picture(for: gold))
        #expect(library.cachedPicture(for: blue) == nil)
        let blueImage = try #require(try await library.picture(for: blue))
        #expect(try ItemPictureFixture.pixels(plain).color(56, 8) == [128, 64, 32, 255])
        #expect(try ItemPictureFixture.pixels(golden).color(56, 8) == [255, 255, 0, 255])
        #expect(try ItemPictureFixture.pixels(blueImage).color(56, 8) == [0, 0, 255, 255])
        #expect(library.cachedPicture(for: ordinary) === plain)
        #expect(library.cachedPicture(for: gold) === golden)
        #expect(library.cachedPicture(for: blue) === blueImage)
        let redDye = Self.stack("gold", dye: 0xFF0000)
        #expect(library.cachedPicture(for: redDye) == nil)
        let dyed = try #require(try await library.picture(for: redDye))
        #expect(dyed !== golden)
        #expect(try ItemPictureFixture.pixels(dyed).color(56, 56) == [255, 0, 0, 255])
        #expect(try ItemPictureFixture.pixels(dyed).color(56, 8) == [255, 255, 0, 255])
        let shared = ItemStack(id: "test:other", count: 64, components: .compound([
            "minecraft:item_model": .string("test:armor"), "minecraft:trim": .compound([
                "material": .string("test:gold"), "pattern": .string("test:different")
            ])
        ]))
        #expect(library.cachedPicture(for: shared) === golden)
        #expect(try await library.picture(for: shared) === golden)
        await library.close()
        #expect(library.cachedPicture(for: gold) == nil)
        #expect(try await library.picture(for: gold) == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func warmTrimmedIconDrawsTheSelectedPictureImmediately(appearance: ColorScheme) async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library(), stack = Self.stack("gold", dye: 0x00FF00)
        _ = try #require(try await library.picture(for: stack))
        let renderer = ImageRenderer(content: ItemIcon(item: stack)
            .environment(\.gameAssetLibrary, library).environment(\.colorScheme, appearance))
        renderer.scale = 4
        let pixels = try ItemPictureFixture.pixels(try #require(renderer.cgImage))
        #expect(pixels.color(70, 10) == [255, 255, 0, 255])
        #expect(pixels.color(70, 70) == [0, 255, 0, 255])
    }

    @Test func olderUntrimmedPicturesAndMissingMaterialFallbacksRemainAvailable() async throws {
        let fixture = try Self.fixture(extraFiles: [
            "version.json": ItemPictureFixture.json(["id": "1.21.5", "world_version": 4325])
        ])
        defer { fixture.remove() }
        let library = try fixture.library()
        let ordinary = try #require(try await library.picture(for: ItemStack(id: "test:armor")))
        for trim in [NBT.compound(["!minecraft:trim": .compound([:]), "Trim": .compound(["material": .string("test:gold")])]),
                     .compound(["minecraft:trim": .compound(["material": .compound([:])])])] {
            let stack = ItemStack(id: "test:armor", components: trim)
            #expect(try await library.picture(for: stack) === ordinary)
            #expect(library.cachedPicture(for: stack) === ordinary)
        }
        #expect(try await library.picture(for: Self.stack("gold")) == nil)
        #expect(library.cachedPicture(for: Self.stack("gold")) == nil)
    }

    @Test func malformedTrimNeverReusesAnUntrimmedOrPreviouslyTrimmedImage() async throws {
        let fixture = try Self.fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        _ = try #require(try await library.picture(for: Self.stack("gold")))
        _ = try #require(try await library.picture(for: ItemStack(id: "test:armor")))
        for material in [NBT.int(2), .string("Bad material")] {
            let stack = ItemStack(id: "test:armor", components: .compound([
                "minecraft:trim": .compound(["material": material])
            ]))
            #expect(library.cachedPicture(for: stack) == nil)
            #expect(try await library.picture(for: stack) == nil)
        }
    }

    @Test(arguments: [false, true])
    func atlasPrecedenceDoesNotChangeDirectMapTextures(rawLast: Bool) async throws {
        var sources = [Self.paletteSource]
        if rawLast { sources.append(["type": "single", "resource": "test:trim/rim_gold"]) }
        let fixture = try Self.fixture(extraFiles: [
            "assets/minecraft/atlases/items.json": ItemPictureFixture.json(["sources": sources]),
            "assets/test/textures/trim/rim_gold.png": ItemPictureFixture.png(Array(repeating: [255, 0, 0, 255], count: 4).flatMap { $0 }),
            "assets/test/blockstates/trim.json": ItemPictureFixture.json(["variants": ["": ["model": "test:block/trim"]]]),
            "assets/test/models/block/trim.json": ItemPictureFixture.json([
                "textures": ["top": "test:trim/rim_gold"],
                "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": ["up": ["texture": "#top"]]]]
            ])
        ])
        defer { fixture.remove() }
        let library = try fixture.library()
        let picture = try #require(try await library.picture(for: Self.stack("gold")))
        #expect(try ItemPictureFixture.pixels(picture).color(56, 8) == (rawLast ? [255, 0, 0, 255] : [255, 255, 0, 255]))
        let colors = try await library.mapColors(for: [BlockState("test:trim")])
        #expect(colors == [MapColor(0xff0000)])
    }

    @Test func missingOrMismatchedGeneratedPalettesRemainUnavailable() async throws {
        for replacement in [Data(), try Self.straightPNG([255, 0, 0, 255, 0, 255, 0, 255], width: 2, height: 1)] {
            let fixture = try Self.fixture(extraFiles: ["assets/test/textures/palettes/trim_gold.png": replacement])
            defer { fixture.remove() }
            let library = try fixture.library()
            #expect(try await library.picture(for: Self.stack("gold")) == nil)
            #expect(library.cachedPicture(for: Self.stack("gold")) == nil)
            #expect(try await library.picture(for: ItemStack(id: "test:armor")) != nil)
        }
    }

    @Test func paletteMatchingKeepsOriginalRGBBeforeMultiplyingPartialAlpha() throws {
        let base = try Self.straightPNG([18, 52, 86, 128, 18, 52, 86, 255,
                                         18, 52, 86, 0, 0, 255, 0, 255], width: 2, height: 2)
        let key = try Self.straightPNG([18, 52, 86, 255], width: 1, height: 1)
        let palette = try Self.straightPNG([255, 0, 0, 128], width: 1, height: 1)
        let image = try #require(ItemTexture(png: base, paletteKey: key, palette: palette))
        #expect(image.pixels == [64, 0, 0, 64, 128, 0, 0, 128, 0, 0, 0, 0, 0, 255, 0, 255])
    }

    @Test func grayscaleSourcesAndPalettesRetainRowsAndRespectThePaletteBound() throws {
        let base = try Self.straightPNG([32, 255, 64, 255, 64, 128, 32, 0], width: 2, height: 2, grayscale: true)
        let key = try Self.straightPNG([32, 64], width: 1, height: 2, grayscale: true, hasAlpha: false)
        let palette = try Self.straightPNG([255, 0, 0, 0, 0, 255], width: 2, height: 1, hasAlpha: false)
        let image = try #require(ItemTexture(png: base, paletteKey: key, palette: palette))
        #expect(image.pixels == [255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 128, 128, 0, 0, 0, 0])
        let excessive = try Self.straightPNG(Array(repeating: 255, count: 128 * 33 * 4), width: 128, height: 33)
        #expect(ItemTexture(png: base, paletteKey: excessive, palette: excessive) == nil)
    }

    private static func stack(_ material: String, dye: Int32? = nil) -> ItemStack {
        var values: [String: NBT] = ["minecraft:trim": .compound(["material": .string("test:" + material)])]
        if let dye { values["minecraft:dyed_color"] = .int(dye) }
        return ItemStack(id: "test:armor", components: .compound(values))
    }

    private static var paletteSource: [String: Any] {
        ["type": "paletted_permutations", "textures": ["test:trim/rim"],
         "palette_key": "test:trim_key", "permutations": ["gold": "test:trim_gold", "blue": "test:trim_blue"]]
    }

    private static func fixture(extraFiles: [String: Data] = [:]) throws -> ItemPictureFixture {
        func model(_ id: String) -> [String: Any] {
            ["type": "model", "model": id, "tints": [["type": "dye", "default": 0x804020]]]
        }
        var files = [
            "assets/test/items/armor.json": try ItemPictureFixture.json(["model": [
                "type": "select", "property": "trim_material", "fallback": model("test:item/leather"),
                "cases": ["gold", "blue"].map { ["when": "test:" + $0, "model": model("test:item/trim_" + $0)] }
            ]]),
            "assets/minecraft/atlases/items.json": try ItemPictureFixture.json(["sources": [paletteSource]]),
            "assets/test/textures/trim/rim.png": try straightPNG([0, 0, 0, 0, 18, 52, 86, 255,
                                                                  0, 0, 0, 0, 0, 0, 0, 0], width: 2, height: 2),
            "assets/test/textures/palettes/trim_key.png": try straightPNG([18, 52, 86, 255], width: 1, height: 1),
            "assets/test/textures/palettes/trim_gold.png": try straightPNG([255, 255, 0, 255], width: 1, height: 1),
            "assets/test/textures/palettes/trim_blue.png": try straightPNG([0, 0, 255, 255], width: 1, height: 1)
        ]
        for color in ["gold", "blue"] {
            files["assets/test/models/item/trim_\(color).json"] = try ItemPictureFixture.json([
                "parent": "test:item/leather", "textures": ["layer2": "test:trim/rim_" + color]
            ])
        }
        files.merge(extraFiles) { _, new in new }
        return try ItemPictureFixture(extraFiles: files)
    }

    private static func straightPNG(_ bytes: [UInt8], width: Int, height: Int, grayscale: Bool = false, hasAlpha: Bool = true) throws -> Data {
        let components = (grayscale ? 1 : 3) + (hasAlpha ? 1 : 0)
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                        bitsPerPixel: components * 8, bytesPerRow: width * components,
                                        space: CGColorSpace(name: grayscale ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: (hasAlpha ? CGImageAlphaInfo.last : .none).rawValue),
                                        provider: CGDataProvider(data: Data(bytes) as CFData)!,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try ItemPictureFixture.png(image)
    }
}
