import SwiftUI

@main
struct MCWorldApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        DocumentGroup { (document: WorldDocument) in
            WorldDocumentView(document: document)
                .frame(minWidth: 640, minHeight: 420)
        } makeReadableDocument: { configuration, _ in
            WorldDocument(configuration: configuration, model: model)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()
            InspectorCommands()
            WorldCommands()
        }

        Settings {
            SettingsView(names: model.names)
        }
    }
}
