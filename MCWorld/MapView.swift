import MCWorldKit
import SwiftUI

/// The pannable, zoomable top-down map of one dimension.
struct MapView: View {
    @Bindable var map: MapModel
    /// Structures to draw, above the tiles and below player markers.
    var structures: [StructureMarker] = []
    /// Points of interest to draw, above structures and below player markers.
    var places: [PlaceMarker] = []
    /// The portal whose details are showing, drawn with a highlight ring.
    var selectedPortal: NetherPortal?
    /// Link status per portal, for warning badges; `nil` while unknown.
    var portalStatus: (NetherPortal) -> PortalLinkStatus? = { _ in nil }
    /// Item search results in this dimension, drawn as pins above everything but players.
    var hits: [SearchHit] = []
    var selectedHitID: SearchHit.ID?
    /// The dimension's world border, drawn when it's closer than Minecraft's default.
    var border: WorldBorder?
    /// Time-spent heat images by region, drawn over the terrain.
    var heatMap: [RegionCoordinate: CGImage] = [:]
    /// A map made in the game, drawn over the terrain where it belongs.
    var inGameMap: (map: MapItem, image: CGImage)?
    var inGameMapOpacity = 0.85
    /// Called when a portal is clicked, or with `nil` when the map is clicked elsewhere.
    var onSelectPortal: (NetherPortal?) -> Void = { _ in }
    /// Points of interest for this dimension, drawn above the tiles.
    var markers: [MapMarker] = []

    @State private var size: CGSize = .zero
    @State private var dragStart: MapViewport?
    @State private var magnifyStart: MapViewport?
    /// The pointer position in the view; the block under it is worked out from the current viewport,
    /// so the readout stays right while the map moves under a still pointer.
    @State private var hoverPoint: CGPoint?
    @FocusState private var isFocused: Bool
    @Environment(\.displayScale) private var displayScale

    /// Zoom buttons and shortcuts step by a factor of two.
    private static let zoomStep: CGFloat = 2

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            // Crisp block edges when zoomed in; smoothing when zoomed out avoids shimmering.
            let interpolation: Image.Interpolation = map.viewport.scale >= 1 ? .none : .medium
            let fullResolution = map.needsFullResolution(displayScale: displayScale)
            for region in map.viewport.visibleRegionRange(in: size).regions {
                guard let image = map.image(for: region, fullResolution: fullResolution) else { continue }
                // Overlap neighbors by half a point so smoothed edges don't let the background show
                // through as seams between tiles.
                let rect = map.viewport.viewRect(for: region, in: size).insetBy(dx: -0.5, dy: -0.5)
                context.draw(Image(decorative: image, scale: 1).interpolation(interpolation), in: rect)
            }
            let bounds = CGRect(origin: .zero, size: size)
            if !heatMap.isEmpty {
                for region in map.viewport.visibleRegionRange(in: size).regions {
                    guard let image = heatMap[region] else { continue }
                    context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: map.viewport.viewRect(for: region, in: size))
                }
            }
            if let (item, image) = inGameMap {
                let topLeft = map.viewport.viewPoint(for: CGPoint(x: item.minX, y: item.minZ), in: size)
                let side = CGFloat(item.sideInBlocks) * map.viewport.scale
                let rect = CGRect(origin: topLeft, size: CGSize(width: side, height: side))
                var layer = context
                layer.opacity = inGameMapOpacity
                layer.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
                context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
            if let border {
                let half = border.size / 2
                let topLeft = map.viewport.viewPoint(for: CGPoint(x: border.centerX - half, y: border.centerZ - half), in: size)
                let edge = Path(CGRect(origin: topLeft, size: CGSize(width: border.size * map.viewport.scale, height: border.size * map.viewport.scale)))
                context.stroke(edge, with: .color(.red.opacity(0.85)), lineWidth: 2)
            }
            for structure in structures {
                Self.draw(structure, viewport: map.viewport, in: context, size: size, bounds: bounds)
            }
            // Individual places are tiny; zoomed far out, only portals stay (they're few and useful).
            for place in places where map.viewport.scale >= 0.125 || place.group == .portal {
                let point = map.viewport.viewPoint(for: place.position, in: size)
                Self.draw(place, at: point, scale: map.viewport.scale, in: context, bounds: bounds)
                if let portal = place.portal {
                    Self.drawPortalState(at: point, selected: portal == selectedPortal, status: portalStatus(portal), in: context)
                }
            }
            for hit in hits {
                guard let position = hit.position else { continue }
                Self.drawPin(at: map.viewport.viewPoint(for: position, in: size), selected: hit.id == selectedHitID,
                             in: context, bounds: bounds)
            }
            for marker in markers {
                Self.draw(marker, at: map.viewport.viewPoint(for: CGPoint(x: marker.position.x + 0.5, y: marker.position.y + 0.5), in: size),
                          in: context, bounds: CGRect(origin: .zero, size: size))
            }
        }
        .background(.background.secondary)
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(SpatialTapGesture().onEnded { value in onSelectPortal(portal(at: value.location)) })
        .scrollWheelInput { action in
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
        .onChange(of: size) { map.requestTiles(visibleIn: size, displayScale: displayScale) }
        .accessibilityElement()
        .accessibilityLabel(Text("Map of \(map.dimension.displayName)"))
        .accessibilityValue(Text("Centered on X \(Int(map.viewport.center.x)), Z \(Int(map.viewport.center.y))"))
        .accessibilityHint(Text("Use the arrow keys or scroll to move the map, and Command-scroll to zoom."))
        .overlay(alignment: .bottom) { statusBar }
        .toolbar {
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom(by: 1 / Self.zoomStep) }
                    .keyboardShortcut("-")
                    .disabled(map.viewport.scale <= MapViewport.scaleRange.lowerBound)
                Button("Actual Size", systemImage: "1.magnifyingglass") { map.viewport.scale = 1 }
                    .keyboardShortcut("0")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom(by: Self.zoomStep) }
                    .keyboardShortcut("=")  // ⌘= is the Mac convention; "+" needs Shift on most layouts
                    .disabled(map.viewport.scale >= MapViewport.scaleRange.upperBound)
            }
        }
    }

    /// A structure's icon at its center; zoomed in, also its outline (from 1/4×), its name (from
    /// 1/2×) and, for strongholds, the End portal room.
    private static func draw(_ structure: StructureMarker, viewport: MapViewport, in context: GraphicsContext,
                             size: CGSize, bounds: CGRect) {
        let topLeft = viewport.viewPoint(for: structure.bounds.origin, in: size)
        let outline = CGRect(origin: topLeft, size: CGSize(width: structure.bounds.width * viewport.scale,
                                                           height: structure.bounds.height * viewport.scale))
        guard outline.insetBy(dx: -40, dy: -40).intersects(bounds) else { return }
        let color = Color(red: Double((structure.group.color >> 16) & 0xFF) / 255,
                          green: Double((structure.group.color >> 8) & 0xFF) / 255,
                          blue: Double(structure.group.color & 0xFF) / 255)
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

    /// The portal under a click, within 14 points of its marker.
    private func portal(at point: CGPoint) -> NetherPortal? {
        places.compactMap { place -> (NetherPortal, CGFloat)? in
            guard let portal = place.portal else { return nil }
            let p = map.viewport.viewPoint(for: place.position, in: size)
            let distance = hypot(p.x - point.x, p.y - point.y)
            return distance <= 14 ? (portal, distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    /// A small round marker; its name appears from 2× zoom. Claimed beds and workstations are dimmed.
    private static func draw(_ place: PlaceMarker, at point: CGPoint, scale: CGFloat, in context: GraphicsContext, bounds: CGRect) {
        guard bounds.insetBy(dx: -20, dy: -20).contains(point) else { return }
        var context = context
        context.opacity = place.isClaimed ? 0.65 : 1
        let color = Color(red: Double((place.group.color >> 16) & 0xFF) / 255,
                          green: Double((place.group.color >> 8) & 0xFF) / 255,
                          blue: Double(place.group.color & 0xFF) / 255)
        let radius: CGFloat = place.group == .portal ? 8 : 6
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(color))
        context.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1)
        var symbol = context.resolve(Image(systemName: place.group.symbol))
        symbol.shading = .color(.white)
        let side = radius * 1.2
        context.draw(symbol, in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        guard scale >= 2 else { return }
        let text = context.resolve(Text(place.name).font(.caption2.weight(.medium)).foregroundStyle(.white))
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
            if let hoverPoint {
                let hoverBlock = map.viewport.blockPoint(at: hoverPoint, in: size)
                Text("X \(Int(hoverBlock.x.rounded(.down)))  Z \(Int(hoverBlock.y.rounded(.down)))")
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
        .opacity(hoverPoint == nil && !map.isLoading && !map.availableRegions.isEmpty ? 0 : 1)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
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

    private func zoom(by factor: CGFloat) {
        map.viewport.zoom(by: factor, anchor: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
    }
}
