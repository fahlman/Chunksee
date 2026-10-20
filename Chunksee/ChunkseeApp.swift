import SwiftUI

#if !CHUNKSEE_TEST_HOST
@main
struct ChunkseeApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyDocumentMenus.self) private var documentMenus
    @State private var model: AppModel
    @FocusedValue(\.worldSession) private var focusedSession

    init() {
        let model = AppModel(defaults: .standard, cacheRoot: TileCache.root)
        _model = State(initialValue: model)
        documentMenus.prepareForTermination = { [weak model] in model?.saveViews() }
    }

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
            HelpCommands()
        }

        Window("Chunksee Help", id: "help") {
            HelpView()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 520, height: 600)

        Settings {
            SettingsView(names: model.names)
        }
    }
}
#endif
