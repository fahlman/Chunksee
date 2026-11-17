import AppKit
import ApplicationServices
import CoreGraphics
import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized) struct MapContextMenuTests {
    private let size = CGSize(width: 400, height: 300)

    private func withSession(_ body: (WorldSession) async throws -> Void) async throws {
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: -1, z: -1,
            palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= 2 ? 1 : 0 }])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        do { try await body(session) }
        catch { session.close(); await session.waitUntilClosed(); throw error }
        session.close()
        await session.waitUntilClosed()
    }

    private func menu<Content: View>(_ content: Content) -> NSMenu {
        let menu = MapContextMenu.make { content }
        menu.update()
        return menu
    }

    private func perform(_ title: String, in menu: NSMenu) throws {
        menu.update()
        let index = try #require(menu.items.firstIndex { $0.title == title && !$0.isSeparatorItem })
        menu.performActionForItem(at: index)
    }

    @Test(.timeLimit(.minutes(1))) func nativeAccessibilityFramesContainTheirMarkers() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            map.viewport = MapViewport(center: .zero, scale: 2)
            var content = MapContent(gameNames: .unavailable)
            content.savedPlaces = [
                SavedPlace(name: "West Marker", dimension: map.dimension.id, x: -50, z: -30),
                SavedPlace(name: "East Marker", dimension: map.dimension.id, x: 40, z: 25),
            ]
            let appeared = AsyncStream<Void>.makeStream()
            let host = NSHostingView(rootView: MapView(session: session, map: map, content: content)
                .frame(width: size.width, height: size.height)
                .onAppear { appeared.continuation.yield(()); appeared.continuation.finish() })
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for await _ in appeared.stream { }

            // An AX client activates SwiftUI's lazy accessibility tree. Leave the main actor
            // free to answer its request, then use the public selectors: virtual SwiftUI nodes
            // implement them without declaring AppKit's full NSAccessibilityProtocol.
            let activation = await Task.detached {
                var windows: CFTypeRef?
                return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows).rawValue
            }.value
            try #require(activation == AXError.success.rawValue)
            func frames(of node: AnyObject) -> [(String, CGRect)] {
                let label = node.accessibilityLabel?() ?? ""
                let frame = node.accessibilityFrame?() ?? .zero
                let children = node.accessibilityChildren?() ?? []
                return [(label, frame)] + children.flatMap { frames(of: $0 as AnyObject) }
            }
            let nativeFrames = frames(of: host)

            for location in content.accessibleLocations(viewport: map.viewport, size: size) {
                let frame = try #require(nativeFrames.first { $0.0 == location.name }?.1)
                let point = map.viewport.viewPoint(for: location.anchor ?? location.position, in: size)
                let local = CGPoint(x: point.x, y: host.isFlipped ? point.y : size.height - point.y)
                let screen = window.convertPoint(toScreen: host.convert(local, to: nil))
                #expect(frame.contains(screen))
                #expect(abs(frame.width - location.frame.width) < 1)
                #expect(abs(frame.height - location.frame.height) < 1)
            }
        }
    }

    @Test func aSavedPinAndSidebarShareCommandsWithoutMovingTheMap() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let place = try #require(session.savedPlaces.add(name: "Fixture", dimension: map.dimension.id, at: CGPoint(x: -8, y: -8)))
            map.viewport = MapViewport(center: place.position, scale: 2)
            let original = map.viewport
            var content = MapContent(gameNames: .unavailable)
            content.savedPlaces = [place]
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("previous", forType: .string)
            let root = try #require(MapContextMenuContent(at: CGPoint(x: 206, y: 150), session: session, map: map,
                                                         content: content, size: size, pasteboard: board))
            let pinMenu = menu(root)
            let sidebarMenu = menu(SavedPlaceMenu(session: session, place: place, pasteboard: board))
            #expect(sidebarMenu.items.map(\.title) == ["Copy Coordinates", "Rename…", "Measure Distance from Here", "Plan Portal Here…", "", "Remove"])
            #expect(pinMenu.items.map(\.title) == sidebarMenu.items.map(\.title))
            #expect(map.viewport == original && session.selection.sidebarSelection == nil)
            try perform("Rename…", in: pinMenu)
            #expect(session.sheet?.savedPlaceDraft?.existingID == place.id && session.sheet?.savedPlaceDraft?.name == place.name)
            #expect(session.sheet?.savedPlaceDraft?.position == place.position)
            session.sheet = nil

            for source in [pinMenu, sidebarMenu] {
                board.setString("previous", forType: .string)
                try perform("Copy Coordinates", in: source)
                await map.waitForCoordinateReads()
                #expect(board.string(forType: .string) == "-8 2 -8")
                session.annotations.ruler.isEnabled = false
                session.annotations.ruler.clear()
                try perform("Measure Distance from Here", in: source)
                #expect(session.annotations.ruler.isEnabled && session.annotations.ruler.start?.position == place.position)
                #expect(session.annotations.ruler.end == nil)
                #expect(map.viewport == original && session.selection.sidebarSelection == nil)
            }
            try perform("Remove", in: pinMenu)
            #expect(session.savedPlaces.all.isEmpty)
        }
    }

    @Test func markerAndEmptyMenusUseOneAnchorForCopySaveAndMeasure() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let pet = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: -8.7, y: 63.9, z: -8.1,
                                                           owner: UUID()), dimension: map.dimension.id))
            map.viewport = MapViewport(center: pet.position, scale: 2)
            let original = map.viewport, click = CGPoint(x: 208, y: 150)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            var content = MapContent(gameNames: .unavailable)
            content.creatures = [pet]
            let root = try #require(MapContextMenuContent(at: click, session: session, map: map,
                                                         content: content, size: size, pasteboard: board))
            let markerMenu = menu(root)
            #expect(markerMenu.items.map(\.title) == ["Copy Coordinates", "Save Place…", "Measure Distance from Here", "Plan Portal Here…"])
            try perform("Copy Coordinates", in: markerMenu)
            #expect(board.string(forType: .string) == "-9 63 -9")
            #expect(map.unfinishedCoordinateReads == 0)
            try perform("Save Place…", in: markerMenu)
            #expect(session.sheet?.savedPlaceDraft?.position == CGPoint(x: -9, y: -9))
            session.sheet = nil
            try perform("Measure Distance from Here", in: markerMenu)
            #expect(session.annotations.ruler.start?.position == CGPoint(x: -9, y: -9))
            try perform("Plan Portal Here…", in: markerMenu)
            #expect(session.sheet?.portalDraft?.entrance == .init(x: -9, y: 63, z: -9))
            #expect(map.unfinishedCoordinateReads == 0)
            session.sheet = nil

            // The same off-center pointer click while measuring uses the marker, not the block
            // behind its badge. Both entry paths keep whole-block endpoints at negative positions.
            let markerLocation = try #require(content.location(at: click, viewport: map.viewport, size: size))
            var tappedRuler = MapRuler()
            tappedRuler.isEnabled = true
            tappedRuler.mark(markerLocation.position)
            #expect(tappedRuler.start == session.annotations.ruler.start)
            #expect(markerLocation.y == 63.9)
            let endLocation = try #require(content.location(at: CGPoint(x: 300, y: 150), viewport: map.viewport, size: size))
            tappedRuler.mark(endLocation.position)
            session.annotations.ruler.mark(endLocation.position)
            #expect(tappedRuler.distance == 50 && session.annotations.ruler.distance == 50)

            let emptyRoot = try #require(MapContextMenuContent(at: click, session: session, map: map,
                                                              content: MapContent(gameNames: .unavailable), size: size, pasteboard: board))
            let emptyMenu = menu(emptyRoot)
            try perform("Copy Coordinates", in: emptyMenu)
            await map.waitForCoordinateReads()
            #expect(board.string(forType: .string) == "-5 2 -9")
            try perform("Save Place…", in: emptyMenu)
            #expect(session.sheet?.savedPlaceDraft?.position == CGPoint(x: -5, y: -9))
            session.sheet = nil
            try perform("Measure Distance from Here", in: emptyMenu)
            #expect(session.annotations.ruler.start?.position == CGPoint(x: -5, y: -9))
            try perform("Plan Portal Here…", in: emptyMenu)
            await map.waitForCoordinateReads()
            #expect(session.sheet?.portalDraft?.entrance == .init(x: -5, y: 2, z: -9))
            session.sheet = nil
            tappedRuler.clear()
            let emptyLocation = try #require(MapContent(gameNames: .unavailable).location(at: click, viewport: map.viewport, size: size))
            tappedRuler.mark(emptyLocation.position)
            #expect(tappedRuler.start == session.annotations.ruler.start)
            #expect(emptyLocation.target == nil && emptyLocation.y == nil)
            #expect(content.location(at: CGPoint(x: CGFloat.nan, y: 0), viewport: map.viewport, size: size) == nil)
            #expect(map.viewport == original)
        }
    }

    @Test func layerRowsAndMapMarkersShareLocationCommandsAndHeights() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }

            @MainActor func check<Marker: MapLayerMarker>(_ marker: Marker, content: MapContent?,
                                               copied: String, block: CGPoint) async throws {
                map.viewport = MapViewport(center: marker.position, scale: 2)
                let original = map.viewport
                var sources = [menu(LocationMenu(session: session, position: marker.position, dimension: map.dimension.id,
                                                 y: marker.yCoordinate, pasteboard: board))]
                if let content {
                    let root = try #require(MapContextMenuContent(at: CGPoint(x: 204, y: 150), session: session,
                                                                 map: map, content: content, size: size,
                                                                 pasteboard: board))
                    sources.append(menu(root))
                }
                for source in sources {
                    #expect(source.items.map(\.title) == ["Copy Coordinates", "Save Place…", "Measure Distance from Here", "Plan Portal Here…"])
                    board.clearContents()
                    board.setString("previous", forType: .string)
                    try perform("Copy Coordinates", in: source)
                    if marker.yCoordinate != nil { #expect(map.unfinishedCoordinateReads == 0) }
                    await map.waitForCoordinateReads()
                    #expect(board.string(forType: .string) == copied)
                    try perform("Save Place…", in: source)
                    #expect(session.sheet?.savedPlaceDraft?.position == block)
                    #expect(session.sheet?.savedPlaceDraft?.dimension == map.dimension.id)
                    session.sheet = nil
                    session.annotations.ruler.clear()
                    try perform("Measure Distance from Here", in: source)
                    #expect(session.annotations.ruler.start?.position == block)
                    #expect(map.viewport == original && session.selection.sidebarSelection == nil)
                }
            }

            let pet = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: -8.7, y: 63.9, z: -8.1,
                                                           owner: UUID()), dimension: map.dimension.id))
            var content = MapContent(gameNames: .unavailable)
            content.creatures = [pet]
            try await check(pet, content: content, copied: "-9 63 -9", block: CGPoint(x: -9, y: -9))

            let place = PlaceMarker(Spawner(x: -7, y: -23, z: -4, mob: "minecraft:zombie"))
            content = MapContent(gameNames: .unavailable)
            content.places = [place]
            try await check(place, content: content, copied: "-7 -23 -4", block: CGPoint(x: -7, y: -4))

            var structure = try StructureMarker(StructureTests().start("minecraft:mineshaft", chunk: (-1, -1),
                                              pieces: [("piece", [-14, -60, -14, -11, -41, -11])]))
            content = MapContent(gameNames: .unavailable)
            content.structures = [structure]
            try await check(structure, content: content, copied: "-12 -50 -12", block: CGPoint(x: -12, y: -12))
            structure.y = nil
            content.structures = [structure]
            try await check(structure, content: content, copied: "-12 2 -12", block: CGPoint(x: -12, y: -12))

            let biome = BiomeArea(id: "plains", group: BiomeGroup(id: "minecraft:plains"), chunkCount: 1,
                                 position: CGPoint(x: -8, y: -8), bounds: CGRect(x: -16, y: -16, width: 16, height: 16),
                                 chunks: Path(), outline: Path())
            try await check(biome, content: nil, copied: "-8 2 -8", block: CGPoint(x: -8, y: -8))
        }
    }

    @Test func otherDimensionMenusCopySavedHeightsButNeverReadThisMapsTerrain() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let position = CGPoint(x: -8.7, y: -8.1)
            let original = map.viewport
            for dimension in ["minecraft:the_nether", "missing:dimension"] {
                let saved = menu(LocationMenu(session: session, position: position, dimension: dimension,
                                              y: -1.2, pasteboard: board))
                #expect(try #require(saved.items.first { $0.title == "Copy Coordinates" }).isEnabled)
                #expect(!(try #require(saved.items.first { $0.title == "Measure Distance from Here" }).isEnabled))
                try perform("Copy Coordinates", in: saved)
                #expect(board.string(forType: .string) == "-9 -2 -9")
                #expect(map.unfinishedCoordinateReads == 0)
                try perform("Save Place…", in: saved)
                #expect(session.sheet?.savedPlaceDraft?.dimension == dimension)
                #expect(session.sheet?.savedPlaceDraft?.position == CGPoint(x: -9, y: -9))
                session.sheet = nil
                try perform("Measure Distance from Here", in: saved)
                #expect(!session.annotations.ruler.isEnabled && session.annotations.ruler.start == nil)

                let unknown = menu(LocationMenu(session: session, position: position, dimension: dimension,
                                                y: nil, pasteboard: board))
                #expect(!(try #require(unknown.items.first { $0.title == "Copy Coordinates" }).isEnabled))
                board.clearContents()
                board.setString("unchanged", forType: .string)
                try perform("Copy Coordinates", in: unknown)
                let place = try #require(session.savedPlaces.add(name: "Elsewhere", dimension: dimension, at: position))
                let savedPlace = menu(SavedPlaceMenu(session: session, place: place, pasteboard: board))
                #expect(!(try #require(savedPlace.items.first { $0.title == "Copy Coordinates" }).isEnabled))
                try perform("Copy Coordinates", in: savedPlace)
                #expect(board.string(forType: .string) == "unchanged")
                #expect(map.unfinishedCoordinateReads == 0 && map.viewport == original)
                #expect(session.selection.sidebarSelection == nil)
            }
        }
    }

    @Test func savedCoordinatesCopyWithoutAMapUntilTheDocumentCloses() async throws {
        try await withSession { session in
            let dimension = "missing:dimension"
            let unmapped = WorldSession(resources: session.resources, dimensionID: dimension)
            #expect(unmapped.map == nil)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let saved = menu(LocationMenu(session: unmapped, position: CGPoint(x: -8.7, y: 12.3),
                                          dimension: dimension, y: 64.9, pasteboard: board))
            #expect(try #require(saved.items.first { $0.title == "Copy Coordinates" }).isEnabled)
            try perform("Copy Coordinates", in: saved)
            #expect(board.string(forType: .string) == "-9 64 12")
            unmapped.close()
            await unmapped.waitUntilClosed()
            board.clearContents()
            board.setString("after close", forType: .string)
            saved.update()
            for item in saved.items { #expect(!item.isEnabled) }
            try perform("Copy Coordinates", in: saved)
            try perform("Save Place…", in: saved)
            try perform("Measure Distance from Here", in: saved)
            #expect(board.string(forType: .string) == "after close")
            #expect(unmapped.sheet == nil && !unmapped.annotations.ruler.isEnabled)
        }
    }

    @Test func closedDocumentsAndUnavailableDimensionsCannotCopyOrChangeTheirAnnotations() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let place = try #require(session.savedPlaces.add(name: "Fixture", dimension: "missing:dimension", at: .zero))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("unchanged", forType: .string)
            let savedMenu = menu(SavedPlaceMenu(session: session, place: place, pasteboard: board))
            let copy = try #require(savedMenu.items.first { $0.title == "Copy Coordinates" })
            #expect(!copy.isEnabled)
            let measure = try #require(savedMenu.items.first { $0.title == "Measure Distance from Here" })
            #expect(!measure.isEnabled)
            #expect(!(try #require(savedMenu.items.first { $0.title == "Plan Portal Here…" })).isEnabled)
            let unmapped = WorldSession(resources: session.resources, dimensionID: place.dimension)
            let withoutMap = menu(SavedPlaceMenu(session: unmapped, place: place, pasteboard: board))
            let unavailable = try #require(withoutMap.items.first { $0.title == "Measure Distance from Here" })
            #expect(unmapped.map == nil && !unavailable.isEnabled && !unmapped.annotations.canMeasure(in: place.dimension))
            for source in [savedMenu, withoutMap] { try perform("Measure Distance from Here", in: source) }
            unmapped.annotations.beginMeasurement(at: .zero, in: place.dimension)
            session.annotations.beginMeasurement(at: .zero, in: place.dimension)
            #expect(!unmapped.annotations.ruler.isEnabled && unmapped.annotations.ruler.start == nil)
            #expect(!session.annotations.ruler.isEnabled && session.annotations.ruler.start == nil)
            unmapped.close()
            await unmapped.waitUntilClosed()
            let root = try #require(MapContextMenuContent(at: CGPoint(x: 200, y: 150), session: session, map: map,
                                                         content: MapContent(gameNames: .unavailable), size: size, pasteboard: board))
            let mapMenu = menu(root)
            let rowMenu = menu(LocationMenu(session: session, position: .zero, dimension: map.dimension.id, y: 64, pasteboard: board))
            session.close()
            await session.waitUntilClosed()
            for source in [savedMenu, mapMenu, rowMenu] {
                source.update()
                for item in source.items where !item.isSeparatorItem { #expect(!item.isEnabled) }
            }
            try perform("Plan Portal Here…", in: rowMenu)
            #expect(session.sheet?.portalDraft == nil)
            try perform("Remove", in: savedMenu)
            try perform("Rename…", in: savedMenu)
            try perform("Copy Coordinates", in: mapMenu)
            try perform("Measure Distance from Here", in: mapMenu)
            try perform("Copy Coordinates", in: rowMenu)
            try perform("Save Place…", in: rowMenu)
            try perform("Measure Distance from Here", in: rowMenu)
            #expect(session.savedPlaces.all == [place] && session.sheet?.savedPlaceDraft == nil)
            #expect(!session.annotations.ruler.isEnabled && session.annotations.ruler.start == nil)
            #expect(board.string(forType: .string) == "unchanged")
            #expect(MapContextMenuContent(at: .zero, session: session, map: map, content: MapContent(gameNames: .unavailable), size: size) == nil)
        }
    }

    @Test func nativePointerMenusRejectAnotherWindowAndConvertTheCorrectWindowPoint() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let own = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            let other = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            own.isReleasedWhenClosed = false
            other.isReleasedWhenClosed = false
            defer { own.close(); other.close() }
            var received: [CGPoint] = []
            let view = MapScrollView(perform: { _ in }, contextContent: { point in
                received.append(point)
                return MapContextMenuContent(at: point, session: session, map: map, content: MapContent(gameNames: .unavailable), size: size)
            })
            own.contentView = view
            @MainActor func event(_ window: NSWindow, at point: CGPoint, control: Bool = false) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: control ? .leftMouseDown : .rightMouseDown, location: point,
                                               modifierFlags: control ? .control : [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            #expect(view.menu(for: try event(other, at: CGPoint(x: 120, y: 100))) == nil)
            #expect(view.menu(for: try event(own, at: CGPoint(x: 800, y: 900))) == nil)
            #expect(received.isEmpty)
            for control in [false, true] {
                let native = try #require(view.menu(for: try event(own, at: CGPoint(x: 120, y: 100), control: control)))
                native.update()
                #expect(native.items.map(\.title) == ["Copy Coordinates", "Save Place…", "Measure Distance from Here", "Plan Portal Here…"])
            }
            #expect(received == [CGPoint(x: 120, y: 200), CGPoint(x: 120, y: 200)])
        }
    }
}
