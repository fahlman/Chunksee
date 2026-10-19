import ChunkseeKit
import SwiftUI

private struct WorldSessionKey: FocusedValueKey {
    typealias Value = WorldSession
}

/// Focuses the front world's search field; the field's focus state lives in its view.
struct SearchFocusAction {
    let focus: () -> Void
}

private struct SearchFocusKey: FocusedValueKey {
    typealias Value = SearchFocusAction
}

private struct MapHeightPopoverKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct CoordinateSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var coordinateSheet: Binding<Bool>? {
        get { self[CoordinateSheetKey.self] }
        set { self[CoordinateSheetKey.self] = newValue }
    }

    var mapHeightPopover: Binding<Bool>? {
        get { self[MapHeightPopoverKey.self] }
        set { self[MapHeightPopoverKey.self] = newValue }
    }

    var worldSession: WorldSession? {
        get { self[WorldSessionKey.self] }
        set { self[WorldSessionKey.self] = newValue }
    }

    var focusSearch: SearchFocusAction? {
        get { self[SearchFocusKey.self] }
        set { self[SearchFocusKey.self] = newValue }
    }
}

/// Map and navigation commands always target the front document, including from its sidebar.
struct WorldCommands: Commands {
    @FocusedValue(\.worldSession) private var session
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedBinding(\.mapHeightPopover) private var showsMapHeight
    @FocusedBinding(\.coordinateSheet) private var showsCoordinateSheet

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { focusSearch?.focus() }
                    .keyboardShortcut("f")
                    .disabled(focusSearch == nil)
            }
        }
        CommandGroup(before: .sidebar) {
            Button("Zoom In") { session?.map?.zoom(by: 2) }
                .keyboardShortcut("+")
                .disabled((session?.map?.viewport.scale ?? MapViewport.scaleRange.upperBound) >= MapViewport.scaleRange.upperBound)
            Button("Zoom Out") { session?.map?.zoom(by: 0.5) }
                .keyboardShortcut("-")
                .disabled(session?.map?.viewport.canZoomOut != true)
            Button("Actual Size") { session?.map?.viewport.scale = 1 }
                .keyboardShortcut("0")
                .disabled(session?.map == nil)
            Button("Fit World") { session?.navigation.fitWorld() }
                .disabled(session?.navigation.canFitWorld != true)
            Button("Map Height…") { showsMapHeight = true }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(session?.map == nil || showsMapHeight == nil)
            Toggle("Surface", isOn: Binding {
                session?.map?.depth.isSurface ?? true
            } set: { isSurface in
                guard let map = session?.map else { return }
                map.setDepth(MapDepth(y: map.depth.y, isSurface: isSurface))
            })
                .keyboardShortcut("y", modifiers: [.command, .option])
                .disabled(session?.map == nil)
            Divider()
            Toggle("World Info", isOn: Binding {
                session?.selection.inspector == .world
            } set: { shown in
                session?.selection.inspector = shown ? .world : nil
            })
            .keyboardShortcut("i")
            .disabled(session == nil)
            Toggle("Time Spent", isOn: Binding {
                session?.heatMap.isShown ?? false
            } set: { session?.heatMap.isShown = $0 })
            .disabled(session?.map == nil)
            Toggle("Grid", isOn: Binding {
                session?.visibility.showsGrid ?? false
            } set: { session?.visibility.showsGrid = $0 })
            .disabled(session?.map == nil)
            Toggle("Measure Distance", isOn: Binding {
                session?.annotations.ruler.isEnabled ?? false
            } set: { session?.annotations.setRulerEnabled($0) })
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(session?.map == nil)
            Button("Clear Measurement") { session?.annotations.ruler.clear() }
                .disabled(session?.annotations.ruler.start == nil)
        }
        CommandMenu("Navigate") {
            Button("Back") { session?.navigation.goBack() }
                .keyboardShortcut("[")
                .disabled(session?.navigation.canGoBack != true)
            Button("Forward") { session?.navigation.goForward() }
                .keyboardShortcut("]")
                .disabled(session?.navigation.canGoForward != true)
            Divider()
            Button("Go to Coordinates…") { showsCoordinateSheet = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session?.map == nil || showsCoordinateSheet == nil)
            // ⇧⌘H, like Finder's Go ▸ Home.
            Button("Go to Spawn") {
                guard let session, let spawn = session.world.level.spawnPosition,
                      let dimension = session.world.level.spawnDimension else { return }
                session.routing.focus(on: .init(dimension: dimension,
                                       x: Double(spawn.x), y: Double(spawn.y), z: Double(spawn.z)))
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(session?.world.level.spawnPosition == nil)
            Button("Save Place…") { session?.annotations.savePlace() }
                .keyboardShortcut("d")
                .disabled(session?.map == nil)
            Divider()
            Menu("Dimension") {
                if let session {
                    ForEach(session.dimensions, id: \.id) { dimension in
                        Toggle(session.dimensionName(dimension.id), isOn: Binding {
                            session.selectedDimensionID == dimension.id
                        } set: { if $0 { session.routing.openDimension(dimension.id) } })
                    }
                }
            }
            .disabled(session == nil)
            Button("Save Search") { session?.search.saveSearch() }
                .disabled(session?.search.canSaveSearch != true)
        }
    }
}

/// Preview accepts both forms of the punctuation keys. Keep one visible menu command,
/// with additional SwiftUI shortcuts scoped to the focused world's content.
struct WorldKeyboardShortcuts: View {
    let session: WorldSession
    @FocusedValue(\.worldSession) private var focusedSession

    var body: some View {
        VStack {
            Button("Zoom In") { session.map?.zoom(by: 2) }
                .keyboardShortcut("=")
                .disabled(focusedSession !== session ||
                          (session.map?.viewport.scale ?? MapViewport.scaleRange.upperBound) >= MapViewport.scaleRange.upperBound)
            Button("Zoom Out") { session.map?.zoom(by: 0.5) }
                .keyboardShortcut("_")
                .disabled(focusedSession !== session ||
                          session.map?.viewport.canZoomOut != true)
        }
        .hidden()
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
    }
}
