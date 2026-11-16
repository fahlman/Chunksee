import CoreGraphics
import Foundation
@testable import ChunkseeTestHost

/// The retired marker-cache shape is a fixture, not a persistence contract for live markers.
nonisolated struct LegacyStructureMarker: Encodable {
    let id: String
    let structureID: String
    let group: String
    let bounds: CGRect
    let y: Int?
    let portalRoom: CGPoint?

    init(_ marker: StructureMarker) {
        id = marker.id
        structureID = marker.structureID
        group = marker.group.rawValue
        bounds = marker.bounds
        y = marker.y
        portalRoom = marker.portalRoom
    }
}
