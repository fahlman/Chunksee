import CoreGraphics
import ChunkseeKit
import Observation

/// A dimension's saved-place drafts and ruler. SavedPlaces remains the world's shared store.
@Observable
final class MapAnnotations {
    @ObservationIgnored private weak var source: WorldSession?
    var draft: SavedPlaceDraft?
    var ruler = MapRuler()

    init(source: WorldSession) {
        self.source = source
    }

    var listedPlaces: [SavedPlace] {
        guard let source else { return [] }
        return source.savedPlaces.all.filter { source.presentation.lists($0.dimension) }
    }

    func savePlace(at point: CGPoint? = nil, in dimension: String? = nil) {
        guard let source, !source.isClosed, let point = point ?? source.map?.viewport.center,
              let coordinates = MapCoordinates(point: point), let dimension = dimension ?? source.selectedDimensionID else { return }
        draft = SavedPlaceDraft(name: "", dimension: dimension, position: coordinates.position)
    }

    func edit(_ place: SavedPlace) {
        guard let source, !source.isClosed else { return }
        draft = SavedPlaceDraft(existingID: place.id, name: place.name, dimension: place.dimension, position: place.position)
    }

    func canVisit(_ place: SavedPlace) -> Bool {
        source?.dimensions.contains { $0.id == place.dimension } ?? false
    }

    func visit(_ place: SavedPlace) {
        guard let source, canVisit(place) else { return }
        if source.routing.route(to: place.dimension, perform: { $0.annotations.visit(place) }) { return }
        source.navigation.goToCoordinates(place.position)
    }

    func setRulerEnabled(_ enabled: Bool) {
        ruler.isEnabled = enabled
        if enabled, let selection = source?.selection, selection.mapSelection != nil { selection.inspector = nil }
    }

    func beginMeasurement(at point: CGPoint, in dimension: String) {
        guard let source, !source.isClosed, source.selectedDimensionID == dimension else { return }
        setRulerEnabled(true)
        ruler.clear()
        ruler.mark(point)
    }

    /// Native rereads keep the measurement, but never revive a draft sheet.
    func restore(from previous: MapAnnotations) {
        ruler = previous.ruler
    }
}
