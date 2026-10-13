import SwiftUI

@main
struct ChunkseeApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyDocumentMenus.self) private var documentMenus
    @State private var model = AppModel.shared

    var body: some Scene {
        Settings {
            SettingsView(names: model.names)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            InspectorCommands()
            WorldCommands(windows: model.windows)
        }
    }
}
