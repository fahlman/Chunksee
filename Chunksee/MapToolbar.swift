import SwiftUI

/// Controls act on this document's map; the menu bar uses the focused document instead.
struct MapToolbar: ToolbarContent {
    let session: WorldSession
    @Bindable var map: MapModel
    @Binding var showsHeightPopover: Bool

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
            MapZoomControl(session: session, map: map)
        }
        ToolbarItem {
            MapDepthControl(map: map, heightRange: session.presentation.heightRange, showsPopover: $showsHeightPopover)
        }
        ToolbarItem {
            Toggle("Measure Distance", systemImage: "ruler", isOn: Binding {
                session.annotations.ruler.isEnabled
            } set: { session.annotations.setRulerEnabled($0) })
            .toggleStyle(.button)
            .help("Measure the distance between two points on the map")
        }
    }
}
