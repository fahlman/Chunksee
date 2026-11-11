import ChunkseeIndex
import ChunkseeKit
import SwiftUI

/// Edits a draft and applies it once, so browsing block choices does not restart map rendering.
struct MapBlockFilterView: View {
    let session: WorldSession
    let map: MapModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gameNames) private var gameNames
    @State private var draft: MapBlockFilter
    @State private var search = ""

    init(session: WorldSession, map: MapModel) {
        self.session = session
        self.map = map
        _draft = State(initialValue: map.blockFilter)
    }

    private var catalog: Set<String> {
        // Keep saved choices editable if a later world update removes their last palette entry.
        (session.presentation.selectedIndex.shared?.paletteBlockIDs ?? [])
            .union(draft.hiddenIDs).union(draft.highlightedIDs)
    }

    private var displayed: [String] {
        gameNames.blockIDs(in: catalog, matching: search)
    }

    var body: some View {
        let leaves = MapBlockFilter.leafIDs(in: catalog, tag: session.details.definitions.leafTag)
        VStack(alignment: .leading, spacing: 12) {
            Text("Show/Hide Blocks").font(.headline)
            Text("Hide blocks to see below them, or highlight blocks to make them stand out.")
                .foregroundStyle(.secondary)
            Toggle("Apply Block Choices", isOn: Binding { draft.isEnabled } set: { draft = draft.enabled($0) })
            TextField("Find a Block", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("block-filter-search")
            List(displayed, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading) {
                        Text(gameNames.block(id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Appearance", selection: Binding { draft.choice(for: id) } set: { draft = draft.choosing($0, for: [id]) }) {
                        Text("Show").tag(MapBlockFilter.Choice.show)
                        Text("Hide").tag(MapBlockFilter.Choice.hide)
                        Text("Highlight").tag(MapBlockFilter.Choice.highlight)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel(Text("Appearance of \(gameNames.block(id))"))
                    .accessibilityIdentifier("block-filter-" + id)
                }
            }
            .overlay {
                if catalog.isEmpty {
                    ContentUnavailableView("No Block Names Yet", systemImage: "square.stack.3d.up",
                                           description: Text("Block names appear as this dimension is read."))
                } else if displayed.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            Text("Blocks come from this dimension’s saved palettes. Some may not currently appear on the map.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hide Leaves", isOn: Binding {
                leaves.map { !$0.isEmpty && $0.isSubset(of: draft.hiddenIDs) } ?? false
            } set: { hidden in
                if let leaves { draft = draft.choosing(hidden ? .hide : .show, for: leaves) }
            })
                .disabled(leaves?.isEmpty ?? true)
                .help(leaves == nil
                      ? Text("Leaf types are unavailable. You can still choose individual blocks.")
                      : Text("Select blocks in Minecraft’s leaves group; individual choices stay editable"))
            HStack {
                Button("Reset Choices") { draft = MapBlockFilter() }
                    .disabled(draft == MapBlockFilter())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    map.setBlockFilter(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(map.isClosed)
            }
        }
        .padding(20)
        .frame(width: 540, height: 540)
    }
}
