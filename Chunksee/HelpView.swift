import SwiftUI

/// An on-demand introduction; opening documents still belongs to DocumentGroup.
struct HelpView: View {
    @Environment(\.openDocument) private var openDocument
    @State private var errorMessage: String?
    @State private var isOpeningSample = false

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
                        Text("Select a pet or player to see details. Search for an item such as diamond to find where it is stored.")
                        Text("Use the Y slider to look below the surface. Surface returns to the normal map.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                Text("No world handy? The sample has a small island, a cabin, two pets and a chest of diamonds. Minecraft isn’t needed to explore it.")
                HStack {
                    Button("Open Sample World") { isOpeningSample = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isOpeningSample)
                    if isOpeningSample { ProgressView().controlSize(.small) }
                    Spacer()
                    Link("User Guide", destination: URL(string: "https://github.com/fahlman/Chunksee#using-chunksee")!)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 440, idealHeight: 600)
        .task(id: isOpeningSample) {
            if isOpeningSample { await openSample() }
        }
        .alert("Couldn’t Open Sample World", isPresented: Binding {
            errorMessage != nil
        } set: { if !$0 { errorMessage = nil } }) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func openSample() async {
        defer { isOpeningSample = false }
        guard let url = SampleWorld.url(in: .main) else {
            errorMessage = String(localized: "The sample world couldn’t be found in this copy of Chunksee.")
            return
        }
        do { try await openDocument(at: url) }
        catch is CancellationError {}
        catch { errorMessage = error.localizedDescription }
    }
}

enum SampleWorld {
    static func url(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "SampleWorld", withExtension: nil)
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Chunksee Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
