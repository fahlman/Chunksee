import SwiftUI

enum ZoomPercentage {
    static func text(_ scale: CGFloat) -> String {
        if scale < 0.01 {
            return Double(scale).formatted(.percent.precision(.significantDigits(1...4)))
        }
        return Double(scale).formatted(.percent.precision(.fractionLength(0...2)))
    }
}

/// Controls act on this document's map; the menu bar uses the focused document instead.
struct MapToolbar: ToolbarContent {
    let session: WorldSession
    @Bindable var map: MapModel
    private static let levels: [CGFloat] = [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 16, 32]

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { session.navigation.goBack() }
                .disabled(!session.navigation.canGoBack)
                .help("Go back to the previous map view")
            Button("Forward", systemImage: "chevron.forward") { session.navigation.goForward() }
                .disabled(!session.navigation.canGoForward)
                .help("Go forward to the next map view")
        }
        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { map.zoom(by: 0.5) }
                .disabled(!map.viewport.canZoomOut)
            Button("Actual Size", systemImage: "1.magnifyingglass") { map.viewport.scale = 1 }
            Button("Zoom In", systemImage: "plus.magnifyingglass") { map.zoom(by: 2) }
                .disabled(map.viewport.scale >= MapViewport.scaleRange.upperBound)
            Menu {
                Picker("Zoom", selection: $map.viewport.scale) {
                    if !Self.levels.contains(map.viewport.scale) {
                        Text(ZoomPercentage.text(map.viewport.scale)).tag(map.viewport.scale)
                        Divider()
                    }
                    ForEach(Self.levels, id: \.self) { level in
                        Text(ZoomPercentage.text(level)).tag(level)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Fit World") { session.navigation.fitWorld() }
                    .disabled(!session.navigation.canFitWorld)
            } label: {
                Text(ZoomPercentage.text(map.viewport.scale))
                    .monospacedDigit()
                    .frame(minWidth: 56)
            }
            .accessibilityLabel("Zoom")
            .accessibilityValue(Text(ZoomPercentage.text(map.viewport.scale)))
            .help("Choose a zoom level or fit the world")
        }
        ToolbarItem {
            MapDepthControl(map: map)
        }
        ToolbarItem {
            Toggle("Measure Distance", systemImage: "ruler", isOn: Binding {
                session.ruler.isEnabled
            } set: { session.setRulerEnabled($0) })
            .toggleStyle(.button)
            .help("Measure the distance between two points on the map")
        }
    }
}
