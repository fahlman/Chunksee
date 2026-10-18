import SwiftUI

@main
struct ChunkseeApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyDocumentMenus.self) private var documentMenus
    @State private var model = AppModel()
    @FocusedValue(\.worldSession) private var focusedSession

    var body: some Scene {
        DocumentGroup { (document: WorldDocument) in
            WorldDocumentView(document: document)
                .frame(minWidth: 640, minHeight: 420)
        } makeReadableDocument: { configuration, _ in
            WorldDocument(configuration: configuration, model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1200, height: 800)
        .onChange(of: focusedSession?.viewID) {
            focusedSession?.becameActive()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            InspectorCommands()
            WorldCommands()
        }

        Settings {
            SettingsView(names: model.names)
        }
    }
}
