import ChunkseeKit
import Foundation
import Observation

/// A proposed entrance, separate from saved portals and the document's selected item.
@Observable
final class PortalPlanDraft: Identifiable {
    let id = UUID()
    let dimension: String
    private let column: MapCoordinates
    private var wasEdited = false
    var coordinates: String {
        didSet { if coordinates != oldValue { wasEdited = true } }
    }

    init(dimension: String, column: MapCoordinates, height: Int?) {
        self.dimension = dimension
        self.column = column
        coordinates = column.entryText(height: height)
    }

    /// An asynchronous surface read must not overwrite any intervening edit, even an edit back.
    func fillHeight(_ height: Int?) {
        guard !wasEdited, let height else { return }
        coordinates = column.entryText(height: height)
    }

    var entrance: NetherPortal.Block? {
        guard let point = MapCoordinates(text: coordinates), let y = point.y,
              Coordinates(point.position, y: y).isMappable else { return nil }
        return NetherPortal.Block(x: Int(point.x), y: y, z: Int(point.z))
    }
}

/// The library owns scaling and linking; missing index data remains distinct from an empty list.
nonisolated struct PortalPlan {
    let targetDimension: String
    let destination: NetherPortal.Block
    let link: NetherPortal.Link?

    init?(entrance: NetherPortal.Block, dimension: String, portals: [String: [NetherPortal]]) {
        guard let target = NetherPortal.targetDimension(from: dimension),
              let destination = NetherPortal.destination(of: entrance, from: dimension) else { return nil }
        targetDimension = target
        self.destination = destination
        let proposed = NetherPortal(dimension: dimension, blocks: [entrance])
        link = portals[target].flatMap { proposed.link(into: $0, entering: entrance) }
    }
}
