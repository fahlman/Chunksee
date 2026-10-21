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
    var pasteboard: NSPasteboard = .general

    var body: some View {
        Group {
            Button("Rename…") { session.annotations.edit(place) }
            CopyCoordinatesCommand(session: session, position: place.position, dimension: place.dimension,
                                   y: nil, pasteboard: pasteboard)
            MeasureDistanceCommand(session: session, position: place.position, dimension: place.dimension)
            Divider()
            Button("Remove", role: .destructive) { if !session.isClosed { session.savedPlaces.remove(place.id) } }
        }
        .disabled(session.isClosed)
    }
}

private struct CopyCoordinatesCommand: View {
    let session: WorldSession
    let position: CGPoint
    let dimension: String
    let y: Double?
    let pasteboard: NSPasteboard

    // A saved height does not need a map. An unknown height must never come from another dimension.
    private var map: MapModel? {
        guard let map = session.map, !map.isClosed, map.dimension.id == dimension else { return nil }
        return map
    }

    private var canCopy: Bool {
        MapCoordinates(point: position) != nil && (y.map { Coordinates.block($0) != nil } ?? (map != nil))
    }

    var body: some View {
        Button("Copy Coordinates") {
            if !session.isClosed, canCopy { MapClipboard.copy(position, y: y, on: map, to: pasteboard) }
        }
        .disabled(session.isClosed || !canCopy)
    }
}

private struct MeasureDistanceCommand: View {
    let session: WorldSession
    let position: CGPoint
    let dimension: String

    var body: some View {
        Button("Measure Distance from Here") {
            session.annotations.beginMeasurement(at: position, in: dimension)
        }
        .disabled(!session.annotations.canMeasure(in: dimension))
    }
}

/// The same location commands on map markers, sidebar rows and inspector coordinates.
struct LocationMenu: View {
    let session: WorldSession
    let position: CGPoint
    let dimension: String
    let y: Double?
    var pasteboard: NSPasteboard = .general

    var body: some View {
        Group {
            CopyCoordinatesCommand(session: session, position: position, dimension: dimension,
                                   y: y, pasteboard: pasteboard)
            Button("Save Place…") { session.annotations.savePlace(at: position, in: dimension) }
            MeasureDistanceCommand(session: session, position: position, dimension: dimension)
        }
        .disabled(session.isClosed)
    }
}

extension View {
    func locationMenu(session: WorldSession, position: CGPoint?, dimension: String?, y: Double?) -> some View {
        contextMenu {
            if let position, let dimension {
                LocationMenu(session: session, position: position, dimension: dimension, y: y)
            }
        }
    }
}

/// Inspector coordinates share native activation, validation and location commands.
struct LocationRow: View {
    var title = Text("Location")
    let session: WorldSession
    let destination: MapDestination
    var showsDimension = false

    var body: some View {
        let coordinates = destination.coordinates
        let dimension = destination.dimension
        Button {
            session.routing.focus(on: destination)
        } label: {
            LabeledContent {
                CoordinateText(coordinates, dimension: showsDimension ? dimension.map(session.presentation.dimensionName) : nil)
                    .textSelection(.disabled)
            } label: {
                title
            }
        }
        .disabled(!session.routing.canFocus(coordinates, in: dimension))
        .locationMenu(session: session, position: coordinates.point, dimension: dimension, y: coordinates.y)
    }
}

/// Resolve the pointer once through the same hit test as selection, before the menu opens.
struct MapContextMenuContent: View {
    private let session: WorldSession
    private let dimension: String
    private let position: CGPoint
    private let y: Double?
    private let place: SavedPlace?
    private let pasteboard: NSPasteboard

    init?(at point: CGPoint, session: WorldSession, map: MapModel, content: MapContent,
          size: CGSize, pasteboard: NSPasteboard = .general) {
        guard !session.isClosed,
              let location = content.location(at: point, viewport: map.viewport, size: size) else { return nil }
        self.session = session
        self.dimension = map.dimension.id
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
                SavedPlaceMenu(session: session, place: place, pasteboard: pasteboard)
            } else {
                LocationMenu(session: session, position: position, dimension: dimension, y: y, pasteboard: pasteboard)
            }
        }
        .disabled(session.isClosed)
    }
}

enum MapClipboard {
    private static var requests: [NSPasteboard.Name: UUID] = [:]

    /// Every Copy Coordinates action comes here. A marker supplies its saved Y; other locations
    /// use the block actually drawn by this map. A late read cannot replace a newer clipboard.
    static func copy(_ point: CGPoint, y: Double? = nil, on map: MapModel?, to pasteboard: NSPasteboard = .general) {
        guard let coordinates = MapCoordinates(point: point), y != nil || map != nil else { return }
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
        } else if let map {
            map.readTopBlock(at: coordinates.position) { finish($0?.y) }
        }
    }
}
