import ChunkseeKit
import SwiftUI

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
    var y: Double?
    var target: MapTarget?
    var anchor: CGPoint? = nil
    /// The badge body (or biome area), in map-view coordinates.
    var frame: CGRect
}

/// The pannable, zoomable top-down map of one dimension.
struct MapView: View {
    let session: WorldSession
    @Bindable var map: MapModel
    var content = MapContent()
    /// Link status per portal, for warning badges; `nil` while unknown.
    var portalStatus: (NetherPortal) -> PortalLinkStatus? = { _ in nil }
    /// Called with the clicked marker’s identity and saved height, or nil for empty map.
    var onSelect: (MapTarget?, Double?) -> Void = { _, _ in }

    @State private var size: CGSize = .zero
    @State private var dragStart: MapViewport?
    @State private var magnifyStart: MapViewport?
    @State private var showsHeightPopover = false
    /// The pointer position in the view; the block under it is worked out from the current viewport,
    /// so the readout stays right while the map moves under a still pointer.
    @State private var hoverPoint: CGPoint?
    @FocusState private var isFocused: Bool
    @Environment(\.displayScale) private var displayScale

    private var zoomPercentage: String {
        ZoomPercentage.text(map.viewport.scale)
    }

    private var accessibilityReadout: String {
        let position = String(localized: "Centered on \(Coordinates.text(map.viewport.center)); zoom \(zoomPercentage); \(map.depth.accessibilityDescription)")
        guard let seed = content.slimeSeed,
              let slime = SlimeChunks.description(at: map.viewport.center, seed: seed) else { return position }
        return [position, slime].joined(separator: "; ")
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
            if session.annotations.ruler.isEnabled {
                session.annotations.ruler.mark(map.viewport.blockPoint(at: value.location, in: size))
            } else {
                let hit = content.hit(at: value.location, viewport: map.viewport, size: size)
                onSelect(hit?.target, hit?.y)
            }
        })
        .scrollWheelInput(contextContent: { point in
            MapContextMenuContent(at: point, session: session, map: map, content: content, size: size)
        }) { action in
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
            guard session.annotations.ruler.isEnabled else { return .ignored }
            session.annotations.ruler.escape()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            switch press.key {
            case .leftArrow: map.viewport.pan(.west, in: size)
            case .rightArrow: map.viewport.pan(.east, in: size)
            case .upArrow: map.viewport.pan(.north, in: size)
            default: map.viewport.pan(.south, in: size)
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
        .accessibilityLabel(Text("Map of \(session.presentation.dimensionName(map.dimension.id))"))
        .accessibilityIdentifier("world-map")
        .accessibilityValue(Text(accessibilityReadout))
        .accessibilityHint(Text("Use the arrow keys or scroll to move the map, and Command-scroll to zoom."))
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(content.accessibleLocations(viewport: map.viewport, size: size)) { location in
                    Button {
                        isFocused = true
                        session.navigation.focus(on: location.anchor ?? location.position, keepingZoom: true)
                        onSelect(location.target, location.y)
                    } label: {
                        Color.clear.frame(width: location.frame.width, height: location.frame.height)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(location.name)
                    .accessibilityValue(Text(Coordinates.text(location.position, y: location.y)))
                    .accessibilityHint(Text("Center the map on this location"))
                    .accessibilityAction(named: Text("Copy Coordinates")) {
                        MapClipboard.copy(location.position, y: location.y, on: map)
                    }
                    .position(x: location.frame.midX, y: location.frame.midY)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityAction(named: Text("Zoom In")) { map.zoom(by: 2) }
        .accessibilityAction(named: Text("Zoom Out")) { map.zoom(by: 0.5) }
        .accessibilityAction(named: Text("Move North")) { map.viewport.pan(.north, in: size) }
        .accessibilityAction(named: Text("Move South")) { map.viewport.pan(.south, in: size) }
        .accessibilityAction(named: Text("Move West")) { map.viewport.pan(.west, in: size) }
        .accessibilityAction(named: Text("Move East")) { map.viewport.pan(.east, in: size) }
        .overlay(alignment: .bottom) { statusBar }
        .toolbar { MapToolbar(session: session, map: map, showsHeightPopover: $showsHeightPopover) }
        .focusedSceneValue(\.mapHeightPopover, $showsHeightPopover)
    }

    /// Draws the map: terrain tiles, then every overlay, bottom to top. The map view and image
    /// export both draw through this, so an exported image matches the screen.
    static func drawMap(_ map: MapModel, content: MapContent, portalStatus: (NetherPortal) -> PortalLinkStatus?,
                        displayScale: CGFloat, in context: GraphicsContext, size: CGSize) {
        // Crisp block edges when zoomed in; smoothing when zoomed out avoids shimmering.
        let interpolation: Image.Interpolation = map.viewport.scale >= 1 ? .none : .medium
        let fullResolution = map.needsFullResolution(displayScale: displayScale)
        let visible = map.viewport.visibleRegions(in: size, among: map.availableRegions)
        for region in visible {
            guard let image = map.image(for: region, fullResolution: fullResolution),
                  let rect = map.viewport.viewRect(for: region, in: size) else { continue }
            // Overlap neighbors by half a point so smoothed edges don't let the background show
            // through as seams between tiles.
            context.draw(Image(decorative: image, scale: 1).interpolation(interpolation), in: rect.insetBy(dx: -0.5, dy: -0.5))
        }
        let bounds = CGRect(origin: .zero, size: size)
        if !content.heatMap.isEmpty {
            for region in visible {
                guard let image = content.heatMap[region], let rect = map.viewport.viewRect(for: region, in: size) else { continue }
                context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
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
        let scene = content.scene(viewport: map.viewport, size: size)
        scene.drawBiomeAreas(in: context)
        for region in visible {
            if let image = content.slimeChunks[region], let rect = map.viewport.viewRect(for: region, in: size) {
                context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
            }
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
        var labels: [MarkerLabel] = []
        func add(_ label: MarkerLabel?) {
            if let label, label.placement.frame.intersects(bounds) { labels.append(label) }
        }
        func symbol(_ key: MarkerStyle.Symbol) -> GraphicsContext.ResolvedImage {
            if let image = symbols[key] { return image }
            var image = context.resolve(Image(systemName: key.name))
            image.shading = .color(key.color)
            symbols[key] = image
            return image
        }
        for structure in scene.structures {
            add(structure.draw(in: context, symbol: symbol))
        }
        for item in scene.items {
            add(item.draw(in: context, portalStatus: portalStatus, symbol: symbol))
        }
        MarkerLabel.draw(labels, in: context)
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

    private var statusBar: some View {
        HStack(spacing: 12) {
            if session.annotations.ruler.isEnabled {
                Image(systemName: "ruler")
                if let distance = session.annotations.ruler.distance {
                    Text(distance, format: CountedText.blocks)
                        .monospacedDigit()
                } else {
                    Text(session.annotations.ruler.start == nil ? "Click the first point" : "Click the second point")
                }
                if session.annotations.ruler.start != nil {
                    Button("Clear") { session.annotations.ruler.clear() }
                        .help("Clear this measurement; Escape also clears it")
                }
            }
            if let hoverPoint {
                let hoverBlock = map.viewport.blockPoint(at: hoverPoint, in: size)
                let block = Self.namesBlocks(at: map.viewport.scale) ? map.topBlock(at: hoverBlock) : nil
                Text(Self.readout(at: hoverBlock, block: block, biomes: content.biomeDescription(at: hoverBlock)))
                    .monospacedDigit()
                if let seed = content.slimeSeed, let description = SlimeChunks.description(at: hoverBlock, seed: seed) {
                    Text(description)
                }
            }
            if session.slimeChunks.isLoading {
                ProgressView().controlSize(.small)
                Text("Drawing slime chunks…")
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
        .opacity(hoverPoint == nil && !map.isLoading && !map.availableRegions.isEmpty && !session.annotations.ruler.isEnabled && !session.slimeChunks.isLoading ? 0 : 1)
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
