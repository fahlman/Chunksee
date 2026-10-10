import SwiftUI

/// The pannable, zoomable top-down map of one dimension.
struct MapView: View {
    @Bindable var map: MapModel

    @State private var size: CGSize = .zero
    @State private var dragStart: MapViewport?
    @State private var magnifyStart: MapViewport?
    @State private var hoverBlock: CGPoint?
    @FocusState private var isFocused: Bool

    /// Zoom buttons and shortcuts step by a factor of two.
    private static let zoomStep: CGFloat = 2

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            // Crisp block edges when zoomed in; smoothing when zoomed out avoids shimmering.
            let interpolation: Image.Interpolation = map.viewport.scale >= 1 ? .none : .medium
            for (region, image) in map.tiles {
                let rect = map.viewport.viewRect(for: region, in: size)
                guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                context.draw(Image(decorative: image, scale: 1).interpolation(interpolation), in: rect)
            }
        }
        .background(.background.secondary)
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverBlock = map.viewport.blockPoint(at: point, in: size)
            case .ended: hoverBlock = nil
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
        .onChange(of: map.viewport, initial: true) { map.requestTiles(visibleIn: size) }
        .onChange(of: size) { map.requestTiles(visibleIn: size) }
        .accessibilityElement()
        .accessibilityLabel(Text("Map of \(map.dimension.displayName)"))
        .accessibilityValue(Text("Centered on X \(Int(map.viewport.center.x)), Z \(Int(map.viewport.center.y))"))
        .accessibilityHint(Text("Use the arrow keys to move the map."))
        .overlay(alignment: .bottom) { statusBar }
        .toolbar {
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom(by: 1 / Self.zoomStep) }
                    .keyboardShortcut("-")
                    .disabled(map.viewport.scale <= MapViewport.scaleRange.lowerBound)
                Button("Actual Size", systemImage: "1.magnifyingglass") { map.viewport.scale = 1 }
                    .keyboardShortcut("0")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom(by: Self.zoomStep) }
                    .keyboardShortcut("+")
                    .disabled(map.viewport.scale >= MapViewport.scaleRange.upperBound)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let hoverBlock {
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
        .opacity(hoverBlock == nil && !map.isLoading && !map.availableRegions.isEmpty ? 0 : 1)
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
