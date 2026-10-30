import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldSourceReplacementTests {
    private final class Fixture {
        let original: URL
        let moved: URL
        let copy: URL
        let alias: URL
        let model: AppModel
        var sessions: [WorldSession] = []

        init() throws {
            original = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
            moved = original.appendingPathExtension("moved")
            copy = original.appendingPathExtension("copy")
            alias = original.appendingPathExtension("alias")
            model = AppModel(defaults: TestDefaults.make(), cacheRoot: nil)
            try FileManager.default.createDirectory(at: document("the_nether", at: original).appendingPathComponent("region"), withIntermediateDirectories: true)
            try Self.writeMap(at: original, center: 10)
            try model.worldFolders.remember(original)
        }

        func document(_ dimension: String = "overworld", at root: URL) -> URL {
            root.appendingPathComponent("dimensions/minecraft/" + dimension)
        }

        static func writeMap(at root: URL, center: Int32) throws {
            try Fixtures.writeGzippedNBT(.compound(["data": .compound([
                "dimension": .string("minecraft:overworld"), "scale": .byte(0),
                "xCenter": .int(center), "zCenter": .int(0),
                "colors": .byteArray([Int8](repeating: 4, count: MapItem.size * MapItem.size)),
            ])]), to: root.appendingPathComponent("data/minecraft/maps/1.dat"))
        }

        func open(_ url: URL, reusing session: WorldSession? = nil, reread: Bool = false) async throws -> WorldSession {
            let reader = WorldDocument.Reader(folders: model.worldFolders, model: model, reuseOpenWorld: { !reread })
            guard case .dimension(let snapshot) = try await reader.readFolder(url) else { throw WorldOpenError.notADimension }
            let opened = try await snapshot.makeSession(in: model, reusing: session)
            if !sessions.contains(where: { $0 === opened }) { sessions.append(opened) }
            return opened
        }

        func close() async {
            sessions.forEach { $0.close() }
            for session in sessions { await session.waitUntilClosed() }
            for url in [alias, original, moved, copy] { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func movedWorldKeepsOneOwnerAndEveryWindowsChoicesAndSavedPlaces() async throws {
        try await withFixture { f in
            let first = try await f.open(f.document(at: f.original))
            let second = try await f.open(f.document("the_nether", at: f.original))
            let resources = first.resources, index = resources.index, places = first.savedPlaces
            let firstMap = try #require(first.map), secondMap = try #require(second.map)
            await resources.waitForRefresh(); await resources.index.waitForIndex()
            first.selection.choose(.inGameMap(1))
            second.selection.choose(.worldInfo)
            first.selection.inGameMapOpacity = 0.3
            first.search.text = "block:minecraft:stone"
            await first.search.waitForSearch()
            firstMap.viewport = MapViewport(center: CGPoint(x: 50, y: 60), scale: 2)
            first.navigation.goToCoordinates(CGPoint(x: 100, y: 200))
            firstMap.setDepth(MapDepth(y: 20, isSurface: false))
            firstMap.setStyle(.height)
            firstMap.setCastsShadows(false)
            secondMap.setStyle(.waterDepth)
            first.annotations.ruler.isEnabled = true
            first.annotations.ruler.mark(.zero); first.annotations.ruler.mark(CGPoint(x: 3, y: 4))
            let view = firstMap.viewport, ruler = first.annotations.ruler, id = first.viewID
            let home = try #require(places.add(name: "Home", dimension: "minecraft:overworld", at: .zero))

            try FileManager.default.moveItem(at: f.original, to: f.moved)
            let reread = try await f.open(f.document(at: f.moved), reusing: first, reread: true)
            await resources.waitForRefresh(); await resources.index.waitForIndex(); await first.search.waitForSearch()
            #expect(reread === first && first.viewID == id && first.map === firstMap && second.map === secondMap)
            #expect(first.resources === resources && second.resources === resources && resources.index === index)
            #expect(resources.url.resolvingSymlinksInPath() == f.moved.resolvingSymlinksInPath())
            #expect(resources.index.readers.count == 2)
            #expect(resources.index.readers.allSatisfy { $0.dimension.url.path.hasPrefix(f.moved.path + "/") })
            #expect((try #require(firstMap.currentRenderer)).dimension.url == f.document(at: f.moved))
            #expect((try #require(secondMap.currentRenderer)).dimension.url == f.document("the_nether", at: f.moved))
            #expect(firstMap.viewport == view && firstMap.depth == MapDepth(y: 20, isSurface: false))
            #expect(firstMap.chosenStyle == .height && !firstMap.castsShadows && secondMap.chosenStyle == .waterDepth)
            #expect(first.navigation.canGoBack && first.annotations.ruler == ruler)
            #expect(first.search.text == "block:minecraft:stone")
            #expect(first.selection.sidebarSelection == .inGameMap(1) && first.selection.inspector == .selection)
            #expect(first.selection.inGameMapOpacity == 0.3 && second.selection.inspector == .world)
            #expect(first.savedPlaces === places && second.savedPlaces === places)
            let away = try #require(second.savedPlaces.add(name: "Away", dimension: "minecraft:the_nether", at: CGPoint(x: 2, y: 3)))
            #expect(Set(first.savedPlaces.all.map(\.id)) == [home.id, away.id])
            first.close(); await first.waitUntilClosed()
            #expect(!resources.isClosed)
            let reopened = try await f.open(f.document(at: f.moved))
            #expect(reopened.resources === resources && reopened.savedPlaces === places)
            #expect(Set(reopened.savedPlaces.all.map(\.id)) == [home.id, away.id])
        }
    }

    @Test func aliasesShareAnOwnerAndAnOpenedCopyHasItsOwnPlaces() async throws {
        try await withFixture { f in
            let first = try await f.open(f.document(at: f.original))
            try FileManager.default.createSymbolicLink(at: f.alias, withDestinationURL: f.original)
            try f.model.worldFolders.remember(f.alias)
            let alias = try await f.open(f.document(at: f.alias))
            #expect(alias.resources === first.resources)
            try FileManager.default.copyItem(at: f.original, to: f.copy)
            try f.model.worldFolders.remember(f.copy)
            let copy = try await f.open(f.document(at: f.copy))
            #expect(copy.resources !== first.resources && copy.resources.settings.worldID != first.resources.settings.worldID)
            let place = try #require(copy.savedPlaces.add(name: "Copy", dimension: "minecraft:overworld", at: .zero))
            #expect(copy.savedPlaces.all == [place] && first.savedPlaces.all.isEmpty && alias.savedPlaces.all.isEmpty)
        }
    }

    @Test func samePathRereadReplacesSavedDataWithoutReplacingTheSession() async throws {
        try await withFixture { f in
            let session = try await f.open(f.document(at: f.original))
            let resources = session.resources, oldSource = resources.readSource
            session.selection.choose(.inGameMap(1))
            session.selection.inGameMapOpacity = 0.2
            let viewport = session.map?.viewport
            try Fixture.writeMap(at: f.original, center: 200)
            let reread = try await f.open(f.document(at: f.original), reusing: session, reread: true)
            #expect(reread === session && reread.resources === resources && resources.readSource !== oldSource)
            #expect(resources.details.maps.first?.centerX == 200)
            #expect(session.selection.sidebarSelection == .inGameMap(1) && session.selection.inspector == .selection)
            #expect(MapContent(session: session).inGameMap?.map.centerX == 200)
            #expect(session.selection.inGameMapOpacity == 0.2 && session.map?.viewport == viewport)
        }
    }

    @Test func aRemovedDimensionStopsReadingAndKeepsItsViewForReappearance() async throws {
        try await withFixture { f in
            let first = try await f.open(f.document(at: f.original))
            let netherURL = f.document("the_nether", at: f.original)
            let second = try await f.open(netherURL), map = try #require(second.map)
            map.setStyle(.waterDepth)
            map.viewport = MapViewport(center: CGPoint(x: 30, y: 60), scale: 4)
            let view = map.viewport
            try FileManager.default.removeItem(at: netherURL)
            _ = try await f.open(f.document(at: f.original), reusing: first, reread: true)
            #expect(second.map === map && map.currentRenderer == nil && map.availableRegions.isEmpty)
            #expect(!second.imageExport.canCreate && map.chosenStyle == .waterDepth && map.viewport == view)
            try FileManager.default.createDirectory(at: netherURL.appendingPathComponent("region"), withIntermediateDirectories: true)
            _ = try await f.open(f.document(at: f.original), reusing: first, reread: true)
            #expect(second.map === map && (try #require(map.currentRenderer)).dimension.url == netherURL)
            #expect(map.chosenStyle == .waterDepth && map.viewport == view)
        }
    }
}
