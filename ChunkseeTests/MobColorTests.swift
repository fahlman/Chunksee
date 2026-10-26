import ChunkseeKit
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MobColorTests {
    @Test func representativeColorsIgnoreTransparentPixelsAndWeightPartialAlpha() throws {
        let texture = ItemTexture(width: 3, height: 1, pixels: [255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0])
        #expect(try texture.representativeColor() == MapColor(0xA95500))
        #expect(try ItemTexture(width: 1, height: 1, pixels: [0, 0, 0, 0]).representativeColor() == nil)
    }

    @Test func installedTextureColorsUseTheSharedCacheAndRetireWithTheirSource() async throws {
        let fixture = try ItemPictureFixture(extraFiles: [
            "assets/test/textures/entity/pink.png": ItemPictureFixture.png([240, 160, 180, 255], width: 1, height: 1),
        ])
        defer { fixture.remove() }
        let library = try fixture.library()
        #expect(library.cachedTextureColor("test:entity/pink") == nil)
        #expect(try await library.textureColor("test:entity/pink") == MapColor(0xF0A0B4))
        #expect(library.cachedTextureColor("test:entity/pink") == MapColor(0xF0A0B4))
        #expect(try await library.textureColor("test:entity/missing") == nil)
        await library.close()
        #expect(library.cachedTextureColor("test:entity/pink") == nil)
        await #expect(throws: CancellationError.self) { try await library.textureColor("test:entity/pink") }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func axolotlsKeepUntintedSymbolsWithoutArtworkAndSheepKeepGameTints(_ scheme: ColorScheme) async throws {
        func marker(_ species: String, variant: String?) throws -> CreatureMarker {
            try #require(CreatureMarker(Creature(id: species, x: 0, y: 64, z: 0,
                appearance: variant.map { CreatureAppearance(variant: $0) }), dimension: "minecraft:overworld"))
        }
        func image(_ marker: CreatureMarker, library: GameAssetLibrary? = nil) throws -> [UInt8] {
            let view = MobLocationLabel(marker: marker).font(.body).frame(width: 160, height: 28, alignment: .leading)
                .environment(\.gameAssetLibrary, library).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return try ItemPictureFixture.pixels(#require(renderer.cgImage)).bytes
        }
        func equivalent(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            // Independent native text/symbol rasters can vary by one unit in premultiplied
            // edge pixels, including alpha. Actual tint differences are much larger.
            a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
        let plain = try marker("minecraft:axolotl", variant: nil)
        let lucy = try marker("minecraft:axolotl", variant: "minecraft:lucy")
        let fallback = try image(plain)
        #expect(fallback.contains { $0 != 0 })
        #expect(try equivalent(image(lucy), fallback))
        guard case .texture(let id)? = lucy.creature.appearance?.colorSource(for: lucy.creature.id) else {
            Issue.record("The published game facts did not supply the texture source"); return
        }
        let fixture = try ItemPictureFixture(extraFiles: [
            "assets/minecraft/textures/entity/axolotl/axolotl_lucy.png": ItemPictureFixture.png([240, 160, 180, 255], width: 1, height: 1),
        ])
        defer { fixture.remove() }
        let library = try fixture.library()
        _ = try #require(try await library.textureColor(id))
        #expect(try !equivalent(image(lucy, library: library), fallback))
        await library.close()
        #expect(library.cachedTextureColor(id) == nil)
        #expect(try equivalent(image(lucy, library: library), fallback))
        let noSheepColor = try image(marker("minecraft:sheep", variant: nil))
        #expect(try !equivalent(image(marker("minecraft:sheep", variant: "minecraft:white")), noSheepColor))
        #expect(try !equivalent(image(marker("minecraft:sheep", variant: "minecraft:black")), noSheepColor))
    }
}
