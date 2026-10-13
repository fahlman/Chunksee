import ChunkseeKit
import SwiftUI

/// Everything drawn over one dimension's terrain, bottom to top in this order.
struct MapContent {
    /// Time-spent heat images by region.
    var heatMap: [RegionCoordinate: CGImage] = [:]
    /// A map made in the game, drawn where it belongs at the given opacity.
    var inGameMap: (map: MapItem, image: CGImage, opacity: Double)?
    var biomeAreas: [BiomeArea] = []
    /// Each chunk's surface biome and any cave biomes under it, for the hover readout.
    var biomes: [ChunkCoordinate: String] = [:]
    var caveBiomes: [ChunkCoordinate: [String]] = [:]
    /// The world border, when it's closer than Minecraft's default.
    var border: WorldBorder?
    /// Whether chunk and region lines are drawn.
    var showsGrid = false
    var structures: [StructureMarker] = []
    var places: [PlaceMarker] = []
    var creatures: [CreatureMarker] = []
    /// Search results, drawn as pins.
    var hits: [SearchHit] = []
    var selectedHitID: SearchHit.ID?
    /// Players' positions, last deaths and respawn points.
    var players: [MapMarker] = []
    var savedPlaces: [SavedPlace] = []
    var ruler = MapRuler()
    /// The selected portal or creature, drawn highlighted.
    var selection: MapSelection?

    /// The surface biome of the chunk under a block, once the dimension has been read.
    func biome(at block: CGPoint) -> String? {
        biomes[Self.chunk(at: block)]
    }

    /// The hover readout's biomes: the surface biome, then any cave biomes below it, as in
    /// "Plains · Deep Dark below".
    func biomeDescription(at block: CGPoint) -> String? {
        let surface = biome(at: block).map(ReadableName.from)
        let caves = (caveBiomes[Self.chunk(at: block)] ?? []).map(ReadableName.from)
        let below = caves.isEmpty ? nil : String(localized: "\(caves.formatted(.list(type: .and))) below")
        let parts = [surface, below].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func chunk(at block: CGPoint) -> ChunkCoordinate {
        ChunkCoordinate(x: Int(block.x.rounded(.down)) >> 4, z: Int(block.y.rounded(.down)) >> 4)
    }

    /// The individual locations represented by Canvas. Names and actions remain available
    /// to VoiceOver even though Canvas itself creates no accessibility children.
    func accessibleLocations(viewport: MapViewport, size: CGSize) -> [AccessibleMapLocation] {
        var locations: [AccessibleMapLocation] = []
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
        // Ids and names are built only for locations in view: a world can have thousands of
        // spawners and other places off screen.
        func add(_ id: @autoclosure () -> String, _ name: @autoclosure () -> String, _ position: CGPoint,
                 selection: @autoclosure () -> MapSelection? = nil) {
            guard bounds.contains(viewport.viewPoint(for: position, in: size)) else { return }
            locations.append(.init(id: id(), name: name(), position: position, selection: selection()))
        }
        for marker in structures { add("structure-" + marker.id, marker.name, marker.position) }
        for marker in places where viewport.scale >= 0.125 || marker.group == .portal {
            add("place-" + marker.id, marker.name, marker.position, selection: marker.portal.map(MapSelection.portal))
        }
        for marker in creatures where viewport.scale >= 0.25 || selection == .creature(marker) {
            add("creature-" + marker.id, marker.name, marker.position, selection: .creature(marker))
        }
        for area in biomeAreas { add("biome-" + area.id, area.group.name, area.position) }
        for hit in hits {
            if let position = hit.position { add("search-" + hit.id, hit.title + ", " + hit.detail, position) }
        }
        for marker in players { add("player-" + marker.id, marker.label, marker.position) }
        for place in savedPlaces { add("saved-" + place.id.uuidString, place.name, place.position) }
        return locations
    }
}

struct AccessibleMapLocation: Identifiable {
    var id: String
    var name: String
    var position: CGPoint
    var selection: MapSelection?
}

/// The pannable, zoomable top-down map of one dimension.
struct MapView: View {
    let session: WorldSession
    @Bindable var map: MapModel
    var content = MapContent()
    /// Link status per portal, for warning badges; `nil` while unknown.
    var portalStatus: (NetherPortal) -> PortalLinkStatus? = { _ in nil }
    /// Called when a portal or creature is clicked, or with `nil` when the map is clicked elsewhere.
    var onSelect: (MapSelection?) -> Void = { _ in }

    @State private var size: CGSize = .zero
    @State private var dragStart: MapViewport?
    @State private var magnifyStart: MapViewport?
    /// The pointer position in the view; the block under it is worked out from the current viewport,
    /// so the readout stays right while the map moves under a still pointer.
    @State private var hoverPoint: CGPoint?
    @FocusState private var isFocused: Bool
    @Environment(\.displayScale) private var displayScale

    private var zoomPercentage: String {
        ZoomPercentage.text(map.viewport.scale)
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            Self.drawMap(map, content: content, portalStatus: portalStatus, displayScale: displayScale, in: context, size: size)
        }
        .background(.background.secondary)
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            isFocused = true   // clicking the map gives it the arrow keys again
            if session.ruler.isEnabled {
                session.ruler.mark(map.viewport.blockPoint(at: value.location, in: size))
            } else {
                onSelect(selection(at: value.location))
            }
        })
        .scrollWheelInput(contextActions: contextActions) { action in
            switch action {
            case .pan(let delta): map.viewport.pan(by: delta)
            case .zoom(let factor, let anchor): map.viewport.zoom(by: factor, anchor: anchor, in: size)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverPoint = point
            case .ended: hoverPoint = nil
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.escape) {
            guard session.ruler.isEnabled else { return .ignored }
            session.ruler.escape()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let step = size.width / 4
            switch press.key {
            case .leftArrow: map.viewport.pan(by: CGSize(width: step, height: 0))
            case .rightArrow: map.viewport.pan(by: CGSize(width: -step, height: 0))
            case .upArrow: map.viewport.pan(by: CGSize(width: 0, height: step))
            default: map.viewport.pan(by: CGSize(width: 0, height: -step))
            }
            return .handled
        }
        .onAppear { isFocused = true }
        .onChange(of: map.viewport, initial: true) { map.requestTiles(visibleIn: size, displayScale: displayScale) }
        .onChange(of: ObjectIdentifier(map)) {
            dragStart = nil
            magnifyStart = nil
            map.requestTiles(visibleIn: size, displayScale: displayScale)
        }
        .onChange(of: size) { map.requestTiles(visibleIn: size, displayScale: displayScale) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Map of \(map.dimension.displayName)"))
        .accessibilityIdentifier("world-map")
        .accessibilityValue(Text("Centered on X \(Int(map.viewport.center.x)), Z \(Int(map.viewport.center.y)); zoom \(zoomPercentage)"))
        .accessibilityHint(Text("Use the arrow keys or scroll to move the map, and Command-scroll to zoom."))
        .accessibilityChildren {
            ForEach(content.accessibleLocations(viewport: map.viewport, size: size)) { location in
                Button(location.name) {
                    session.goToCoordinates(location.position)
                    onSelect(location.selection)
                }
                .accessibilityValue(Text("X \(Int(location.position.x)), Z \(Int(location.position.y))"))
                .accessibilityHint(Text("Center the map on this location"))
            }
        }
        .accessibilityAction(named: Text("Zoom In")) { map.zoom(by: 2) }
        .accessibilityAction(named: Text("Zoom Out")) { map.zoom(by: 0.5) }
        .accessibilityAction(named: Text("Move North")) { map.viewport.pan(by: CGSize(width: 0, height: size.height / 4)) }
        .accessibilityAction(named: Text("Move South")) { map.viewport.pan(by: CGSize(width: 0, height: -size.height / 4)) }
        .accessibilityAction(named: Text("Move West")) { map.viewport.pan(by: CGSize(width: size.width / 4, height: 0)) }
        .accessibilityAction(named: Text("Move East")) { map.viewport.pan(by: CGSize(width: -size.width / 4, height: 0)) }
        .overlay(alignment: .bottom) { statusBar }
        .toolbar { MapToolbar(session: session, map: map) }
    }

    private func contextActions(at point: CGPoint) -> [MapContextAction] {
        guard let coordinates = MapCoordinates(point: map.viewport.blockPoint(at: point, in: size)) else { return [] }
        let position = coordinates.position, dimension = map.dimension.id
        return [
            MapContextAction(title: String(localized: "Copy Coordinates")) { MapClipboard.copy(position) },
            MapContextAction(title: String(localized: "Save Place…")) { session.savePlace(at: position, in: dimension) },
            MapContextAction(title: String(localized: "Measure Distance from Here")) { session.beginMeasurement(at: position, in: dimension) },
        ]
    }

    /// A structure's icon at its center; zoomed in, also its outline (from 1/4×), its name (from
    /// 1/2×) and, for strongholds, the End portal room.
    private static func draw(_ structure: StructureMarker, viewport: MapViewport, in context: GraphicsContext,
                             size: CGSize, bounds: CGRect) {
        let topLeft = viewport.viewPoint(for: structure.bounds.origin, in: size)
        let outline = CGRect(origin: topLeft, size: CGSize(width: structure.bounds.width * viewport.scale,
                                                           height: structure.bounds.height * viewport.scale))
        guard outline.insetBy(dx: -40, dy: -40).intersects(bounds) else { return }
        let color = Color(hex: structure.group.color)
        if viewport.scale >= 0.25 {
            let path = Path(outline)
            context.fill(path, with: .color(color.opacity(0.12)))
            context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        let center = CGPoint(x: outline.midX, y: outline.midY)
        let radius: CGFloat = 9
        let disc = Path(roundedRect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                        cornerRadius: 4)
        context.fill(disc, with: .color(color))
        context.stroke(disc, with: .color(.white.opacity(0.9)), lineWidth: 1)
        var symbol = context.resolve(Image(systemName: structure.group.symbol))
        symbol.shading = .color(.white)
        context.draw(symbol, in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))

        if viewport.scale >= 0.25, let room = structure.portalRoom {
            let p = viewport.viewPoint(for: room, in: size)
            let ring = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            context.fill(ring, with: .color(.black.opacity(0.7)))
            var sparkle = context.resolve(Image(systemName: "sparkles"))
            sparkle.shading = .color(.mint)
            context.draw(sparkle, in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
        guard viewport.scale >= 0.5 else { return }
        let text = context.resolve(Text(structure.name).font(.caption2.weight(.semibold)).foregroundStyle(.white))
        let textSize = text.measure(in: CGSize(width: 240, height: 40))
        let label = CGRect(x: center.x - textSize.width / 2 - 5, y: center.y + radius + 2,
                           width: textSize.width + 10, height: textSize.height + 2)
        context.fill(Path(roundedRect: label, cornerRadius: label.height / 2), with: .color(color.opacity(0.85)))
        context.draw(text, at: CGPoint(x: label.midX, y: label.midY))
    }

    /// A ring around the selected portal, and a warning badge on portals that don't link both ways.
    /// Draws the map: terrain tiles, then every overlay, bottom to top. The map view and image
    /// export both draw through this, so an exported image matches the screen.
    static func drawMap(_ map: MapModel, content: MapContent, portalStatus: (NetherPortal) -> PortalLinkStatus?,
                        displayScale: CGFloat, in context: GraphicsContext, size: CGSize) {
        // Crisp block edges when zoomed in; smoothing when zoomed out avoids shimmering.
        let interpolation: Image.Interpolation = map.viewport.scale >= 1 ? .none : .medium
        let fullResolution = map.needsFullResolution(displayScale: displayScale)
        let visible = map.viewport.visibleRegions(in: size, among: map.availableRegions)
        for region in visible {
            guard let image = map.image(for: region, fullResolution: fullResolution) else { continue }
            // Overlap neighbors by half a point so smoothed edges don't let the background show
            // through as seams between tiles.
            let rect = map.viewport.viewRect(for: region, in: size).insetBy(dx: -0.5, dy: -0.5)
            context.draw(Image(decorative: image, scale: 1).interpolation(interpolation), in: rect)
        }
        let bounds = CGRect(origin: .zero, size: size)
        if !content.heatMap.isEmpty {
            for region in visible {
                guard let image = content.heatMap[region] else { continue }
                context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: map.viewport.viewRect(for: region, in: size))
            }
        }
        if let (item, image, opacity) = content.inGameMap {
            let topLeft = map.viewport.viewPoint(for: CGPoint(x: item.minX, y: item.minZ), in: size)
            let side = CGFloat(item.sideInBlocks) * map.viewport.scale
            let rect = CGRect(origin: topLeft, size: CGSize(width: side, height: side))
            var layer = context
            layer.opacity = opacity
            layer.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
            context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        // Biome areas: a light fill and an outline along chunk edges, in the biome's color.
        let toView = CGAffineTransform(a: map.viewport.scale, b: 0, c: 0, d: map.viewport.scale,
                                       tx: size.width / 2 - map.viewport.center.x * map.viewport.scale,
                                       ty: size.height / 2 - map.viewport.center.y * map.viewport.scale)
        for area in content.biomeAreas where area.bounds.applying(toView).intersects(bounds) {
            let color = Color(BiomeColors.color(for: area.group.id))
            context.fill(area.chunks.applying(toView), with: .color(color.opacity(0.15)))
            context.stroke(area.outline.applying(toView), with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }
        if content.showsGrid {
            Self.drawGrid(MapGrid(viewport: map.viewport, size: size), in: context, size: size)
        }
        if let border = content.border {
            let half = border.size / 2
            let topLeft = map.viewport.viewPoint(for: CGPoint(x: border.centerX - half, y: border.centerZ - half), in: size)
            let edge = Path(CGRect(origin: topLeft, size: CGSize(width: border.size * map.viewport.scale, height: border.size * map.viewport.scale)))
            context.stroke(edge, with: .color(.red.opacity(0.85)), lineWidth: 2)
        }
        for structure in content.structures {
            Self.draw(structure, viewport: map.viewport, in: context, size: size, bounds: bounds)
        }
        // Each badge's symbol is resolved once per draw rather than once per marker: thousands of
        // spawners can be in view at once.
        var symbols: [String: GraphicsContext.ResolvedImage] = [:]
        func symbol(_ name: String) -> GraphicsContext.ResolvedImage {
            if let image = symbols[name] { return image }
            var image = context.resolve(Image(systemName: name))
            image.shading = .color(.white)
            symbols[name] = image
            return image
        }
        // Individual places are tiny; zoomed far out, only portals stay (they're few and useful).
        for place in content.places where map.viewport.scale >= 0.125 || place.group == .portal {
            let point = map.viewport.viewPoint(for: place.position, in: size)
            Self.draw(place, at: point, scale: map.viewport.scale, in: context, bounds: bounds, symbol: symbol)
            if let portal = place.portal {
                Self.drawPortalState(at: point, selected: content.selection == .portal(portal), status: portalStatus(portal), in: context)
            }
        }
        // Many creatures stand in villages and pens; individually they show from 1/4 zoom.
        for creature in content.creatures {
            let selected = content.selection == .creature(creature)
            guard map.viewport.scale >= 0.25 || selected else { continue }
            Self.draw(creature, selected: selected, at: map.viewport.viewPoint(for: creature.position, in: size),
                      scale: map.viewport.scale, in: context, bounds: bounds, symbol: symbol)
        }
        for hit in content.hits {
            guard let position = hit.position else { continue }
            Self.drawPin(at: map.viewport.viewPoint(for: position, in: size), selected: hit.id == content.selectedHitID,
                         in: context, bounds: bounds)
        }
        for marker in content.players {
            Self.draw(marker, at: map.viewport.viewPoint(for: CGPoint(x: marker.position.x + 0.5, y: marker.position.y + 0.5), in: size),
                      in: context, bounds: bounds)
        }
        for place in content.savedPlaces {
            Self.drawBadge(symbol: symbol("mappin"), color: .accentColor, radius: 8, name: place.name,
                           showsName: map.viewport.scale >= 2, opacity: 1, selected: false,
                           at: map.viewport.viewPoint(for: place.position, in: size), in: context, bounds: bounds)
        }
        content.ruler.draw(in: context, viewport: map.viewport, size: size)
    }

    /// Block lines stay subtle; chunk and region boundaries stand out. Label only the larger
    /// boundaries so closely spaced block lines don't crowd the coordinates.
    private static func drawGrid(_ grid: MapGrid, in context: GraphicsContext, size: CGSize) {
        func stroke(_ path: Path, line: MapGrid.Line) {
            let width: CGFloat = line.isRegionEdge ? 1.5 : line.isChunkEdge ? 1 : 0.5
            let opacity = line.isRegionEdge ? 0.7 : line.isChunkEdge ? 0.4 : 0.2
            // A dark edge keeps the lines visible over snow as well as darker terrain.
            context.stroke(path, with: .color(.black.opacity(opacity)), lineWidth: width + 0.5)
            context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: width)
        }
        for line in grid.vertical {
            let path = Path { $0.move(to: CGPoint(x: line.position, y: 0)); $0.addLine(to: CGPoint(x: line.position, y: size.height)) }
            stroke(path, line: line)
        }
        for line in grid.horizontal {
            let path = Path { $0.move(to: CGPoint(x: 0, y: line.position)); $0.addLine(to: CGPoint(x: size.width, y: line.position)) }
            stroke(path, line: line)
        }
        func label(_ value: Int, at point: CGPoint) {
            let text = context.resolve(Text(value, format: .number.grouping(.never)).font(.caption2.monospacedDigit()).foregroundStyle(.white))
            let textSize = text.measure(in: CGSize(width: 80, height: 20))
            let box = CGRect(x: point.x + 2, y: point.y + 2, width: textSize.width + 6, height: textSize.height + 2)
            context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.55)))
            context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
        }
        for line in grid.vertical where grid.isLabeled(line) { label(line.block, at: CGPoint(x: line.position, y: 0)) }
        for line in grid.horizontal where grid.isLabeled(line) { label(line.block, at: CGPoint(x: 0, y: line.position)) }
    }

    private static func drawPortalState(at point: CGPoint, selected: Bool, status: PortalLinkStatus?, in context: GraphicsContext) {
        if selected {
            let ring = Path(ellipseIn: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
            context.stroke(ring, with: .color(.white), lineWidth: 3)
            context.stroke(ring, with: .color(.accentColor), lineWidth: 1.5)
        }
        guard let status, status != .linked else { return }
        let badge = CGRect(x: point.x + 4, y: point.y - 12, width: 10, height: 10)
        context.fill(Path(ellipseIn: badge), with: .color(status == .noPartner ? .red : .orange))
        var mark = context.resolve(Text("!").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white))
        mark.shading = .color(.white)
        context.draw(mark, at: CGPoint(x: badge.midX, y: badge.midY))
    }

    /// A yellow search-result pin; the selected one is larger with a ring.
    private static func drawPin(at point: CGPoint, selected: Bool, in context: GraphicsContext, bounds: CGRect) {
        guard bounds.insetBy(dx: -20, dy: -20).contains(point) else { return }
        let radius: CGFloat = selected ? 10 : 7
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(.yellow))
        context.stroke(circle, with: .color(.black.opacity(0.6)), lineWidth: selected ? 2 : 1)
        var symbol = context.resolve(Image(systemName: "magnifyingglass"))
        symbol.shading = .color(.black)
        let side = radius * 1.1
        context.draw(symbol, in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
    }

    /// What a click selects: a portal within 14 points, or else a drawn creature within 12. A
    /// portal wins over a creature standing in it.
    private func selection(at point: CGPoint) -> MapSelection? {
        func nearest<Item>(_ items: [(item: Item, position: CGPoint)], within reach: CGFloat) -> Item? {
            items.map { item, position in
                let p = map.viewport.viewPoint(for: position, in: size)
                return (item, hypot(p.x - point.x, p.y - point.y))
            }.filter { $0.1 <= reach }.min { $0.1 < $1.1 }?.0
        }
        if let portal = nearest(content.places.compactMap { place in place.portal.map { ($0, place.position) } }, within: 14) {
            return .portal(portal)
        }
        guard map.viewport.scale >= 0.25 else { return nil }
        return nearest(content.creatures.map { ($0, $0.position) }, within: 12).map(MapSelection.creature)
    }

    /// A small round marker; its name appears from 2× zoom. Claimed beds and workstations are dimmed.
    private static func draw(_ place: PlaceMarker, at point: CGPoint, scale: CGFloat, in context: GraphicsContext, bounds: CGRect,
                             symbol: (String) -> GraphicsContext.ResolvedImage) {
        drawBadge(symbol: symbol(place.group.symbol), color: Color(hex: place.group.color), radius: place.group == .portal ? 8 : 6, name: place.name,
                  showsName: scale >= 2, opacity: place.isClaimed ? 0.65 : 1, selected: false, at: point, in: context, bounds: bounds)
    }

    /// Creatures look like places; a selected one is larger and always named.
    private static func draw(_ creature: CreatureMarker, selected: Bool, at point: CGPoint, scale: CGFloat, in context: GraphicsContext,
                             bounds: CGRect, symbol: (String) -> GraphicsContext.ResolvedImage) {
        drawBadge(symbol: symbol(creature.group.symbol), color: Color(hex: creature.group.color), radius: selected ? 9 : 6, name: creature.name,
                  showsName: selected || scale >= 2, opacity: 1, selected: selected, at: point, in: context, bounds: bounds)
    }

    /// The symbol, color and name are evaluated only for a badge in view, and the name only when it's shown.
    private static func drawBadge(symbol: @autoclosure () -> GraphicsContext.ResolvedImage, color: @autoclosure () -> Color,
                                  radius: CGFloat, name: @autoclosure () -> String, showsName: Bool, opacity: Double,
                                  selected: Bool, at point: CGPoint, in context: GraphicsContext, bounds: CGRect) {
        guard bounds.insetBy(dx: -20, dy: -20).contains(point) else { return }
        let color = color()
        var context = context
        context.opacity = opacity
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(color))
        context.stroke(circle, with: .color(selected ? .accentColor : .white.opacity(0.9)), lineWidth: selected ? 2 : 1)
        let side = radius * 1.2
        context.draw(symbol(), in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        guard showsName else { return }
        let text = context.resolve(Text(name()).font(.caption2.weight(.medium)).foregroundStyle(.white))
        let size = text.measure(in: CGSize(width: 200, height: 30))
        let label = CGRect(x: point.x - size.width / 2 - 4, y: point.y + radius + 2, width: size.width + 8, height: size.height + 2)
        context.fill(Path(roundedRect: label, cornerRadius: label.height / 2), with: .color(color.opacity(0.85)))
        context.draw(text, at: CGPoint(x: label.midX, y: label.midY))
    }

    /// Markers keep a constant size at every zoom; players also get a name label.
    private static func draw(_ marker: MapMarker, at point: CGPoint, in context: GraphicsContext, bounds: CGRect) {
        guard bounds.insetBy(dx: -60, dy: -30).contains(point) else { return }
        var context = context
        context.opacity = marker.isOutdated ? 0.55 : 1
        let radius: CGFloat = marker.kind == .player ? 11 : 9
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        let (symbolName, color): (String, Color) = switch marker.kind {
        case .player: ("person.fill", .blue)
        case .death: ("xmark", .red)
        case .respawn: ("bed.double.fill", .purple)
        }
        context.fill(circle, with: .color(color))
        context.stroke(circle, with: .color(.white), lineWidth: 1.5)
        var symbol = context.resolve(Image(systemName: symbolName))
        symbol.shading = .color(.white)
        let side = radius * 1.15
        context.draw(symbol, in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        guard marker.kind == .player else { return }
        let text = context.resolve(Text(marker.label).font(.caption.weight(.semibold)).foregroundStyle(.white))
        let textSize = text.measure(in: CGSize(width: 240, height: 40))
        let label = CGRect(x: point.x - textSize.width / 2 - 6, y: point.y + radius + 3,
                           width: textSize.width + 12, height: textSize.height + 4)
        context.fill(Path(roundedRect: label, cornerRadius: label.height / 2), with: .color(.black.opacity(0.6)))
        context.draw(text, at: CGPoint(x: label.midX, y: label.midY))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if session.ruler.isEnabled {
                Image(systemName: "ruler")
                if let distance = session.ruler.distance {
                    Text("\(distance.formatted(.number.precision(.fractionLength(0...2)))) blocks")
                        .monospacedDigit()
                } else {
                    Text(session.ruler.start == nil ? "Click the first point" : "Click the second point")
                }
                if session.ruler.start != nil {
                    Button("Clear") { session.ruler.clear() }
                        .help("Clear this measurement; Escape also clears it")
                }
            }
            if let hoverPoint {
                let hoverBlock = map.viewport.blockPoint(at: hoverPoint, in: size)
                Text(Coordinates.text(hoverBlock))
                    .monospacedDigit()
                if let biomes = content.biomeDescription(at: hoverBlock) {
                    Text(biomes)
                }
            }
            if map.isLoading {
                ProgressView().controlSize(.small)
                Text("Drawing map…")
            } else if map.availableRegions.isEmpty {
                Text("No terrain has been saved in this dimension.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
        .opacity(hoverPoint == nil && !map.isLoading && !map.availableRegions.isEmpty && !session.ruler.isEnabled ? 0 : 1)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                isFocused = true
                let start = dragStart ?? map.viewport
                dragStart = start
                var viewport = start
                viewport.pan(by: value.translation)
                map.viewport = viewport
            }
            .onEnded { _ in dragStart = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnifyStart ?? map.viewport
                magnifyStart = start
                var viewport = start
                viewport.zoom(by: value.magnification, anchor: value.startLocation, in: size)
                map.viewport = viewport
            }
            .onEnded { _ in magnifyStart = nil }
    }

}
