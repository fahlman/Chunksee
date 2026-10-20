import AppKit
import ChunkseeKit
import SwiftUI

/// SwiftUI has no map-point argument for contextMenu. AppKit captures the native event point;
/// NSHostingMenu presents SwiftUI's commands with that point's world-coordinate snapshot.
enum MapContextMenu {
    static func make<Content: View>(@ViewBuilder content: () -> Content) -> NSMenu {
        NSHostingMenu(rootView: content())
    }
}

/// Identical saved-place commands for the sidebar and a map pin's native context menu.
struct SavedPlaceMenu: View {
    let session: WorldSession
    let place: SavedPlace
    let map: MapModel?
    var pasteboard: NSPasteboard = .general

    var body: some View {
        Group {
            Button("Rename…") { session.annotations.edit(place) }
            Button("Copy Coordinates") {
                if !session.isClosed, session.annotations.canVisit(place), let map {
                    MapClipboard.copy(place.position, on: map, to: pasteboard)
                }
            }
            .disabled(map == nil || !session.annotations.canVisit(place))
            Divider()
            Button("Remove", role: .destructive) { if !session.isClosed { session.savedPlaces.remove(place.id) } }
        }
        .disabled(session.isClosed)
    }
}

/// Resolve the pointer once through the same hit test as selection, before the menu opens.
struct MapContextMenuContent: View {
    private let session: WorldSession
    private let map: MapModel
    private let position: CGPoint
    private let y: Double?
    private let place: SavedPlace?
    private let pasteboard: NSPasteboard

    init?(at point: CGPoint, session: WorldSession, map: MapModel, content: MapContent,
          size: CGSize, pasteboard: NSPasteboard = .general) {
        guard !session.isClosed,
              let location = content.location(at: point, viewport: map.viewport, size: size) else { return nil }
        self.session = session
        self.map = map
        self.position = location.position
        self.y = location.y
        if case .row(.savedPlace(let id))? = location.target {
            place = session.annotations.listedPlaces.first { $0.id == id }
        } else {
            place = nil
        }
        self.pasteboard = pasteboard
    }

    var body: some View {
        Group {
            if let place {
                SavedPlaceMenu(session: session, place: place, map: map, pasteboard: pasteboard)
                Divider()
            } else {
                Button("Copy Coordinates") {
                    if !session.isClosed { MapClipboard.copy(position, y: y, on: map, to: pasteboard) }
                }
                Button("Save Place…") { session.annotations.savePlace(at: position, in: map.dimension.id) }
            }
            Button("Measure Distance from Here") { session.annotations.beginMeasurement(at: position, in: map.dimension.id) }
        }
        .disabled(session.isClosed)
    }
}

enum MapClipboard {
    private static var requests: [NSPasteboard.Name: UUID] = [:]

    /// Every Copy Coordinates action comes here. A marker supplies its saved Y; other locations
    /// use the block actually drawn by this map. A late read cannot replace a newer clipboard.
    static func copy(_ point: CGPoint, y: Double? = nil, on map: MapModel, to pasteboard: NSPasteboard = .general) {
        guard let coordinates = MapCoordinates(point: point) else { return }
        let id = UUID(), changeCount = pasteboard.changeCount
        requests[pasteboard.name] = id
        func finish(_ y: Int?) {
            guard requests[pasteboard.name] == id else { return }
            requests[pasteboard.name] = nil
            guard pasteboard.changeCount == changeCount else { return }
            guard let y else { NSSound.beep(); return }
            pasteboard.clearContents()
            pasteboard.setString("\(coordinates.x) \(y) \(coordinates.z)", forType: .string)
        }
        if let y {
            finish(Coordinates.block(y))
        } else {
            map.readTopBlock(at: coordinates.position) { finish($0?.y) }
        }
    }
}
