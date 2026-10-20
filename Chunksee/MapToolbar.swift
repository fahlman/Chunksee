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
        ToolbarItem {
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
