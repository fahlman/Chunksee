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

private struct MapImageSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct MapBlockFilterSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var mapBlockFilterSheet: Binding<Bool>? {
        get { self[MapBlockFilterSheetKey.self] }
        set { self[MapBlockFilterSheetKey.self] = newValue }
    }

    var mapImageSheet: Binding<Bool>? {
        get { self[MapImageSheetKey.self] }
        set { self[MapImageSheetKey.self] = newValue }
    }

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
    @Bindable var minecraft: MinecraftResources
    @FocusedValue(\.worldSession) private var session
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedBinding(\.mapHeightPopover) private var showsMapHeight
    @FocusedBinding(\.coordinateSheet) private var showsCoordinateSheet
    @FocusedBinding(\.mapImageSheet) private var showsImageExport
    @FocusedBinding(\.mapBlockFilterSheet) private var showsBlockFilter

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { focusSearch?.focus() }
                    .keyboardShortcut("f")
                    .disabled(focusSearch == nil)
                Button("Save Search") { session?.search.saveSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(session?.search.canSaveSearch != true)
            }
        }
        CommandGroup(before: .sidebar) {
            Button("Zoom In") { session?.map?.zoom(by: 2) }
                .keyboardShortcut("+")
                .disabled(session?.map?.viewport.canZoomIn != true)
            Button("Zoom Out") { session?.map?.zoom(by: 0.5) }
                .keyboardShortcut("-")
                .disabled(session?.map?.viewport.canZoomOut != true)
            Button("Actual Size") { session?.map?.viewport.scale = 1 }
                .keyboardShortcut("0")
                .disabled(session?.map == nil)
            Button("Fit World") { session?.navigation.fitWorld() }
                .keyboardShortcut("9")
                .disabled(session?.navigation.canFitWorld != true)
            Menu("Map Style") {
                ForEach(MapStyle.allCases, id: \.self) { style in
                    // Native menu toggles honor per-item availability. An inline Picker's
                    // Text options remain enabled even when their .disabled value is true.
                    Toggle(isOn: Binding {
                        session?.map?.style == style
                    } set: { if $0 { session?.map?.setStyle(style) } }) {
                        Text(style.title)
                    }
                    .disabled(style == .height && session?.map?.heightScale == nil)
                }
                Divider()
                Toggle("Blend Biome Colors", isOn: Binding {
                    session?.map?.blendsBiomeColors ?? false
                } set: { session?.map?.setBiomeBlending($0) })
                .help("Smooth grass, foliage and water colors across biome boundaries")
                .disabled(session?.map?.style == .height)
            }
            .disabled(session?.map == nil)
            Toggle("Use Game Artwork", isOn: $minecraft.usesGameArtwork)
            Menu("Lighting") {
                ForEach(MapLightingMode.allCases, id: \.self) { mode in
                    Toggle(isOn: Binding {
                        (session?.map?.lighting == nil ? MapLightingMode.daylight : .savedTime) == mode
                    } set: { if $0 { session?.map?.setLightingMode(mode) } }) {
                        Text(mode.title)
                    }
                    .disabled(mode == .savedTime && session?.map?.savedLighting == nil)
                }
                Divider()
                Toggle("Cast Shadows", isOn: Binding {
                    session?.map?.castsShadows ?? true
                } set: { session?.map?.setCastsShadows($0) })
            }
            .disabled(session?.map == nil || session?.map?.style == .height)
            Button("Show/Hide Blocks…") { showsBlockFilter = true }
                .disabled(session?.map == nil || showsBlockFilter == nil)
            Button("Map Height…") { showsMapHeight = true }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(session?.map == nil || showsMapHeight == nil)
            Button("Increase Y Level") { session?.map?.stepHeight(by: 1) }
                .keyboardShortcut("+", modifiers: [.command, .control])
                .buttonRepeatBehavior(.enabled)
                .disabled(session?.map == nil || session?.map?.depth.y == Int.max)
            Button("Decrease Y Level") { session?.map?.stepHeight(by: -1) }
                .keyboardShortcut("-", modifiers: [.command, .control])
                .buttonRepeatBehavior(.enabled)
                .disabled(session?.map == nil || session?.map?.depth.y == Int.min)
            Button("Create Map Image…") { showsImageExport = true }
                .disabled(session?.map == nil || showsImageExport == nil)
            Toggle("Surface", isOn: Binding {
                session?.map?.depth.isSurface ?? true
            } set: { isSurface in
                guard let map = session?.map else { return }
                map.setDepth(MapDepth(y: map.depth.y, isSurface: isSurface))
            })
                .keyboardShortcut("y", modifiers: [.command, .option])
                .disabled(session?.map == nil)
            Divider()
            inspectorCommand("World Info", inspector: .world)
                .keyboardShortcut("i")
            inspectorCommand("Storage", inspector: .storage)
            Toggle("Time Spent", isOn: Binding {
                session?.heatMap.isShown ?? false
            } set: { session?.heatMap.isShown = $0 })
            .disabled(session?.map == nil)
            Toggle("Slime Chunks", isOn: Binding {
                session?.slimeChunks.isShown ?? false
            } set: { session?.slimeChunks.isShown = $0 })
            .disabled(session?.slimeChunks.isAvailable != true)
            Toggle("Dark Spots", isOn: Binding {
                session?.map?.showsDarkSpots ?? false
            } set: { session?.setDarkSpots($0) })
            .disabled(session?.map == nil)
            Toggle("Grid", isOn: Binding {
                session?.visibility.showsGrid ?? false
            } set: { session?.visibility.showsGrid = $0 })
            .disabled(session?.map == nil)
            Toggle("World Border", isOn: Binding {
                session?.presentation.limitedWorldBorder != nil && session?.visibility.showsWorldBorder == true
            } set: { session?.visibility.showsWorldBorder = $0 })
            .disabled(session?.presentation.limitedWorldBorder == nil)
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
            Button("Go to Spawn") { session?.routing.goToSpawn() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(session?.presentation.worldSpawn == nil)
            Button("Save Place…") { session?.annotations.savePlace() }
                .keyboardShortcut("d")
                .disabled(session?.map == nil)
            PlanPortalCommand(session: session)
            Divider()
            Menu("Dimension") {
                if let session {
                    ForEach(session.dimensions, id: \.id) { dimension in
                        Toggle(isOn: Binding {
                            session.selectedDimensionID == dimension.id
                        } set: { if $0 { session.routing.openDimension(dimension.id) } }) {
                            Text(dimension.id, format: session.presentation.dimensionNameStyle)
                        }
                    }
                }
            }
            .disabled(session == nil)
        }
    }

    private func inspectorCommand(_ title: LocalizedStringKey, inspector: Inspector) -> some View {
        Toggle(title, isOn: Binding {
            session?.selection.inspector == inspector
        } set: { shown in
            session?.selection.inspector = shown ? inspector : nil
        })
        .disabled(session == nil)
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
                          session.map?.viewport.canZoomIn != true)
            Button("Zoom Out") { session.map?.zoom(by: 0.5) }
                .keyboardShortcut("_")
                .disabled(focusedSession !== session ||
                          session.map?.viewport.canZoomOut != true)
            Button("Increase Y Level") { session.map?.stepHeight(by: 1) }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .buttonRepeatBehavior(.enabled)
                .disabled(focusedSession !== session || session.map == nil || session.map?.depth.y == Int.max)
            Button("Decrease Y Level") { session.map?.stepHeight(by: -1) }
                .keyboardShortcut("_", modifiers: [.command, .control])
                .buttonRepeatBehavior(.enabled)
                .disabled(focusedSession !== session || session.map == nil || session.map?.depth.y == Int.min)
        }
        .hidden()
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
    }
}
