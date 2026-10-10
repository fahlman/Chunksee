import SwiftUI

@main
struct MCWorldApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // One window per world. A window opened without one (at launch, or by Open World…) shows
        // the Open panel.
        WindowGroup(id: WorldWindow.sceneID, for: String.self) { $worldID in
            WorldWindow(worldID: $worldID)
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 1200, height: 800)
        // The app reopens the worlds open at quit itself, whatever the system's setting for
        // reopening windows; the system's restoring them too would open each twice.
        .restorationBehavior(.disabled)
        .commands {
            WorldCommands(model: model)
        }

        Settings {
            SettingsView(names: model.names)
        }
    }
}

/// File ▸ Open World… and Open Recent.
private struct WorldCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open World…") { openWindow(id: WorldWindow.sceneID) }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentWorlds) { world in
                    Button(world.name) { openWindow(id: WorldWindow.sceneID, value: world.id) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecentWorlds() }
                    .disabled(model.recentWorlds.isEmpty)
            }
        }
    }
}
