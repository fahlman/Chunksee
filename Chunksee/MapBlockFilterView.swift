import ChunkseeIndex
import ChunkseeKit
import SwiftUI

/// Edits a draft and applies it once, so browsing block choices does not restart map rendering.
struct MapBlockFilterView: View {
    let session: WorldSession
    let map: MapModel
    @Environment(\.dismiss) private var dismiss
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
        catalog.filter { search.isEmpty || ReadableName.from($0).localizedStandardContains(search)
            || $0.localizedStandardContains(search) }
            .sorted { left, right in
                let comparison = ReadableName.from(left).localizedStandardCompare(ReadableName.from(right))
                return comparison == .orderedSame ? left < right : comparison == .orderedAscending
            }
    }

    var body: some View {
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
                        Text(ReadableName.from(id))
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
                    .accessibilityLabel(Text("Appearance of \(ReadableName.from(id))"))
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
            Text("Names come from this dimension’s saved palettes. Some may not currently appear on the map.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hide Leaves", isOn: Binding {
                let leaves = MapBlockFilter.leafNames(in: catalog)
                return !leaves.isEmpty && leaves.isSubset(of: draft.hiddenIDs)
            } set: { draft = draft.choosing($0 ? .hide : .show, for: MapBlockFilter.leafNames(in: catalog)) })
                .disabled(MapBlockFilter.leafNames(in: catalog).isEmpty)
                .help("Select every saved block name ending in _leaves; individual choices stay editable")
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
