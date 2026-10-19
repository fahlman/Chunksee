import SwiftUI

#if !CHUNKSEE_TEST_HOST
@main
struct ChunkseeApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyDocumentMenus.self) private var documentMenus
    @State private var model = AppModel(defaults: .standard, cacheRoot: TileCache.root)
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
            focusedSession?.becameActive(isTerminating: documentMenus.isTerminating)
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
#endif
