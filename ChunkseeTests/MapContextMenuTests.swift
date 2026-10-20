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
            var content = MapContent()
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
            var content = MapContent()
            content.savedPlaces = [place]
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("previous", forType: .string)
            let root = try #require(MapContextMenuContent(at: CGPoint(x: 206, y: 150), session: session, map: map,
                                                         content: content, size: size, pasteboard: board))
            let pinMenu = menu(root)
            let sidebarMenu = menu(SavedPlaceMenu(session: session, place: place, map: map, pasteboard: board))
            #expect(sidebarMenu.items.map(\.title) == ["Rename…", "Copy Coordinates", "Measure Distance from Here", "", "Remove"])
            #expect(pinMenu.items.map(\.title) == sidebarMenu.items.map(\.title))
            #expect(map.viewport == original && session.selection.sidebarSelection == nil)
            try perform("Rename…", in: pinMenu)
            #expect(session.annotations.draft?.existingID == place.id && session.annotations.draft?.name == place.name)
            #expect(session.annotations.draft?.position == place.position)
            session.annotations.draft = nil

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
            var content = MapContent()
            content.creatures = [pet]
            let root = try #require(MapContextMenuContent(at: click, session: session, map: map,
                                                         content: content, size: size, pasteboard: board))
            let markerMenu = menu(root)
            #expect(markerMenu.items.map(\.title) == ["Copy Coordinates", "Save Place…", "Measure Distance from Here"])
            try perform("Copy Coordinates", in: markerMenu)
            #expect(board.string(forType: .string) == "-9 63 -9")
            #expect(map.unfinishedCoordinateReads == 0)
            try perform("Save Place…", in: markerMenu)
            #expect(session.annotations.draft?.position == CGPoint(x: -9, y: -9))
            session.annotations.draft = nil
            try perform("Measure Distance from Here", in: markerMenu)
            #expect(session.annotations.ruler.start?.position == CGPoint(x: -9, y: -9))

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
                                                              content: MapContent(), size: size, pasteboard: board))
            let emptyMenu = menu(emptyRoot)
            try perform("Copy Coordinates", in: emptyMenu)
            await map.waitForCoordinateReads()
            #expect(board.string(forType: .string) == "-5 2 -9")
            try perform("Save Place…", in: emptyMenu)
            #expect(session.annotations.draft?.position == CGPoint(x: -5, y: -9))
            session.annotations.draft = nil
            try perform("Measure Distance from Here", in: emptyMenu)
            #expect(session.annotations.ruler.start?.position == CGPoint(x: -5, y: -9))
            tappedRuler.clear()
            let emptyLocation = try #require(MapContent().location(at: click, viewport: map.viewport, size: size))
            tappedRuler.mark(emptyLocation.position)
            #expect(tappedRuler.start == session.annotations.ruler.start)
            #expect(emptyLocation.target == nil && emptyLocation.y == nil)
            #expect(content.location(at: CGPoint(x: CGFloat.nan, y: 0), viewport: map.viewport, size: size) == nil)
            #expect(map.viewport == original)
        }
    }

    @Test func closedDocumentsAndUnavailableDimensionsCannotCopyOrChangeTheirAnnotations() async throws {
        try await withSession { session in
            let map = try #require(session.map)
            let place = try #require(session.savedPlaces.add(name: "Fixture", dimension: "missing:dimension", at: .zero))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("unchanged", forType: .string)
            let savedMenu = menu(SavedPlaceMenu(session: session, place: place, map: map, pasteboard: board))
            let copy = try #require(savedMenu.items.first { $0.title == "Copy Coordinates" })
            #expect(!copy.isEnabled)
            let measure = try #require(savedMenu.items.first { $0.title == "Measure Distance from Here" })
            #expect(!measure.isEnabled)
            let localPlace = try #require(session.savedPlaces.add(name: "Local", dimension: map.dimension.id, at: .zero))
            let withoutMap = menu(SavedPlaceMenu(session: session, place: localPlace, map: nil, pasteboard: board))
            let unavailable = try #require(withoutMap.items.first { $0.title == "Measure Distance from Here" })
            #expect(!unavailable.isEnabled)
            for source in [savedMenu, withoutMap] { try perform("Measure Distance from Here", in: source) }
            #expect(!session.annotations.ruler.isEnabled && session.annotations.ruler.start == nil)
            let root = try #require(MapContextMenuContent(at: CGPoint(x: 200, y: 150), session: session, map: map,
                                                         content: MapContent(), size: size, pasteboard: board))
            let mapMenu = menu(root)
            session.close()
            await session.waitUntilClosed()
            for source in [savedMenu, mapMenu] {
                source.update()
                for item in source.items where !item.isSeparatorItem { #expect(!item.isEnabled) }
            }
            try perform("Remove", in: savedMenu)
            try perform("Rename…", in: savedMenu)
            try perform("Copy Coordinates", in: mapMenu)
            try perform("Measure Distance from Here", in: mapMenu)
            #expect(session.savedPlaces.all == [place, localPlace] && session.annotations.draft == nil)
            #expect(!session.annotations.ruler.isEnabled && session.annotations.ruler.start == nil)
            #expect(board.string(forType: .string) == "unchanged")
            #expect(MapContextMenuContent(at: .zero, session: session, map: map, content: MapContent(), size: size) == nil)
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
                return MapContextMenuContent(at: point, session: session, map: map, content: MapContent(), size: size)
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
                #expect(native.items.map(\.title) == ["Copy Coordinates", "Save Place…", "Measure Distance from Here"])
            }
            #expect(received == [CGPoint(x: 120, y: 200), CGPoint(x: 120, y: 200)])
        }
    }
}
