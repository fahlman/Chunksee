import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// A dimension's annotation actions and ruler. The session owns sheets; SavedPlaces owns saved data.
@Observable
final class MapAnnotations {
    @ObservationIgnored private weak var source: WorldSession?
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
        source.presentSheet(.savedPlace(SavedPlaceDraft(name: "", dimension: dimension, position: coordinates.position)))
    }

    func edit(_ place: SavedPlace) {
        guard let source, !source.isClosed else { return }
        source.presentSheet(.savedPlace(SavedPlaceDraft(existingID: place.id, name: place.name,
                                                      dimension: place.dimension, position: place.position)))
    }

    func canPlanPortal(at point: CGPoint? = nil, in dimension: String? = nil) -> Bool {
        guard let source, !source.isClosed, let point = point ?? source.map?.viewport.center,
              MapCoordinates(point: point) != nil, let dimension = dimension ?? source.selectedDimensionID,
              source.dimensions.contains(where: { $0.id == dimension }) else { return false }
        return NetherPortal.targetDimension(from: dimension) != nil
    }

    func planPortal(at point: CGPoint? = nil, in dimension: String? = nil, y: Double? = nil) {
        guard canPlanPortal(at: point, in: dimension), let source,
              let point = point ?? source.map?.viewport.center, let column = MapCoordinates(point: point),
              let dimension = dimension ?? source.selectedDimensionID else { return }
        let height = y.flatMap(Coordinates.block)
        let plan = PortalPlanDraft(dimension: dimension, column: column, height: height)
        source.presentSheet(.portal(plan))
        if height == nil, let map = source.map, map.dimension.id == dimension {
            map.readTopBlock(at: column.position) { [weak self, weak plan] block in
                guard let self, let plan, self.source?.isClosed == false, self.source?.sheet?.portalDraft === plan else { return }
                plan.fillHeight(block?.y)
            }
        }
    }

    func canVisit(_ place: SavedPlace) -> Bool {
        source?.routing.canFocus(Coordinates(place.position), in: place.dimension) ?? false
    }

    func commit(_ draft: SavedPlaceDraft, name: String) -> Bool {
        guard let source, !source.isClosed, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let id = draft.existingID {
            source.savedPlaces.rename(id, to: name)
        } else {
            guard let place = source.savedPlaces.add(name: name, dimension: draft.dimension, at: draft.position) else { return false }
            source.resources.showSavedPlaces(in: place.dimension)
        }
        return true
    }

    func visit(_ place: SavedPlace) {
        guard let source, !source.isClosed, canVisit(place) else { return }
        if source.routing.route(to: place.dimension, perform: { $0.annotations.visit(place) }) { return }
        source.resources.showSavedPlaces(in: place.dimension)
        source.navigation.goToCoordinates(place.position)
    }

    func setRulerEnabled(_ enabled: Bool) {
        ruler.isEnabled = enabled
        if enabled, let selection = source?.selection, selection.inspector == .selection { selection.inspector = nil }
    }

    func canMeasure(in dimension: String) -> Bool {
        guard let source, !source.isClosed, source.selectedDimensionID == dimension else { return false }
        return source.map?.dimension.id == dimension
    }

    func beginMeasurement(at point: CGPoint, in dimension: String) {
        guard canMeasure(in: dimension) else { return }
        setRulerEnabled(true)
        ruler.clear()
        ruler.mark(point)
    }

}
