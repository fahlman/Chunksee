import SwiftUI

@main
struct MCWorldApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MCWorld", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open World…") { model.isShowingOpenPanel = true }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView(names: model.names)
        }
    }
}
