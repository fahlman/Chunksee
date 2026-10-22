import SwiftUI

/// An on-demand introduction; opening documents still belongs to DocumentGroup.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Explore Your Minecraft World")
                    .font(.largeTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Chunksee shows the terrain, places, pets and players in a saved Java Edition world. It only reads your world; it never changes it.")

                GroupBox("Open a World") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose File ▸ Open… and select one world’s folder inside your saves folder.")
                        Text("To reach the hidden Library folder, press Shift-Command-G in the Open panel and enter:")
                        Text(verbatim: "~/Library/Application Support/minecraft/saves")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Text("Each dimension opens as its own document. File ▸ Open Recent brings it back later.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Look Around") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Drag or scroll to move. Pinch to zoom, or click the toolbar’s zoom percentage to choose a level or Fit World.")
                        Text("Select any sidebar item or map marker to see its details and location in the inspector. Sidebar rows show only names and icons.")
                        Text("Search for an item such as diamond to find where it is stored. Select a result to see the matching contents.")
                        Text("Choose a cutaway height to look below the surface. Surface returns to the normal map.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                Link("User Guide", destination: URL(string: "https://github.com/fahlman/Chunksee#using-chunksee")!)
            }
            .padding(24)
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 440, idealHeight: 600)
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Chunksee Help") { openWindow(id: "help") }
        }
    }
}
