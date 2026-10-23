import ChunkseeKit
import ChunkseeIndex
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ItemPicturesTests {
    @Test func translatedBedHalvesRemainSeparateInTheSharedPictureAndNativeIcon() async throws {
        let gui: [String: Any] = ["rotation": [90, 0, 0], "translation": [0, 4, 0], "scale": [0.5, 0.5, 0.5]]
        let fixture = try ItemPictureFixture(extraFiles: [
            "assets/test/items/bed.json": ItemPictureFixture.json(["model": [
                "type": "composite", "models": [
                    ["type": "model", "model": "test:block/bed_head"],
                    ["type": "model", "model": "test:block/bed_foot", "transformation": [
                        "left_rotation": [0, 0, 0, 1], "right_rotation": [0, 0, 0, 1],
                        "scale": [1, 1, 1], "translation": [0, 0, 1]
                    ]]
                ]
            ]]),
            "assets/test/models/block/bed_head.json": ItemPictureFixture.json([
                "gui_light": "front", "display": ["gui": gui], "textures": ["skin": "test:item/red"],
                "elements": [["from": [0, 3, 0], "to": [16, 9, 16], "faces": ["up": ["texture": "#skin"]]]]
            ]),
            "assets/test/models/block/bed_foot.json": ItemPictureFixture.json([
                "parent": "test:block/bed_head", "textures": ["skin": "test:item/blue"]
            ])
        ])
        defer { fixture.remove() }
        let library = try fixture.library(), stack = ItemStack(id: "test:bed")
        let image = try #require(try await library.picture(for: stack))
        let pixels = try ItemPictureFixture.pixels(image)
        // Distinct halves expose a lost translation: the foot would cover the head instead.
        #expect(pixels.color(32, 16) == [255, 0, 0, 255])
        #expect(pixels.color(32, 48) == [0, 0, 255, 255])
        #expect(pixels.color(8, 32) == [0, 0, 0, 0])
        #expect(library.cachedPicture(for: stack) === image)
        for appearance in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: ItemIcon(item: stack)
                .environment(\.gameAssetLibrary, library).environment(\.colorScheme, appearance))
            renderer.scale = 4
            let native = try #require(renderer.cgImage)
            #expect(native.width == 80 && native.height == 80)
            let drawn = try ItemPictureFixture.pixels(native)
            #expect(drawn.color(40, 20) == [255, 0, 0, 255])
            #expect(drawn.color(40, 60) == [0, 0, 255, 255])
        }
    }

    @Test func plainShieldShowsItsPlateInFrontAndHandleBehind() async throws {
        var files = [String: Data]()
        for (view, rotation, translation) in [("front", [0, 0, 0], [4, 4, 0]),
                                               ("back", [0, 180, 0], [-4, 4, 0])] {
            let id = "shield_" + view
            files["assets/test/items/\(id).json"] = try ItemPictureFixture.json(["model": [
                "type": "condition", "property": "using_item", "transformation": [
                    "left_rotation": [0, 0, 0, 1], "right_rotation": [0, 0, 0, 1],
                    "scale": [1, -1, -1], "translation": [0, 0, 0]
                ], "on_false": ["type": "special", "base": "test:item/" + id, "model": ["type": "shield"]]
            ]])
            files["assets/test/models/item/\(id).json"] = try ItemPictureFixture.json([
                "gui_light": "front", "display": ["gui": ["rotation": rotation, "translation": translation,
                                                              "scale": [0.5, 0.5, 0.5]]]
            ])
        }
        var skin = Array(repeating: [UInt8(255), 0, 0, 255], count: 64 * 64).flatMap { $0 }
        // Blue regions identify the handle independently of the red front/back plate.
        for x in [32, 40] {
            for y in 6..<12 {
                for column in x..<x + 2 {
                    let offset = (y * 64 + column) * 4
                    skin.replaceSubrange(offset..<offset + 4, with: [0, 0, 255, 255])
                }
            }
        }
        files["assets/minecraft/textures/entity/shield/shield_base_nopattern.png"] = try ItemPictureFixture.png(skin, width: 64, height: 64)
        let fixture = try ItemPictureFixture(extraFiles: files)
        defer { fixture.remove() }
        let library = try fixture.library()
        for (view, center) in [("front", [UInt8(255), 0, 0, 255]), ("back", [0, 0, 255, 255])] {
            let stack = ItemStack(id: "test:shield_" + view)
            let image = try #require(try await library.picture(for: stack))
            let pixels = try ItemPictureFixture.pixels(image)
            #expect(pixels.color(32, 32) == center, "\(view) center")
            #expect(pixels.color(22, 32) == [255, 0, 0, 255], "\(view) plate")
            #expect(pixels.color(8, 32) == [0, 0, 0, 0])
            #expect(library.cachedPicture(for: stack) === image)
        }
    }

    @Test func chestsUseTheirTopLidBodyAndLatchTextureRegions() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let checks: [(String, [(Int, Int, [UInt8])])] = [
            ("chest_front", [(20, 40, [0, 255, 0, 255]), (20, 16, [0, 0, 255, 255]),
                              (32, 24, [255, 255, 0, 255])]),
            ("chest_top", [(32, 32, [255, 0, 0, 255])]),
            ("chest_side", [(32, 40, [0, 255, 255, 255])])
        ]
        for (id, samples) in checks {
            let stack = ItemStack(id: "test:" + id)
            let image = try #require(try await library.picture(for: stack))
            let pixels = try ItemPictureFixture.pixels(image)
            for (x, y, expected) in samples { #expect(pixels.color(x, y) == expected, "\(id) at \(x), \(y)") }
            #expect(library.cachedPicture(for: ItemStack(id: stack.id, count: 64)) === image)
        }
    }

    @Test func redShulkersUseTheirTopAndBothSideRegionsAfterTheLocalTurn() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let checks: [(String, [(Int, Int, [UInt8])])] = [
            ("shulker_front", [(32, 12, [0, 0, 255, 255]), (32, 56, [0, 255, 0, 255])]),
            ("shulker_top", [(32, 32, [255, 0, 0, 255])]),
            ("shulker_side", [(32, 12, [0, 255, 255, 255])])
        ]
        for (id, samples) in checks {
            let stack = ItemStack(id: "test:" + id)
            let image = try #require(try await library.picture(for: stack))
            let pixels = try ItemPictureFixture.pixels(image)
            for (x, y, expected) in samples { #expect(pixels.color(x, y) == expected, "\(id) at \(x), \(y)") }
            #expect(library.cachedPicture(for: stack) === image)
        }
    }

    @Test func unverifiedContainerVersionsKeepTheirFallback() async throws {
        let fixture = try ItemPictureFixture(dataVersion: 5024)
        defer { fixture.remove() }
        let library = try fixture.library()
        for id in ["test:chest_front", "test:shulker_front"] {
            #expect(try await library.picture(for: ItemStack(id: id)) == nil)
            #expect(library.cachedPicture(for: ItemStack(id: id)) == nil)
        }
        #expect(try await library.picture(for: ItemStack(id: "test:flat")) != nil)
    }

    @Test func layeredSpritesKeepTheirOrientationAndNearestPixels() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let picture = try #require(try await library.picture(for: ItemStack(id: "test:flat")))
        let pixels = try ItemPictureFixture.pixels(picture)
        #expect(picture.width == 64 && picture.height == 64 && !picture.shouldInterpolate)
        #expect(pixels.color(8, 8) == [255, 0, 0, 255])
        #expect(pixels.color(56, 8) == [0, 255, 0, 255])
        #expect(pixels.color(8, 56) == [0, 0, 255, 255])
        #expect(pixels.color(56, 56) == [255, 255, 0, 255])
        let expected: Set<[UInt8]> = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
        #expect(Set(stride(from: 0, to: pixels.bytes.count, by: 4).map { Array(pixels.bytes[$0..<$0 + 4]) }) == expected)
    }

    @Test func savedDyeAndPotionColorsAffectOnlyTheirTintedLayers() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let leather = ItemStack(id: "test:leather", components: .compound(["minecraft:dyed_color": .int(0x0080FF)]))
        let image = try #require(try await library.picture(for: leather))
        let pixels = try ItemPictureFixture.pixels(image)
        #expect(pixels.color(8, 8) == [255, 0, 0, 255]) // Untinted red overlay.
        #expect(pixels.color(56, 56) == [0, 128, 255, 255])
        let defaultImage = try #require(try await library.picture(for: ItemStack(id: "test:leather")))
        #expect(try ItemPictureFixture.pixels(defaultImage).color(56, 56) == [128, 64, 32, 255])
        let potion = ItemStack(id: "test:potion", components: .compound([
            "minecraft:potion_contents": .compound(["custom_color": .int(0x23A4D1)])
        ]))
        let potionImage = try #require(try await library.picture(for: potion))
        #expect(try ItemPictureFixture.pixels(potionImage).color(32, 32) == [35, 164, 209, 255])
    }

    @Test func nativeItemGraphicKeepsPixelEdgesInBothAppearances() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let image = try #require(try await fixture.library().picture(for: ItemStack(id: "test:flat")))
        for appearance in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: ItemGraphic(id: "test:flat", isEnchanted: false, image: image)
                .environment(\.colorScheme, appearance))
            renderer.scale = 4
            let rendered = try #require(renderer.cgImage)
            #expect(rendered.width == 80 && rendered.height == 80)
            let decoded = try #require(ItemTexture(png: ItemPictureFixture.png(rendered)))
            let colors = Set(stride(from: 0, to: decoded.pixels.count, by: 4).map { Array(decoded.pixels[$0..<$0 + 4]) })
            #expect(colors == Set([[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]))
        }
    }

    @Test func blockItemsShowThreeFacesAndQuarterTurnsKeepTheirUVs() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let cube = try #require(try await library.picture(for: ItemStack(id: "test:cube")))
        let pixels = try ItemPictureFixture.pixels(cube)
        var channels = [0, 0, 0], clear = 0
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
            if pixels.bytes[index + 3] == 0 { clear += 1; continue }
            for channel in 0..<3 where pixels.bytes[index + channel] > 0 { channels[channel] += 1 }
            #expect(pixels.bytes[index..<index + 3].filter { $0 > 0 }.count == 1)
        }
        #expect(channels.allSatisfy { $0 > 150 })
        #expect(clear > 300)
        let turned = try #require(try await library.picture(for: ItemStack(id: "test:turned")))
        let rotated = try ItemPictureFixture.pixels(turned)
        #expect(rotated.color(8, 8) == [0, 0, 255, 255])
        #expect(rotated.color(56, 8) == [255, 0, 0, 255])
        #expect(rotated.color(8, 56) == [255, 255, 0, 255])
        #expect(rotated.color(56, 56) == [0, 255, 0, 255])
    }

    @Test func elementEulerRotationsApplyXThenYThenZ() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let image = try #require(try await fixture.library().picture(for: ItemStack(id: "test:euler")))
        let pixels = try ItemPictureFixture.pixels(image)
        // X=90 then Y=90 turns the west face toward the camera: (x,y,z) -> (y,-z,-x).
        // Reversing the turns leaves that face edge-on instead of showing these four corners.
        #expect(pixels.color(24, 24) == [0, 0, 255, 255])
        #expect(pixels.color(40, 24) == [255, 0, 0, 255])
        #expect(pixels.color(24, 40) == [255, 255, 0, 255])
        #expect(pixels.color(40, 40) == [0, 255, 0, 255])
        #expect(pixels.color(8, 8) == [0, 0, 0, 0])
    }

    @Test func elementRescaleExpandsTheRotatedFaceBeforeProjection() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let plain = try #require(try await library.picture(for: ItemStack(id: "test:diagonal")))
        let scaled = try #require(try await library.picture(for: ItemStack(id: "test:rescaled")))
        let a = try ItemPictureFixture.pixels(plain), b = try ItemPictureFixture.pixels(scaled)
        for (x, y) in [(32, 4), (4, 32), (59, 32), (32, 59)] {
            #expect(a.color(x, y) == [0, 0, 0, 0])
            #expect(b.color(x, y) == [255, 255, 255, 255])
        }
        #expect(a.color(32, 32) == [255, 255, 255, 255])
        #expect(b.color(32, 32) == [255, 255, 255, 255])
    }

    @Test func repeatedKindsSharePicturesButSavedColorsStayDistinct() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        #expect(library.cachedPicture(for: ItemStack(id: "test:flat")) == nil)
        let first = try #require(try await library.picture(for: ItemStack(id: "test:flat", count: 1)))
        #expect(library.cachedPicture(for: ItemStack(id: "test:flat", count: 64)) === first)
        let more = try #require(try await library.picture(for: ItemStack(id: "test:flat", count: 64)))
        #expect(first === more)
        let red = ItemStack(id: "test:leather", components: .compound(["minecraft:dyed_color": .int(0xFF0000)]))
        let blue = ItemStack(id: "test:leather", components: .compound(["minecraft:dyed_color": .int(0x0000FF)]))
        let redImage = try #require(try await library.picture(for: red))
        #expect(library.cachedPicture(for: blue) == nil)
        let blueImage = try #require(try await library.picture(for: blue))
        #expect(redImage !== blueImage)
        #expect(library.cachedPicture(for: red) === redImage)
        #expect(library.cachedPicture(for: blue) === blueImage)
        let otherLibrary = try fixture.library()
        #expect(otherLibrary.cachedPicture(for: red) == nil)
        #expect(try ItemPictureFixture.pixels(redImage).color(56, 56) != ItemPictureFixture.pixels(blueImage).color(56, 56))
        #expect(try await library.picture(for: ItemStack(id: "test:unknown")) == nil)
        #expect(try await library.picture(for: ItemStack(id: "test:special")) == nil)
        #expect(library.cachedPicture(for: ItemStack(id: "test:special")) == nil)
    }

    @Test func warmItemIconDrawsItsPictureInTheInitialFrame() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let stack = ItemStack(id: "test:flat")
        _ = try #require(try await library.picture(for: stack))
        // ImageRenderer captures the initial view without running its asynchronous load task.
        let renderer = ImageRenderer(content: ItemIcon(item: stack).environment(\.gameAssetLibrary, library))
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let pixels = try ItemPictureFixture.pixels(image)
        #expect(pixels.color(10, 10) == [255, 0, 0, 255])
        #expect(pixels.color(70, 10) == [0, 255, 0, 255])
        #expect(pixels.color(10, 70) == [0, 0, 255, 255])
        #expect(pixels.color(70, 70) == [255, 255, 0, 255])
    }

    @Test func synchronousReadersSharePicturesDuringActorLoads() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let warm = ItemStack(id: "test:flat")
        let picture = try #require(try await library.picture(for: warm))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    #expect(library.cachedPicture(for: warm) === picture)
                    let stack = ItemStack(id: "test:leather", components: .compound([
                        "minecraft:dyed_color": .int(Int32(index * 0x070707))
                    ]))
                    let image = try #require(try await library.picture(for: stack))
                    #expect(library.cachedPicture(for: stack) === image)
                    #expect(library.cachedPicture(for: warm) === picture)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func colorMapsUseTheReadersPixelAndOversizedImagesAreRejected() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let grass = try #require(try await library.picture(for: ItemStack(id: "test:grass")))
        #expect(library.cachedPicture(for: ItemStack(id: "test:grass")) === grass)
        #expect(try ItemPictureFixture.pixels(grass).color(32, 32) == [0, 255, 0, 255])
        let large = try ItemPictureFixture.png([UInt8](repeating: 255, count: 1025 * 4), width: 1025, height: 1)
        #expect(ItemTexture(png: large) == nil)
        #expect(ItemTexture(png: Data([1, 2, 3])) == nil)
    }

    @Test func emptyModelsStayEmptyAndUnusedTintsDoNotHideAnItem() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let empty = try #require(try await library.picture(for: ItemStack(id: "test:empty")))
        #expect(try ItemPictureFixture.pixels(empty).bytes.allSatisfy { $0 == 0 })
        let unused = ItemStack(id: "test:unused", components: .compound([
            "minecraft:potion_contents": .compound(["potion": .string("example:unknown")])
        ]))
        #expect(try await library.picture(for: unused) != nil)
    }

    @Test func existingMinecraftBookmarkIsSharedWithPlayerNames() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let defaults = TestDefaults.make()
        let bookmark = try fixture.root.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "minecraftFolderBookmark")
        let names = PlayerNames(defaults: defaults, readCaches: { _ in [:] })
        #expect(names.minecraftFolder?.standardizedFileURL == fixture.root.standardizedFileURL)
        let version = try #require(GameAssetVersion(name: "26.3", dataVersion: 5023))
        #expect(await names.minecraft.library(for: version) != nil)
        names.forgetMinecraftFolder()
        #expect(names.minecraft.folder == nil && names.minecraftFolder == nil)
        #expect(defaults.data(forKey: "minecraftFolderBookmark") == nil)
        await names.chooseMinecraftFolder(fixture.root)
        #expect(await names.minecraft.library(for: version) != nil)
        await names.minecraft.waitUntilIdle()
    }

    @Test func librariesRequireTheSavedVersionAndShareOnlyTheSameFile() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let resources = MinecraftResources(defaults: TestDefaults.make())
        let version = try #require(GameAssetVersion(name: "26.3", dataVersion: 5023))
        #expect(await resources.library(for: version) == nil)
        resources.choose(fixture.root)
        let first = try #require(await resources.library(for: version))
        let second = try #require(await resources.library(for: version))
        #expect(first === second)
        let stack = ItemStack(id: "test:flat")
        #expect(try await first.picture(for: stack) != nil)
        #expect(second.cachedPicture(for: stack) != nil)
        let wrong = try #require(GameAssetVersion(name: "26.3", dataVersion: 1))
        #expect(await resources.library(for: wrong) == nil)
        let missing = try #require(GameAssetVersion(name: "1.21", dataVersion: 3953))
        #expect(await resources.library(for: missing) == nil)
        let generation = resources.generation
        resources.forget()
        #expect(resources.generation != generation && resources.folder == nil)
        #expect(await resources.library(for: version) == nil)
        await resources.waitUntilIdle()
        // Retained inactive views cannot keep reading or warming the retired source.
        #expect(first.cachedPicture(for: stack) == nil)
        #expect(try await second.picture(for: stack) == nil)
        resources.choose(fixture.root)
        let reopened = try #require(await resources.library(for: version))
        #expect(first !== reopened)
        #expect(try await reopened.picture(for: stack) != nil)
        #expect(try await first.picture(for: stack) == nil)
        await resources.waitUntilIdle()
    }

    @Test func closingTheRegistryRetiresEveryRetainedLibraryAndCannotReopen() async throws {
        let firstFixture = try ItemPictureFixture(), secondFixture = try ItemPictureFixture()
        defer { firstFixture.remove(); secondFixture.remove() }
        let libraries = GameAssetLibraries()
        let version = try #require(GameAssetVersion(name: "26.3", dataVersion: 5023))
        let first = try #require(try await libraries.library(for: version, under: firstFixture.root))
        let second = try #require(try await libraries.library(for: version, under: secondFixture.root))
        #expect(first !== second)
        let stack = ItemStack(id: "test:flat")
        #expect(try await first.picture(for: stack) != nil)
        #expect(try await second.picture(for: stack) != nil)
        await libraries.close()
        for library in [first, second] {
            #expect(library.cachedPicture(for: stack) == nil)
            #expect(try await library.picture(for: stack) == nil)
        }
        #expect(try await libraries.library(for: version, under: firstFixture.root) == nil)
    }

    @Test func changingTheJarDoesNotReuseItsOldPictures() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let libraries = GameAssetLibraries()
        let version = try #require(GameAssetVersion(name: "26.3", dataVersion: 5023))
        let first = try #require(try await libraries.library(for: version, under: fixture.root))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fixture.jar.path)
        let replacement = try #require(try await libraries.library(for: version, under: fixture.root))
        #expect(first !== replacement && first.sourceKey != replacement.sourceKey)
        for name in ["", "..", "/tmp/test", "a/b", "a\\b", "a\0b"] {
            #expect(GameAssetVersion(name: name, dataVersion: 5023) == nil)
        }
        #expect(GameAssetVersion(name: "26.3", dataVersion: Int.max) == nil)
        #expect(GameAssetVersion(name: nil, dataVersion: 5023) == nil)
    }

    @Test func cancelledPicturesDoNotDrawOrPublish() async throws {
        let fixture = try ItemPictureFixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let task = Task { try await library.picture(for: ItemStack(id: "test:cube")) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Canceled image request returned a picture")
        } catch is CancellationError { }
    }

    @Test func searchSummariesKeepTypedItemsWithTheSameCountsAndNames() throws {
        let found = try #require(WorldSearch.summary(of: [ItemStack(id: "minecraft:stone", count: 2),
                                                          ItemStack(id: "minecraft:stone", count: 3),
                                                          ItemStack(id: "minecraft:redstone", count: 1)], query: SearchQuery("stone")))
        #expect(found.count == 6)
        #expect(found.items.map(\.id) == ["minecraft:stone", "minecraft:redstone"])
        #expect(found.items.map(\.count) == [5, 1])
        #expect(found.text == found.items.map(\.text).joined(separator: ", "))
    }
}

/// Synthetic JSON and colored PNGs only. ditto supplies ZIP encoding; tests do not implement
/// another archive writer or copy any installed-game artwork into the repository or bundle.
struct ItemPictureFixture {
    let root: URL
    let jar: URL

    init(dataVersion: Int = 5023, extraFiles: [String: Data] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseeTests-ItemPictures-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        jar = root.appendingPathComponent("versions/26.3/26.3.jar")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ path: String, _ data: Data) throws {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func json(_ path: String, _ object: Any) throws { try write(path, Self.json(object)) }
        try json("version.json", ["id": "26.3", "world_version": dataVersion])
        for id in ["flat", "leather", "potion", "cube", "turned", "grass", "euler", "diagonal", "rescaled"] {
            var model: [String: Any] = ["type": "minecraft:model", "model": "test:item/" + id]
            if id == "leather" { model["tints"] = [["type": "minecraft:dye", "default": 0x804020]] }
            if id == "potion" { model["tints"] = [["type": "minecraft:potion", "default": 0xFFFFFF]] }
            if id == "grass" { model["tints"] = [["type": "minecraft:grass", "temperature": 1, "downfall": 1]] }
            try json("assets/test/items/\(id).json", ["model": model])
        }
        try json("assets/test/items/special.json", ["model": ["type": "minecraft:special"]])
        try json("assets/test/items/empty.json", ["model": ["type": "minecraft:empty"]])
        try json("assets/test/items/unused.json", ["model": ["type": "minecraft:model", "model": "test:item/cube",
            "tints": [["type": "minecraft:potion", "default": 0xFFFFFF]]]])
        for (id, layers) in [("flat", ["layer0": "test:item/quadrants"]),
                             ("leather", ["layer0": "test:item/white", "layer1": "test:item/overlay"]),
                             ("potion", ["layer0": "test:item/white"]), ("grass", ["layer0": "test:item/white"])] {
            try json("assets/test/models/item/\(id).json", ["parent": "minecraft:builtin/generated", "gui_light": "front", "textures": layers])
        }
        var faces: [String: Any] = [:]
        for (face, color) in [("up", "red"), ("east", "blue"), ("north", "green"), ("down", "white"), ("west", "white"), ("south", "white")] {
            faces[face] = ["texture": "#" + color]
        }
        let textures = ["red": "test:item/red", "green": "test:item/green", "blue": "test:item/blue", "white": "test:item/white"]
        try json("assets/test/models/item/cube.json", ["textures": textures, "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": faces]],
            "display": ["gui": ["rotation": [30, 225, 0], "scale": [0.625, 0.625, 0.625]]]])
        try json("assets/test/models/item/turned.json", ["gui_light": "front", "textures": ["main": "test:item/quadrants"],
            "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": ["south": ["texture": "#main", "rotation": 90]]]]])
        try json("assets/test/models/item/euler.json", ["gui_light": "front", "textures": ["main": "test:item/quadrants"],
            "elements": [["from": [4, 4, 4], "to": [12, 12, 12],
                          "rotation": ["origin": [8, 8, 8], "x": 90, "y": 90],
                          "faces": ["west": ["texture": "#main", "uv": [0, 0, 16, 16]]]]]])
        for (id, rescale) in [("diagonal", false), ("rescaled", true)] {
            try json("assets/test/models/item/\(id).json", ["gui_light": "front", "textures": ["main": "test:item/white"],
                "elements": [["from": [4, 4, 8], "to": [12, 12, 8],
                              "rotation": ["origin": [8, 8, 8], "axis": "z", "angle": 45, "rescale": rescale],
                              "faces": ["south": ["texture": "#main"]]]]])
        }
        let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
        let white: [UInt8] = [255, 255, 255, 255], clear: [UInt8] = [0, 0, 0, 0]
        for (name, pixels) in [("red", red + red + red + red), ("green", green + green + green + green),
                               ("blue", blue + blue + blue + blue), ("white", white + white + white + white),
                               ("quadrants", red + green + blue + [255, 255, 0, 255]), ("overlay", red + clear + clear + clear)] {
            try write("assets/test/textures/item/\(name).png", Self.png(pixels))
        }
        // Flat colors mark independent regions of a 64x64 entity skin. Axis-aligned views
        // let the pixel tests identify the lid, body, latch and flipped shulker top directly.
        for container in ["chest", "shulker"] {
            for (view, rotation) in [("front", [0, 0, 0]), ("top", [90, 0, 0]), ("side", [0, -90, 0])] {
                let id = container + "_" + view
                var model: [String: Any] = [
                    "type": "minecraft:special", "base": "test:item/" + id,
                    "model": ["type": container == "chest" ? "minecraft:chest" : "minecraft:shulker_box",
                              "texture": container == "chest" ? "minecraft:normal" : "minecraft:shulker_red"]
                ]
                if container == "shulker" {
                    model["transformation"] = ["left_rotation": [1, 0, 0, 0],
                                               "right_rotation": [0, 0, 0, 1],
                                               "translation": [0.5, 1.4995, 0.5],
                                               "scale": [0.9995, 0.9995, 0.9995]]
                }
                try json("assets/test/items/\(id).json", ["model": model])
                try json("assets/test/models/item/\(id).json", [
                    "gui_light": "front", "display": ["gui": ["rotation": rotation]]
                ])
            }
        }
        func skin(_ regions: [(Int, Int, Int, Int, [UInt8])]) throws -> Data {
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            for (x, y, width, height, color) in regions {
                for row in y..<y + height {
                    for column in x..<x + width {
                        let index = (row * 64 + column) * 4
                        pixels.replaceSubrange(index..<index + 4, with: color)
                    }
                }
            }
            return try Self.png(pixels, width: 64, height: 64)
        }
        let cyan: [UInt8] = [0, 255, 255, 255], yellow: [UInt8] = [255, 255, 0, 255]
        try write("assets/minecraft/textures/entity/chest/normal.png", skin([
            (28, 0, 14, 14, red), (42, 14, 14, 5, blue), (42, 33, 14, 10, green),
            (28, 33, 14, 10, cyan), (4, 1, 2, 4, yellow)
        ]))
        try write("assets/minecraft/textures/entity/shulker/shulker_red.png", skin([
            (16, 0, 16, 16, red), (16, 16, 16, 12, blue), (16, 44, 16, 8, green),
            (32, 16, 16, 12, cyan)
        ]))
        var colorMap = Array(repeating: red, count: 256 * 256).flatMap { $0 }
        colorMap.replaceSubrange(0..<4, with: green)
        try write("assets/minecraft/textures/colormap/grass.png", Self.png(colorMap, width: 256, height: 256))
        for (path, data) in extraFiles { try write(path, data) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", source.path, jar.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func library() throws -> GameAssetLibrary { GameAssetLibrary(assets: try #require(try GameAssets(contentsOf: jar)), sourceKey: CacheKey.hash(jar.path)) }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func png(_ pixels: [UInt8], width: Int = 2, height: Int = 2) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try png(image)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    struct Pixels {
        let width: Int
        let bytes: [UInt8]
        func color(_ x: Int, _ y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<start + 4])
        }
    }
    static func pixels(_ image: CGImage) throws -> Pixels {
        let bytes = try #require(image.dataProvider?.data) as Data
        return Pixels(width: image.width, bytes: Array(bytes))
    }
}
