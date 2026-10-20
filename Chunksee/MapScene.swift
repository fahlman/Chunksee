import ChunkseeKit
import SwiftUI

/// Markers and areas shared by drawing, picking and accessibility. Region buckets limit point
/// candidates; areas can remain visible while their representative point is outside the viewport.
struct MapScene {
    // Picking priority is independent of array/drawing order: a portal wins over a creature
    // standing in it, even though creature bodies are drawn later.
    enum Layer: Int {
        case structure, place, creature, portal, search, player, savedPlace
    }

    /// Keep names lazy: most places/creatures have no visible caption at overview zoom, and
    /// picking never needs their formatted names or prefixed accessibility IDs.
    enum Label {
        case structure(StructureMarker), place(PlaceMarker), creature(CreatureMarker)
        case pin(id: String, name: String, detail: String? = nil)

        var id: String {
            switch self {
            case .structure(let marker): "structure-" + marker.id
            case .place(let marker): "place-" + marker.id
            case .creature(let marker): "creature-" + marker.id
            case .pin(let id, _, _): id
            }
        }

        var name: String {
            switch self {
            case .structure(let marker): marker.name
            case .place(let marker): marker.name
            case .creature(let marker): marker.name
            case .pin(_, let name, _): name
            }
        }

        var accessibleName: String {
            if case .pin(_, let name, let detail?) = self { return name + ", " + detail }
            return name
        }
    }

    struct Item {
        let label: Label
        let layer: Layer
        let target: MapTarget
        /// Saved coordinates remain separate from the block-centered drawing anchor.
        let position: CGPoint
        let y: Double?
        let anchor: CGPoint
        let point: CGPoint
        let scale: CGFloat
        let style: MarkerStyle
        let labelPriority: MarkerLabelLayout.Priority
        var isDimmed = false

        var id: String { label.id }
        var frame: CGRect { MarkerGeometry.frame(at: point, scale: scale) }

        var accessibleLocation: AccessibleMapLocation {
            AccessibleMapLocation(id: id, name: label.accessibleName, position: position, y: y,
                                  target: target, anchor: anchor, frame: frame)
        }

        func draw(in context: GraphicsContext,
                  portalStatus: (NetherPortal) -> PortalLinkStatus?,
                  symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) -> MarkerLabel? {
            style.drawBody(at: point, scale: scale, selected: labelPriority == .selected, dimmed: isDimmed,
                           in: context, symbol: symbol)
            if case .place(let marker) = label, let portal = marker.portal {
                drawPortalState(status: portalStatus(portal), in: context)
            }
            return style.label(label.name, id: id, priority: labelPriority, at: point, scale: scale, dimmed: isDimmed, in: context)
        }

        /// Decorations don't enlarge the shared body or its pointer/accessibility target.
        private func drawPortalState(status: PortalLinkStatus?, in context: GraphicsContext) {
            let radius = MarkerGeometry.radius(at: scale)
            guard let status, status != .linked else { return }
            let badge = CGRect(x: point.x + radius - 4, y: point.y - radius - 4, width: 10, height: 10)
            context.fill(Path(ellipseIn: badge), with: .color(status == .noPartner ? .red : .orange))
            var mark = context.resolve(Text("!").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white))
            mark.shading = .color(.white)
            context.draw(mark, at: CGPoint(x: badge.midX, y: badge.midY))
        }
    }

    /// Area decorations belong only to structures; point items need no storage for them.
    struct StructureItem {
        let item: Item
        let outline: CGRect
        let portalRoom: CGPoint?

        func draw(in context: GraphicsContext,
                  symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) -> MarkerLabel? {
            let scale = item.scale
            if scale >= 0.25 {
                let path = Path(outline)
                context.fill(path, with: .color(item.style.fill.opacity(0.12)))
                context.stroke(path, with: .color(item.style.fill.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            let label = item.draw(in: context, portalStatus: { _ in nil }, symbol: symbol)
            if scale >= 0.25, let point = portalRoom {
                let ring = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                context.fill(ring, with: .color(.black.opacity(0.7)))
                var sparkle = context.resolve(Image(systemName: "sparkles"))
                sparkle.shading = .color(.mint)
                context.draw(sparkle, in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            }
            return label
        }
    }

    struct BiomeItem {
        let area: BiomeArea
        let point: CGPoint
        let frame: CGRect

        var accessibleLocation: AccessibleMapLocation {
            AccessibleMapLocation(id: "biome-" + area.id, name: area.group.name,
                position: area.position, y: nil, target: .row(.biome(area.id)), frame: frame)
        }

        func draw(in context: GraphicsContext, transform: CGAffineTransform) {
            // Transform the potentially large paths only for drawing, never for picking or AX.
            let color = Color(BiomeColors.color(for: area.group.id))
            context.fill(area.chunks.applying(transform), with: .color(color.opacity(0.15)))
            context.stroke(area.outline.applying(transform), with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }
    }

    let biomeAreas: [BiomeItem]
    let structures: [StructureItem]
    let items: [Item]
    private let bounds: CGRect
    private let accessibilityBounds: CGRect
    private let firstPinIndex: Int
    private let biomeTransform: CGAffineTransform

    init(content: MapContent, viewport: MapViewport, size: CGSize, pickingAt pointer: CGPoint? = nil) {
        let bounds = CGRect(origin: .zero, size: size)
        self.bounds = bounds
        let accessibilityBounds = bounds.insetBy(dx: -20, dy: -20)
        self.accessibilityBounds = accessibilityBounds
        let transform = viewport.transform(in: size)
        biomeTransform = transform
        // Areas have no pointer badge. Keep candidates whose shape or AX point is in view;
        // a long area's representative point can be offscreen while its outline is visible.
        biomeAreas = pointer == nil ? content.biomeAreas.compactMap { area in
            let frame = area.bounds.applying(transform)
            let point = viewport.viewPoint(for: area.position, in: size)
            guard frame.intersects(bounds) || accessibilityBounds.contains(point) else { return nil }
            return BiomeItem(area: area, point: point, frame: frame)
        } : []
        structures = content.structures.compactMap { marker in
            let outline = marker.bounds.applying(transform)
            let point = CGPoint(x: outline.midX, y: outline.midY)
            if let pointer {
                let reach = MarkerGeometry.hitRadius(at: viewport.scale)
                guard abs(point.x - pointer.x) <= reach, abs(point.y - pointer.y) <= reach else { return nil }
            } else {
                guard outline.insetBy(dx: -40, dy: -40).intersects(bounds) else { return nil }
            }
            return StructureItem(item: Item(label: .structure(marker), layer: .structure,
                target: .row(.structure(marker.id)), position: marker.position, y: marker.yCoordinate,
                anchor: marker.position, point: point, scale: viewport.scale, style: .structure(marker.group),
                labelPriority: content.selectedItem == .structure(marker.id) ? .selected : .other),
                outline: outline, portalRoom: marker.portalRoom.map { viewport.viewPoint(for: $0, in: size) })
        }
        let candidateBounds = pointer.map { point in
            let reach = MarkerGeometry.hitRadius(at: viewport.scale)
            return CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)
        }
        var items: [Item] = []
        for marker in content.nearbyPlaces(viewport: viewport, size: size, bounds: candidateBounds) {
            let point = viewport.viewPoint(for: marker.position, in: size)
            // Picking applies each body's exact radius below, including the boundary. Drawing
            // clips the broad bucket candidates before preparing styles or names.
            guard accessibilityBounds.contains(point) else { continue }
            let selected = content.selectedItem == .place(marker.id)
                || marker.portal.map { content.selection == .portal($0) } == true
            items.append(Item(label: .place(marker), layer: marker.portal == nil ? .place : .portal,
                target: .row(.place(marker.id)), position: marker.position, y: marker.yCoordinate,
                anchor: marker.position, point: point, scale: viewport.scale, style: .place(marker.group),
                labelPriority: selected ? .selected : .other,
                isDimmed: marker.isClaimed))
        }
        for marker in content.nearbyCreatures(viewport: viewport, size: size, bounds: candidateBounds) {
            let point = viewport.viewPoint(for: marker.position, in: size)
            guard accessibilityBounds.contains(point) else { continue }
            let selected = content.selection == .creature(marker)
            let priority: MarkerLabelLayout.Priority = selected || content.selectedItem == .creature(marker.id) ? .selected
                : marker.group == .pet && marker.creature.customName != nil ? .namedPet : .other
            items.append(Item(label: .creature(marker), layer: .creature,
                target: .row(.creature(marker.id)), position: marker.position, y: marker.yCoordinate,
                anchor: marker.position, point: point, scale: viewport.scale, style: .creature(marker.group),
                labelPriority: priority))
        }
        firstPinIndex = items.count
        for hit in content.hits {
            guard let position = hit.position else { continue }
            let point = viewport.viewPoint(for: position, in: size)
            guard accessibilityBounds.contains(point) else { continue }
            let selected = hit.id == content.selectedHitID
            items.append(Item(label: .pin(id: "search-" + hit.id, name: hit.title, detail: hit.detail), layer: .search,
                target: .searchHit(hit.id), position: position, y: hit.y.map(Double.init),
                anchor: position, point: point, scale: viewport.scale, style: .search,
                labelPriority: selected ? .selected : .other))
        }
        // Player captions can enter the view before their badge does. Keep that wider drawing
        // margin without exposing additional offscreen accessibility children.
        let playerBounds = bounds.insetBy(dx: -60, dy: -30)
        for marker in content.players {
            let point = viewport.viewPoint(for: marker.anchor, in: size)
            guard playerBounds.contains(point) else { continue }
            let selected = marker.playerID == content.selectedPlayerID
            items.append(Item(label: .pin(id: "player-" + marker.id, name: marker.label), layer: .player,
                target: .row(.player(marker.playerID)), position: marker.position, y: marker.y,
                anchor: marker.anchor, point: point, scale: viewport.scale,
                style: .player(marker.kind),
                labelPriority: selected || content.selectedItem == .player(marker.playerID) ? .selected : .player,
                isDimmed: marker.isOutdated))
        }
        for place in content.savedPlaces {
            let point = viewport.viewPoint(for: place.mapPosition, in: size)
            guard accessibilityBounds.contains(point) else { continue }
            items.append(Item(label: .pin(id: "saved-" + place.id.uuidString, name: place.name), layer: .savedPlace,
                target: .row(.savedPlace(place.id)), position: place.position, y: nil,
                anchor: place.mapPosition, point: point, scale: viewport.scale, style: .savedPlace,
                labelPriority: content.selectedItem == .savedPlace(place.id) ? .selected : .other))
        }
        self.items = items
    }

    func drawBiomeAreas(in context: GraphicsContext) {
        for area in biomeAreas where area.frame.intersects(bounds) {
            area.draw(in: context, transform: biomeTransform)
        }
    }

    var accessibleLocations: [AccessibleMapLocation] {
        // Preserve traversal order: structures, Places, creatures, biome areas, then pin layers.
        var locations = structures.filter { accessibilityBounds.contains($0.item.point) }.map(\.item.accessibleLocation)
        locations += items[..<firstPinIndex].map(\.accessibleLocation)
        locations += biomeAreas.filter { accessibilityBounds.contains($0.point) }.map(\.accessibleLocation)
        locations += items[firstPinIndex...].filter { accessibilityBounds.contains($0.point) }.map(\.accessibleLocation)
        return locations
    }

    /// Higher layers win; within a layer choose the closest badge, then the later drawn item.
    func hit(at point: CGPoint) -> MapHit? {
        var best: Item?
        var distance = CGFloat.infinity
        func consider(_ item: Item) {
            let candidate = hypot(item.point.x - point.x, item.point.y - point.y)
            guard candidate <= MarkerGeometry.hitRadius(at: item.scale) else { return }
            if let best {
                if item.layer.rawValue < best.layer.rawValue { return }
                if item.layer == best.layer, candidate > distance { return }
            }
            best = item
            distance = candidate
        }
        for structure in structures { consider(structure.item) }
        for item in items { consider(item) }
        return best.map { MapHit(target: $0.target, position: $0.position, y: $0.y) }
    }
}

extension MapContent {
    func scene(viewport: MapViewport, size: CGSize, pickingAt point: CGPoint? = nil) -> MapScene {
        MapScene(content: self, viewport: viewport, size: size, pickingAt: point)
    }
}
