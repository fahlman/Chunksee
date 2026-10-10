import SwiftUI

/// The pannable, zoomable top-down map of one dimension.
struct MapView: View {
    @Bindable var map: MapModel
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
