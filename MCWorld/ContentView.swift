import MCWorldKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let session = model.session {
                WorldView(session: session)
            } else {
                ContentUnavailableView {
                    Label("No World Open", systemImage: "map")
                } description: {
                    Text("Choose a world’s folder from your Minecraft saves folder.")
                } actions: {
                    Button("Open World…") { model.isShowingOpenPanel = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isOpening)
                }
            }
        }
        .fileImporter(isPresented: $model.isShowingOpenPanel, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.open(url) }
        }
        .alert("Couldn’t Open World", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.restoreLastWorld() }
    }
}

private struct WorldView: View {
    @Bindable var session: WorldSession

    var body: some View {
        NavigationSplitView {
            List(session.dimensions, id: \.id, selection: $session.selectedDimensionID) { dimension in
                Label(dimension.displayName, systemImage: symbol(for: dimension.id))
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            if let map = session.map {
                MapView(map: map)
                    .id(map.dimension.id)
                    .navigationTitle(session.displayName)
                    .navigationSubtitle(map.dimension.displayName)
            } else {
                ContentUnavailableView("No Dimensions", systemImage: "questionmark.folder",
                                       description: Text("This world has no saved terrain yet."))
            }
        }
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "minecraft:overworld": "globe.americas"
        case "minecraft:the_nether": "flame"
        case "minecraft:the_end": "moon.stars"
        default: "square.dashed"
        }
    }
}
