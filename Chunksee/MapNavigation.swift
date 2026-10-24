import CoreGraphics
import ChunkseeKit
import Observation

/// Local jumps and history for one document. MapModel remains the viewport and depth owner.
@Observable
final class MapNavigation {
    private let map: MapModel?
    private var history = MapNavigationHistory()

    init(map: MapModel?) { self.map = map }

    var canGoBack: Bool { map?.isClosed == false && history.canGoBack }
    var canGoForward: Bool { map?.isClosed == false && history.canGoForward }

    var canFitWorld: Bool {
        guard let map, !map.isClosed, let shown = map.shownSize else { return false }
        return MapViewport.fitting(map.availableRegions, in: shown.size) != nil
    }

    /// Every location jump keeps this dimension's zoom; zoom controls and Fit World are explicit.
    func focus(on point: CGPoint) {
        guard MapCoordinates(point: point) != nil else { return }
        navigate { map in
            map.viewport.center = point
        }
    }

    /// Coordinate entry and saved-place jumps keep zoom and center on the containing block.
    func goToCoordinates(_ point: CGPoint, height: Int? = nil) {
        guard let coordinates = MapCoordinates(point: point) else { return }
        navigate { map in
            map.viewport.center = coordinates.center
            if let height { map.setHeight(height) }
        }
    }

    func fitWorld() {
        guard let map, let shown = map.shownSize,
              let fitted = MapViewport.fitting(map.availableRegions, in: shown.size) else { return }
        navigate { $0.viewport = fitted }
    }

    func goBack() {
        guard let map, !map.isClosed, let destination = history.goBack(from: map.viewport) else { return }
        map.viewport = destination
    }

    func goForward() {
        guard let map, !map.isClosed, let destination = history.goForward(from: map.viewport) else { return }
        map.viewport = destination
    }

    /// A native reread/move copies navigation into a new map; the old document may already be closed.
    func restore(from previous: MapNavigation) {
        guard let map, !map.isClosed, let oldMap = previous.map,
              map.dimension.id == oldMap.dimension.id else { return }
        history = previous.history
        map.viewport = oldMap.viewport
        map.setDepth(oldMap.depth)
        map.setStyle(oldMap.style)
        map.setBiomeBlending(oldMap.blendsBiomeColors)
        map.setBlockFilter(oldMap.blockFilter)
    }

    private func navigate(_ change: (MapModel) -> Void) {
        guard let map, !map.isClosed else { return }
        let previous = map.viewport
        change(map)
        if previous != map.viewport { history.record(previous) }
    }
}

/// Past viewports of one dimension document; changing dimensions opens another document.
nonisolated private struct MapNavigationHistory {
    private var previous: [MapViewport] = []
    private var following: [MapViewport] = []

    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !following.isEmpty }

    mutating func record(_ location: MapViewport) {
        if previous.last != location { previous.append(location) }
        following.removeAll()
    }

    mutating func goBack(from current: MapViewport) -> MapViewport? {
        guard let destination = previous.popLast() else { return nil }
        following.append(current)
        return destination
    }

    mutating func goForward(from current: MapViewport) -> MapViewport? {
        guard let destination = following.popLast() else { return nil }
        previous.append(current)
        return destination
    }
}
