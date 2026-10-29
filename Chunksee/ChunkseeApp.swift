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
        WorldDocumentScene { configuration in
            WorldDocument(configuration: configuration, model: model)
        }
        .onChange(of: focusedSession?.viewID) {
            focusedSession?.becameActive(isTerminating: documentMenus.isTerminating)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            InspectorCommands()
            WorldCommands(minecraft: model.names.minecraft)
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

/// The app and isolated document-window tests use the same scene and sizing rules.
struct WorldDocumentScene: Scene {
    let makeDocument: @MainActor (URLDocumentConfiguration) throws -> WorldDocument

    var body: some Scene {
        DocumentGroup { (document: WorldDocument) in
            WorldDocumentView(document: document)
        } makeReadableDocument: { configuration, _ in
            try makeDocument(configuration)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1200, height: 800)
    }
}
