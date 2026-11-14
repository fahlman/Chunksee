import SwiftUI

#if !CHUNKSEE_TEST_HOST
@main
struct ChunkseeApp: App {
    @NSApplicationDelegateAdaptor(ReadOnlyDocumentMenus.self) private var documentMenus
    @State private var model: AppModel

    init() {
        let model = AppModel(defaults: .standard, cacheRoot: TileCache.root)
        _model = State(initialValue: model)
        documentMenus.prepareForTermination = { [weak model] in model?.saveViews() }
    }

    var body: some Scene {
        WorldDocumentScene(isTerminating: { documentMenus.isTerminating }) { configuration in
            WorldDocument(configuration: configuration, model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
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

/// App and document-window tests share sizing, focused-document activation and column commands.
struct WorldDocumentScene: Scene {
    let isTerminating: @MainActor () -> Bool
    let makeDocument: @MainActor (URLDocumentConfiguration) throws -> WorldDocument
    @FocusedValue(\.worldSession) private var focusedSession

    init(isTerminating: @escaping @MainActor () -> Bool,
         makeDocument: @escaping @MainActor (URLDocumentConfiguration) throws -> WorldDocument) {
        self.isTerminating = isTerminating
        self.makeDocument = makeDocument
    }

    var body: some Scene {
        DocumentGroup { (document: WorldDocument) in
            WorldDocumentView(document: document)
        } makeReadableDocument: { configuration, _ in
            try makeDocument(configuration)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1200, height: 800)
        .onChange(of: focusedSession?.viewID) {
            focusedSession?.becameActive(isTerminating: isTerminating())
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
        }
    }
}
