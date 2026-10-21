import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// App actions delivered through native dimension documents, without owning their windows.
@Observable
final class DimensionRouting {
    @ObservationIgnored private weak var source: WorldSession?
    /// Supplied by the document view, capturing only SwiftUI's environment action.
    @ObservationIgnored var openDocument: ((URL) async throws -> Void)?
    var openFailure: String?

    init(source: WorldSession) { self.source = source }

    func openDimension(_ id: String) {
        guard let source, !source.isClosed, source.dimensions.contains(where: { $0.id == id }) else { return }
        open(id, then: nil)
    }

    /// A cross-dimension action belongs to its destination, even if no opener is available.
    /// Returning true prevents the caller from applying it to the source's map instead.
    func route(to dimension: String, perform: @escaping (WorldSession) -> Void) -> Bool {
        guard let source, !source.isClosed, dimension != source.selectedDimensionID else { return false }
        open(dimension, then: perform)
        return true
    }

    /// Shows a location in its dimension document, keeping that document's current zoom.
    func focus(on location: PlayerInfo.Location, blockPosition: Bool = false) {
        focus(on: Coordinates(CGPoint(x: location.x, y: location.z), y: location.y),
              in: location.dimension, blockPosition: blockPosition)
    }

    func goToSpawn() {
        guard let source, let spawn = source.world.level.spawnPosition,
              let dimension = source.world.level.spawnDimension else { return }
        focus(on: Coordinates(CGPoint(x: spawn.x, y: spawn.z), y: spawn.y),
              in: dimension, blockPosition: true)
    }

    /// A map center has no saved height; it follows the same jump without inventing one.
    func focus(on coordinates: Coordinates, in dimension: String, blockPosition: Bool = false) {
        guard let source, canFocus(coordinates, in: dimension) else { return }
        if route(to: dimension, perform: { $0.routing.focus(on: coordinates, in: dimension, blockPosition: blockPosition) }) { return }
        source.navigation.focus(on: coordinates.point, blockPosition: blockPosition)
    }

    func canFocus(_ coordinates: Coordinates, in dimension: String?) -> Bool {
        guard let source, !source.isClosed, let dimension else { return false }
        return coordinates.isMappable && source.dimensions.contains { $0.id == dimension }
    }

    /// Whether choosing a player's row can center the map on their current position.
    func canFocus(_ player: PlayerInfo) -> Bool {
        guard let position = PlayerPresentation.position(of: player) else { return false }
        return canFocus(Coordinates(CGPoint(x: position.x, y: position.z), y: position.y), in: position.dimension)
    }

    private func open(_ dimension: String, then perform: ((WorldSession) -> Void)?) {
        guard let source, !source.isClosed, let openDocument,
              let url = source.resources.documentURL(for: dimension) else { return }
        let resources = source.resources
        let request = perform.flatMap { resources.whenShowing(dimension, perform: $0) }
        Task { [weak self] in
            do {
                try await openDocument(url)
            } catch {
                if let request { resources.cancelPending(request, in: dimension) }
                guard !(error is CancellationError), (error as? CocoaError)?.code != .userCancelled,
                      self?.source?.isClosed == false else { return }
                self?.openFailure = error.localizedDescription
            }
        }
    }
}
