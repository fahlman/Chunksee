import SwiftUI

/// Viewport-local player and saved-place markers shared by drawing, picking and accessibility.
struct MapScene {
    enum Layer: Int {
        case player, savedPlace
    }

    struct Item {
        let id: String
        let name: String
        let layer: Layer
        let target: MapTarget
        /// Saved coordinates remain separate from the block-centered drawing anchor.
        let position: CGPoint
        let y: Double?
        let anchor: CGPoint
        let point: CGPoint
        let style: MarkerStyle
        let labelPriority: MarkerLabelLayout.Priority

        var frame: CGRect { style.geometry.frame(at: point) }

        var accessibleLocation: AccessibleMapLocation {
            AccessibleMapLocation(id: id, name: name, position: position, y: y,
                                  target: target, anchor: anchor, frame: frame)
        }

        func draw(in context: GraphicsContext, scale: CGFloat,
                  symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) -> MarkerLabel? {
            style.drawBody(at: point, in: context, symbol: symbol)
            return style.label(name, id: id, priority: labelPriority, at: point, scale: scale, in: context)
        }
    }

    let items: [Item]
    private let accessibilityBounds: CGRect

    init(content: MapContent, viewport: MapViewport, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        accessibilityBounds = bounds.insetBy(dx: -20, dy: -20)
        var items: [Item] = []
        // Player captions can enter the view before their badge does. Keep that wider drawing
        // margin without exposing additional offscreen accessibility children.
        let playerBounds = bounds.insetBy(dx: -60, dy: -30)
        for marker in content.players {
            let point = viewport.viewPoint(for: marker.anchor, in: size)
            guard playerBounds.contains(point) else { continue }
            let selected = marker.playerID == content.selectedPlayerID
            items.append(Item(id: "player-" + marker.id, name: marker.label, layer: .player,
                target: .row(.player(marker.playerID)), position: marker.position, y: marker.y,
                anchor: marker.anchor, point: point,
                style: .player(marker.kind, outdated: marker.isOutdated, selected: marker.kind == .player && selected),
                labelPriority: selected || content.selectedItem == .player(marker.playerID) ? .selected : .player))
        }
        for place in content.savedPlaces {
            let point = viewport.viewPoint(for: place.mapPosition, in: size)
            guard accessibilityBounds.contains(point) else { continue }
            items.append(Item(id: "saved-" + place.id.uuidString, name: place.name, layer: .savedPlace,
                target: .row(.savedPlace(place.id)), position: place.position, y: nil,
                anchor: place.mapPosition, point: point, style: .savedPlace,
                labelPriority: content.selectedItem == .savedPlace(place.id) ? .selected : .other))
        }
        self.items = items
    }

    var accessibleLocations: [AccessibleMapLocation] {
        items.filter { accessibilityBounds.contains($0.point) }.map(\.accessibleLocation)
    }

    /// Higher layers win; within a layer choose the closest badge, then the later drawn item.
    func hit(at point: CGPoint) -> MapHit? {
        var best: Item?
        var distance = CGFloat.infinity
        for item in items {
            let candidate = hypot(item.point.x - point.x, item.point.y - point.y)
            guard candidate <= item.style.geometry.hitRadius else { continue }
            if let best {
                if item.layer.rawValue < best.layer.rawValue { continue }
                if item.layer == best.layer, candidate > distance { continue }
            }
            best = item
            distance = candidate
        }
        return best.map { MapHit(target: $0.target, position: $0.position, y: $0.y) }
    }
}

extension MapContent {
    func scene(viewport: MapViewport, size: CGSize) -> MapScene {
        MapScene(content: self, viewport: viewport, size: size)
    }
}
