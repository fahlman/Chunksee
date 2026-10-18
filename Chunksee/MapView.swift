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
    var placePoints = PointMarkers<PlaceMarker>()
    var creaturePoints = PointMarkers<CreatureMarker>()
    /// Nil means all groups (standalone map snapshots); a document supplies its own visibility.
    var shownPlaceGroups: Set<PlaceGroup>?
    var shownCreatureGroups: Set<CreatureGroup>?
    var places: [PlaceMarker] {
        get { placePoints.all.filter { shownPlaceGroups?.contains($0.group) ?? true } }
        set { placePoints = PointMarkers(newValue) }
    }
    var creatures: [CreatureMarker] {
        get { creaturePoints.all.filter { shownCreatureGroups?.contains($0.group) ?? true } }
        set { creaturePoints = PointMarkers(newValue) }
    }
    /// Search results, drawn as pins.
    var hits: [SearchHit] = []
    var selectedHitID: SearchHit.ID?
    /// Players' positions, last deaths and respawn points.
    var players: [MapMarker] = []
    /// The player whose details the inspector shows; their position is drawn highlighted.
    var selectedPlayerID: UUID?
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

    func nearbyPlaces(viewport: MapViewport, size: CGSize, bounds: CGRect? = nil) -> [PlaceMarker] {
        guard shownPlaceGroups?.isEmpty != true else { return [] }
        return placePoints.candidates(in: bounds ?? CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20),
                                      viewport: viewport, size: size)
            .filter { (shownPlaceGroups?.contains($0.group) ?? true) && (viewport.scale >= 0.125 || $0.group == .portal) }
    }

    func nearbyCreatures(viewport: MapViewport, size: CGSize, bounds: CGRect? = nil) -> [CreatureMarker] {
        guard shownCreatureGroups?.isEmpty != true else { return [] }
        return creaturePoints.candidates(in: bounds ?? CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20),
                                         viewport: viewport, size: size)
            .filter { (shownCreatureGroups?.contains($0.group) ?? true) && (viewport.scale >= 0.25 || selection == .creature($0)) }
    }

    /// The individual locations represented by Canvas. Names and actions remain available
    /// to VoiceOver even though Canvas itself creates no accessibility children.
    func accessibleLocations(viewport: MapViewport, size: CGSize) -> [AccessibleMapLocation] {
        var locations: [AccessibleMapLocation] = []
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
        // Ids and names are built only for locations in view: a world can have thousands of
        // spawners and other places off screen.
        func add(_ id: @autoclosure () -> String, _ name: @autoclosure () -> String, _ position: CGPoint,
                 anchor: CGPoint? = nil,
                 target: @autoclosure () -> MapTarget? = nil) {
            guard bounds.contains(viewport.viewPoint(for: anchor ?? position, in: size)) else { return }
            locations.append(.init(id: id(), name: name(), position: position, target: target(), anchor: anchor))
        }
        for marker in structures { add("structure-" + marker.id, marker.name, marker.position, target: .row(.structure(marker.id))) }
        for marker in nearbyPlaces(viewport: viewport, size: size) {
            add("place-" + marker.id, marker.name, marker.position, target: .row(.place(marker.id)))
        }
        for marker in nearbyCreatures(viewport: viewport, size: size) {
            add("creature-" + marker.id, marker.name, marker.position, target: .row(.creature(marker.id)))
        }
        for area in biomeAreas { add("biome-" + area.id, area.group.name, area.position, target: .row(.biome(area.id))) }
        for hit in hits {
            if let position = hit.position { add("search-" + hit.id, hit.title + ", " + hit.detail, position, target: .searchHit(hit.id)) }
        }
        for marker in players { add("player-" + marker.id, marker.label, marker.position, anchor: marker.anchor, target: .row(.player(marker.playerID))) }
        for place in savedPlaces { add("saved-" + place.id.uuidString, place.name, place.position, target: .row(.savedPlace(place.id))) }
        return locations
    }

    /// Hit tests only drawn markers. Match drawing order for overlapping badges, preserving a
    /// portal's priority over a creature standing in it. Names are not prepared for hit testing.
    func target(at point: CGPoint, viewport: MapViewport, size: CGSize) -> MapTarget? {
        hit(at: point, viewport: viewport, size: size)?.target
    }

    func hit(at point: CGPoint, viewport: MapViewport, size: CGSize) -> MapHit? {
        func nearest<Item>(_ items: some Sequence<Item>, within reach: (Item) -> CGFloat,
                           position: (Item) -> CGPoint) -> Item? {
            var best: Item?
            var distance = CGFloat.infinity
            for item in items {
                let location = viewport.viewPoint(for: position(item), in: size)
                let candidate = hypot(location.x - point.x, location.y - point.y)
                if candidate <= reach(item), candidate <= distance { best = item; distance = candidate }
            }
            return best
        }
        if let place = nearest(savedPlaces, within: { _ in MarkerGeometry.savedPlace.hitRadius }, position: \.position) {
            return MapHit(target: .row(.savedPlace(place.id)), position: place.position)
        }
        if let player = nearest(players, within: { MarkerGeometry.player($0.kind).hitRadius }, position: \.anchor) {
            return MapHit(target: .row(.player(player.playerID)), position: player.position, y: player.y)
        }
        if let hit = nearest(hits.lazy.filter { $0.position != nil },
                             within: { MarkerGeometry.search(selected: $0.id == selectedHitID).hitRadius }, position: { $0.position! }) {
            return MapHit(target: .searchHit(hit.id), position: hit.position!, y: hit.y.map(Double.init))
        }
        let reach = max(MarkerGeometry.place(isPortal: true).hitRadius, MarkerGeometry.creature(selected: true).hitRadius)
        let bounds = CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)
        let places = nearbyPlaces(viewport: viewport, size: size, bounds: bounds)
        if let portal = nearest(places.lazy.filter { $0.portal != nil }, within: { _ in MarkerGeometry.place(isPortal: true).hitRadius }, position: \.position) {
            return MapHit(target: .row(.place(portal.id)), position: portal.position, y: Double(portal.y))
        }
        if let creature = nearest(nearbyCreatures(viewport: viewport, size: size, bounds: bounds),
                                  within: { MarkerGeometry.creature(selected: selection == .creature($0)).hitRadius }, position: \.position) {
            return MapHit(target: .row(.creature(creature.id)), position: creature.position, y: creature.creature.y)
        }
        if let place = nearest(places, within: { MarkerGeometry.place(isPortal: $0.group == .portal).hitRadius }, position: \.position) {
            return MapHit(target: .row(.place(place.id)), position: place.position, y: Double(place.y))
        }
        if let structure = nearest(structures, within: { _ in MarkerGeometry.structure.hitRadius }, position: \.position) {
            return MapHit(target: .row(.structure(structure.id)), position: structure.position, y: structure.y.map(Double.init))
        }
        // Biomes draw areas, not badges at their representative position. They remain available
        // through the sidebar and accessibility locations without an invisible pointer target.
        return nil
    }
}

/// One drawn marker's action and coordinate snapshot, shared by selection and copying.
struct MapHit {
    var target: MapTarget
    var position: CGPoint
    var y: Double?
}

struct AccessibleMapLocation: Identifiable {
    var id: String
    var name: String
    var position: CGPoint
    var target: MapTarget?
    var anchor: CGPoint? = nil
}

/// The pannable, zoomable top-down map of one dimension.
struct MapView: View {
    let session: WorldSession
    @Bindable var map: MapModel
    var content = MapContent()
    /// Link status per portal, for warning badges; `nil` while unknown.
    var portalStatus: (NetherPortal) -> PortalLinkStatus? = { _ in nil }
    /// Called with the clicked marker's identity, or `nil` for empty map.
    var onSelect: (MapTarget?) -> Void = { _ in }

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
                onSelect(content.target(at: value.location, viewport: map.viewport, size: size))
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
            case .active(let point):
                hoverPoint = point
                loadHoveredBlock()
            case .ended:
                hoverPoint = nil
                map.endHover()
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
        .onChange(of: map.viewport, initial: true) {
            map.requestTiles(visibleIn: size, displayScale: displayScale)
            loadHoveredBlock()
        }
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
                    isFocused = true
                    session.goToCoordinates(location.anchor ?? location.position)
                    onSelect(location.target)
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
        let hit = content.hit(at: point, viewport: map.viewport, size: size)
        let copyPosition = hit?.position ?? position, copyY = hit?.y, map = map
        return [
            MapContextAction(title: String(localized: "Copy Coordinates")) { MapClipboard.copy(copyPosition, y: copyY, on: map) },
            MapContextAction(title: String(localized: "Save Place…")) { session.savePlace(at: position, in: dimension) },
            MapContextAction(title: String(localized: "Measure Distance from Here")) { session.beginMeasurement(at: position, in: dimension) },
        ]
    }

    /// A structure's icon at its center; zoomed in, also its outline (from 1/4×), its name (from
    /// 1/2×) and, for strongholds, the End portal room.
    private static func draw(_ structure: StructureMarker, viewport: MapViewport, in context: GraphicsContext,
                             size: CGSize, bounds: CGRect, symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) {
        let topLeft = viewport.viewPoint(for: structure.bounds.origin, in: size)
        let outline = CGRect(origin: topLeft, size: CGSize(width: structure.bounds.width * viewport.scale,
                                                           height: structure.bounds.height * viewport.scale))
        guard outline.insetBy(dx: -40, dy: -40).intersects(bounds) else { return }
        let style = MarkerStyle.structure(structure.group), color = style.fill
        if viewport.scale >= 0.25 {
            let path = Path(outline)
            context.fill(path, with: .color(color.opacity(0.12)))
            context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        let center = CGPoint(x: outline.midX, y: outline.midY)
        style.drawBody(at: center, in: context, symbol: symbol)

        if viewport.scale >= 0.25, let room = structure.portalRoom {
            let p = viewport.viewPoint(for: room, in: size)
            let ring = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            context.fill(ring, with: .color(.black.opacity(0.7)))
            var sparkle = context.resolve(Image(systemName: "sparkles"))
            sparkle.shading = .color(.mint)
            context.draw(sparkle, in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
        style.drawName(structure.name, at: center, scale: viewport.scale, in: context)
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
        var symbols: [MarkerStyle.Symbol: GraphicsContext.ResolvedImage] = [:]
        func symbol(_ key: MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage {
            if let image = symbols[key] { return image }
            var resolving = context
            if let opacity = key.opacity { resolving.opacity = opacity }
            var image = resolving.resolve(Image(systemName: key.name))
            image.shading = .color(key.color)
            symbols[key] = image
            return image
        }
        for structure in content.structures {
            Self.draw(structure, viewport: map.viewport, in: context, size: size, bounds: bounds, symbol: symbol)
        }
        // Individual places are tiny; zoomed far out, only portals stay (they're few and useful).
        for place in content.nearbyPlaces(viewport: map.viewport, size: size) {
            let point = map.viewport.viewPoint(for: place.position, in: size)
            Self.draw(place, at: point, scale: map.viewport.scale, in: context, bounds: bounds, symbol: symbol)
            if let portal = place.portal {
                Self.drawPortalState(at: point, selected: content.selection == .portal(portal), status: portalStatus(portal), in: context)
            }
        }
        // Many creatures stand in villages and pens; individually they show from 1/4 zoom.
        for creature in content.nearbyCreatures(viewport: map.viewport, size: size) {
            let selected = content.selection == .creature(creature)
            Self.draw(creature, selected: selected, at: map.viewport.viewPoint(for: creature.position, in: size),
                      scale: map.viewport.scale, in: context, bounds: bounds, symbol: symbol)
        }
        for hit in content.hits {
            guard let position = hit.position else { continue }
            Self.drawPin(at: map.viewport.viewPoint(for: position, in: size), selected: hit.id == content.selectedHitID,
                         in: context, bounds: bounds, symbol: symbol)
        }
        for marker in content.players {
            Self.draw(marker, selected: marker.kind == .player && marker.playerID == content.selectedPlayerID,
                      at: map.viewport.viewPoint(for: marker.anchor, in: size),
                      in: context, bounds: bounds, symbol: symbol)
        }
        for place in content.savedPlaces {
            Self.drawBadge(style: .savedPlace, name: place.name, scale: map.viewport.scale,
                           at: map.viewport.viewPoint(for: place.position, in: size), in: context, bounds: bounds, symbol: symbol)
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

    /// A yellow search-result pin; the selected one has the larger shared geometry.
    private static func drawPin(at point: CGPoint, selected: Bool, in context: GraphicsContext, bounds: CGRect,
                                symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) {
        guard bounds.insetBy(dx: -20, dy: -20).contains(point) else { return }
        MarkerStyle.search(selected: selected).drawBody(at: point, in: context, symbol: symbol)
    }

    private static func draw(_ place: PlaceMarker, at point: CGPoint, scale: CGFloat, in context: GraphicsContext, bounds: CGRect,
                             symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) {
        drawBadge(style: .place(place.group, claimed: place.isClaimed), name: place.name, scale: scale,
                  at: point, in: context, bounds: bounds, symbol: symbol)
    }

    private static func draw(_ creature: CreatureMarker, selected: Bool, at point: CGPoint, scale: CGFloat, in context: GraphicsContext,
                             bounds: CGRect, symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) {
        drawBadge(style: .creature(creature.group, selected: selected), name: creature.name, scale: scale,
                  at: point, in: context, bounds: bounds, symbol: symbol)
    }

    private static func drawBadge(style: @autoclosure () -> MarkerStyle, name: @autoclosure () -> String, scale: CGFloat,
                                  at point: CGPoint, in context: GraphicsContext, bounds: CGRect,
                                  symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) {
        guard bounds.insetBy(dx: -20, dy: -20).contains(point) else { return }
        let style = style()
        style.drawBody(at: point, in: context, symbol: symbol)
        style.drawName(name(), at: point, scale: scale, in: context)
    }

    private static func draw(_ marker: MapMarker, selected: Bool, at point: CGPoint, in context: GraphicsContext, bounds: CGRect,
                             symbol: (MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage) {
        guard bounds.insetBy(dx: -60, dy: -30).contains(point) else { return }
        let style = MarkerStyle.player(marker.kind, outdated: marker.isOutdated, selected: selected)
        style.drawBody(at: point, in: context, symbol: symbol)
        style.drawName(marker.label, at: point, scale: 1, in: context)
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
                let block = Self.namesBlocks(at: map.viewport.scale) ? map.topBlock(at: hoverBlock) : nil
                Text(Self.readout(at: hoverBlock, block: block, biomes: content.biomeDescription(at: hoverBlock)))
                    .monospacedDigit()
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

    /// Blocks are named from 100% zoom, where a block is at least a point across.
    static func namesBlocks(at scale: CGFloat) -> Bool { scale >= 1 }

    /// "X 3307  Y 64  Z 938 · Sand · Desert": X, Y and Z together as Minecraft shows them, then the
    /// block and biome (Ryan, 2026-10-13). Without a block, only X and Z are known.
    static func readout(at point: CGPoint, block: RegionTileRenderer.TopBlock?, biomes: String?) -> String {
        let coordinates = block.map { Coordinates.text(point, y: $0.y) } ?? Coordinates.text(point)
        return ([coordinates] + [block.map(describe), biomes].compactMap { $0 }).joined(separator: " · ")
    }

    /// "Sand", or for water "Water, 5 deep". Water is counted only to the renderer's limit, so
    /// deeper water reads "at least 32 deep" rather than a wrong exact depth.
    static func describe(_ block: RegionTileRenderer.TopBlock) -> String {
        let name = ReadableName.from(block.id)
        guard block.waterDepth > 0 else { return name }
        return block.waterDepth >= RegionTileRenderer.maximumWaterDepth
            ? String(localized: "\(name), at least \(block.waterDepth) deep")
            : String(localized: "\(name), \(block.waterDepth) deep")
    }

    /// Reads the block under the pointer, also when the map moves beneath a still pointer.
    private func loadHoveredBlock() {
        guard let hoverPoint, Self.namesBlocks(at: map.viewport.scale) else { return }
        map.loadTopBlocks(at: map.viewport.blockPoint(at: hoverPoint, in: size))
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
