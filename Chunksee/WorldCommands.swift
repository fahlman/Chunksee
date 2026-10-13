import ChunkseeKit
import SwiftUI

private struct WorldSessionKey: FocusedValueKey {
    typealias Value = WorldSession
}

extension FocusedValues {
    var worldSession: WorldSession? {
        get { self[WorldSessionKey.self] }
        set { self[WorldSessionKey.self] = newValue }
    }
}

/// Map and navigation commands always target the front document, including from its sidebar.
struct WorldCommands: Commands {
    @FocusedValue(\.worldSession) private var session

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy Map Image") { session?.copyMapImage() }
                .disabled(session?.map == nil)
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
            Button("Fit World") { session?.fitWorld() }
                .disabled(session?.canFitWorld != true)
            Divider()
            Toggle("World Info", isOn: Binding {
                session?.inspector == .world
            } set: { shown in
                session?.inspector = shown ? .world : nil
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
                session?.ruler.isEnabled ?? false
            } set: { session?.setRulerEnabled($0) })
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(session?.map == nil)
            Button("Clear Measurement") { session?.ruler.clear() }
                .disabled(session?.ruler.start == nil)
        }
        CommandMenu("Navigate") {
            Button("Back") { session?.goBack() }
                .keyboardShortcut("[")
                .disabled(session?.navigation.canGoBack != true)
            Button("Forward") { session?.goForward() }
                .keyboardShortcut("]")
                .disabled(session?.navigation.canGoForward != true)
            Divider()
            Button("Go to Coordinates…") { session?.showsCoordinateSheet = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session?.map == nil)
            // ⇧⌘H, like Finder's Go ▸ Home.
            Button("Go to Spawn") {
                guard let session, let spawn = session.world.level.spawnPosition else { return }
                session.focus(on: .init(dimension: session.world.level.spawnDimension ?? "minecraft:overworld",
                                       x: Double(spawn.x), y: Double(spawn.y), z: Double(spawn.z)))
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(session?.world.level.spawnPosition == nil)
            Button("Save Place…") { session?.savePlace() }
                .keyboardShortcut("d")
                .disabled(session?.map == nil)
            Divider()
            Menu("Dimension") {
                if let session {
                    ForEach(session.dimensions, id: \.id) { dimension in
                        Toggle(dimension.displayName, isOn: Binding {
                            session.selectedDimensionID == dimension.id
                        } set: { if $0 { session.selectedDimensionID = dimension.id } })
                    }
                }
            }
            .disabled(session == nil)
            Button("Save Search") { session?.saveSearch() }
                .disabled(session?.search.isActive != true || session?.savedSearches.contains(session?.search.text ?? "") == true)
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
