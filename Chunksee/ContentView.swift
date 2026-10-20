import ChunkseeKit
import SwiftUI

struct WorldView: View {
    @Bindable var session: WorldSession
    @State private var sidebarDisclosure = SidebarDisclosure()
    /// A new request also reveals a selected row again after the user scrolls away or collapses it.
    @State private var sidebarRevealID = UUID()
    @State private var showsCoordinateSheet = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        @Bindable var visibility = session.visibility
        @Bindable var search = session.search
        @Bindable var annotations = session.annotations
        @Bindable var heatMap = session.heatMap
        @Bindable var slimeChunks = session.slimeChunks
        let nameRequest = session.names.request(for: session.players)
        NavigationSplitView {
            ScrollViewReader { proxy in
                List(selection: sidebarSelection) {
                    if search.isActive {
                        SearchResultsSection(session: session)
                    }
                    Section("World") {
                        Label("World Info", systemImage: "info.circle")
                            .tag(SidebarItem.worldInfo)
                            .help("Show the world’s settings, time, weather and game rules")
                        Label("Storage", systemImage: "shippingbox")
                            .tag(SidebarItem.storage)
                            .help("Show totals of the items stored in this dimension’s containers")
                        Toggle(isOn: $heatMap.isShown) {
                            Label("Time Spent", systemImage: "flame")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Color the map by how long players spent near each chunk")
                        if slimeChunks.isAvailable {
                            Toggle(isOn: $slimeChunks.isShown) {
                                Label("Slime Chunks", systemImage: "square.grid.3x3.fill")
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Mark Overworld chunks where slimes can spawn below Y 40")
                        }
                        Toggle(isOn: $visibility.showsGrid) {
                            Label("Grid", systemImage: "grid")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Show block, chunk and region lines; block lines appear from 8× zoom")
                    }
                    if !session.savedSearches.all.isEmpty {
                        SavedSearchesSection(session: session, expanded: $sidebarDisclosure.savedSearches)
                    }
                    SavedPlacesSection(session: session)
                    let index = session.presentation.selectedIndex
                    LayerSection(title: "Structures", markers: index.structures, origin: session.presentation.spawnPoint,
                                 shown: $visibility.structures, item: { SidebarItem.structure($0.id) },
                                 isExpanded: layerExpanded(.structures), expandedGroups: $sidebarDisclosure.structures)
                    LayerSection(title: "Places", markers: index.places, origin: session.presentation.spawnPoint,
                                 shown: $visibility.places, item: { SidebarItem.place($0.id) },
                                 isExpanded: layerExpanded(.places), expandedGroups: $sidebarDisclosure.places)
                    LayerSection(title: "Creatures", markers: index.creatures, origin: session.presentation.spawnPoint,
                                 shown: $visibility.creatures, item: { SidebarItem.creature($0.id) },
                                 isExpanded: layerExpanded(.creatures), expandedGroups: $sidebarDisclosure.creatures)
                    // Every biome the dimension can have, once it's been read, so one not found yet shows 0.
                    LayerSection(title: "Biomes", markers: index.biomeAreas, origin: session.presentation.spawnPoint,
                                 shown: $visibility.biomes, allGroups: session.presentation.possibleBiomes, item: { SidebarItem.biome($0.id) },
                                 isExpanded: layerExpanded(.biomes), expandedGroups: $sidebarDisclosure.biomes)
                    if !session.presentation.inGameMaps.isEmpty {
                        Section("In-Game Maps", isExpanded: $sidebarDisclosure.showsInGameMaps) {
                            ForEach(session.presentation.inGameMaps, id: \.id) { map in
                                InGameMapRow(session: session, map: map)
                            }
                        }
                    }
                    if !session.presentation.listedPlayers.isEmpty {
                        Section("Players") {
                            ForEach(session.presentation.listedPlayers, id: \.uuid) { player in
                                PlayerRow(session: session, player: player)
                            }
                            // A row rather than a section footer: sidebar lists don't show footers.
                            if session.presentation.hasUnnamedPlayers {
                                SettingsLink {
                                    Label("Find Player Names…", systemImage: "magnifyingglass")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .focused($isSidebarFocused)
                // Clicking the selected row need not change the List binding, but must still
                // move keyboard input from the map to the sidebar. Keep native row/control actions.
                .simultaneousGesture(TapGesture().onEnded { isSidebarFocused = true })
                // A new dimension can receive its jump before this view appears.
                .onChange(of: session.selection.sidebarRevealRequest, initial: true) {
                    guard session.selection.sidebarRevealRequest != nil, let item = session.selection.sidebarSelection else { return }
                    sidebarDisclosure.reveal(item, in: session)
                    sidebarRevealID = UUID()
                }
                .onChange(of: sidebarRevealID) {
                    if let item = session.selection.sidebarSelection {
                        withAnimation { proxy.scrollTo(item, anchor: .center) }
                    }
                }
                .contextMenu(forSelectionType: SidebarItem.self) { _ in } primaryAction: { items in
                    if let item = items.first { session.selection.choose(item) }
                }
                // Names come from the chosen Minecraft folder and, when allowed, from Mojang; look again
                // whenever either setting changes.
                .task(id: nameRequest) {
                    await session.names.load(nameRequest)
                }
            }
            .frame(minWidth: 180, idealWidth: 220)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if session.presentation.isSavedBeforeReadableFormat {
                ContentUnavailableView {
                    Label("Saved Before Minecraft 1.18", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Chunksee can show worlds saved by Minecraft 1.18 or later. To update this one, select it in Minecraft’s world list and choose Upgrade and Play if Minecraft offers it, then return to the list. Select it again, choose Edit, then Optimize World, and open it here again.")
                }
                .navigationSubtitle(session.presentation.displayName)
            } else if let map = session.map {
                MapView(session: session, map: map, content: MapContent(session: session), portalStatus: { session.presentation.linkStatus(for: $0) },
                        onSelect: selectOnMap)
                    .id(map.dimension.id)
                    .onChange(of: map.depth) { session.saveView() }
                    // Edit ▸ Copy copies the map as shown, while the map has focus.
                    .copyable([SharedMapImage { [session] in MapImage.render(session: session) }])
                    // Remember the position a second after the map stops moving.
                    .task(id: map.viewport) {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { session.saveView() }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if heatMap.isShown {
                            HeatMapLegend(isLoading: heatMap.isLoading)
                                .padding(10)
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            ShareLink(item: SharedMapImage { [session] in MapImage.render(session: session) },
                                      preview: SharePreview("Map of \(session.presentation.displayName)", image: Image(systemName: "map"))) {
                                Label("Share Map Image", systemImage: "square.and.arrow.up")
                            }
                            .help("Share an image of the map as shown")
                        }
                    }
                    // The document's folder names the window, so the subtitle names the world.
                    .navigationSubtitle(session.presentation.displayName)
            } else {
                ContentUnavailableView("No Dimensions", systemImage: "questionmark.folder",
                                       description: Text("This world has no saved terrain yet."))
            }
        }
        .searchable(text: $search.text, placement: .toolbar, prompt: Text("Find items, signs and pets"))
        .searchFocused($isSearchFocused)
        .searchSuggestions {
            // Filters that search one sidebar layer, offered while the first word is typed.
            if !search.text.contains(":") && !search.text.contains(" ") {
                ForEach(LayerFilter.allCases.filter { $0.rawValue.hasPrefix(search.text.lowercased()) }, id: \.self) { filter in
                    // One line: a suggestion that wraps makes AppKit's suggestions window ask for
                    // constraint passes until it throws, crashing the app (fahlman/Chunksee#81).
                    Label(filter.prompt, systemImage: filter.symbol)
                        .lineLimit(1)
                        .searchCompletion(filter.rawValue + ":")
                }
            }
        }
        .sheet(isPresented: $showsCoordinateSheet) {
            GoToCoordinatesView(session: session)
        }
        .sheet(item: $annotations.draft) { draft in
            SavedPlaceEditor(session: session, draft: draft)
        }
        .inspector(isPresented: inspectorShown) {
            WorldInspector(session: session)
                // Capped so a wide row can't push the inspector past the window's edge.
                .inspectorColumnWidth(min: 320, ideal: 340, max: 420)
        }
        .focusedSceneValue(\.worldSession, showsCoordinateSheet || session.annotations.draft != nil ? nil : session)
        .focusedSceneValue(\.focusSearch, showsCoordinateSheet || session.annotations.draft != nil ? nil : SearchFocusAction { isSearchFocused = true })
        .focusedSceneValue(\.coordinateSheet, $showsCoordinateSheet)
        .background { WorldKeyboardShortcuts(session: session) }
    }

    /// Only input through the native List binding navigates and requests sidebar focus.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding { session.selection.sidebarSelection } set: { item in
            if item != nil { isSidebarFocused = true }
            session.selection.choose(item)
        }
    }

    private func selectOnMap(_ target: MapTarget?, y: Double?) {
        if sidebarDisclosure.selectOnMap(target, y: y, in: session) { sidebarRevealID = UUID() }
    }

    private func layerExpanded(_ layer: SidebarLayer) -> Binding<Bool> {
        Binding { !sidebarDisclosure.collapsedLayers.contains(layer) } set: {
            if $0 { sidebarDisclosure.collapsedLayers.remove(layer) }
            else { sidebarDisclosure.collapsedLayers.insert(layer) }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding { session.selection.inspector != nil } set: {
            if !$0 { session.selection.inspector = nil }
            else if session.selection.inspector == nil { session.selection.inspector = .world }
        }
    }

}

/// A player in the sidebar. Choosing one shows their details and, when it's known, their last
/// position on the map, as choosing a pet does.
private struct PlayerRow: View {
    let session: WorldSession
    let player: PlayerInfo

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.presentation.name(of: player))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: MarkerStyle.playerAppearance(.player).symbol)
            }
            .opacity(canFocus && !session.presentation.isOutdated(player) ? 1 : MarkerStyle.playerSidebarDimmedOpacity)
            .help(help)
            Spacer(minLength: 0)
            VisibilityButton(isShown: visibility)
        }
        .tag(SidebarItem.player(player.uuid))
        .id(SidebarItem.player(player.uuid))
        .accessibilityElement(children: .combine)
        // Native rows combine their controls; keep the same command reachable by menu and VoiceOver.
        .contextMenu { VisibilityCommand(isShown: visibility) }
    }

    private var isShown: Bool { !session.visibility.hiddenPlayers.contains(player.uuid) }
    private var visibility: Binding<Bool> { Binding { isShown } set: { setShown($0) } }

    private func setShown(_ shown: Bool) {
        if shown { session.visibility.hiddenPlayers.remove(player.uuid) }
        else { session.visibility.hiddenPlayers.insert(player.uuid) }
    }

    private var canFocus: Bool {
        session.routing.canFocus(player)
    }

    private var detail: String {
        guard let position = PlayerPresentation.position(of: player) else { return String(localized: "Location unknown") }
        return Coordinates.text(CGPoint(x: position.x, y: position.z), dimension: session.presentation.dimensionName(position.dimension))
    }

    private var help: String {
        if session.presentation.isOutdated(player) {
            return String(localized: "This player hasn’t joined since the world was upgraded, so this is an old location.")
        }
        return canFocus ? String(localized: "Show this player’s details and center the map on their last location")
            : String(localized: "Show this player’s details")
    }
}

/// What the inspector beside the map shows.
private struct WorldInspector: View {
    let session: WorldSession

    var body: some View {
        switch session.selection.inspector {
        case .world?:
            WorldInfoView(session: session)
        case .storage?:
            StorageView(session: session)
        case .player(let id)?:
            if let player = session.players.first(where: { $0.uuid == id }) {
                PlayerDetailView(session: session, player: player)
                    .id(player.uuid)
            }
        case .selection?:
            switch session.selection.mapSelection {
            case .portal(let portal)?: PortalDetailView(session: session, portal: portal)
            case .creature(let creature)?: CreatureDetailView(session: session, marker: creature).id(creature.id)
            case .inGameMap(let item)?: InGameMapDetailView(session: session, map: item).id(item.id)
            case nil: EmptyView()
            }
        case nil:
            EmptyView()
        }
    }
}

/// Places matching the search, most items first. Choosing one shows it on the map.
private struct SearchResultsSection: View {
    let session: WorldSession

    var body: some View {
        let search = session.search
        Section {
            HitList(session: session, query: search.text)
        } header: {
            HStack {
                Text("Search Results")
                Spacer()
                Button("Save Search", systemImage: "plus.circle") { session.search.saveSearch() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(!session.search.canSaveSearch)
                    .help("Keep this search in the sidebar")
            }
        }
    }
}

/// Searches kept in the sidebar. Each lists its results when expanded and pins them on the map
/// while its eye is open.
private struct SavedSearchesSection: View {
    let session: WorldSession
    @Binding var expanded: Set<UUID>

    var body: some View {
        Section("Saved Searches") {
            ForEach(session.savedSearches.all) { saved in
                let hits = session.search.listedHits(for: saved.query, where: session.presentation.lists)
                let visibility = Binding {
                    session.savedSearches.all.first { $0.id == saved.id }?.isShown ?? false
                } set: { session.savedSearches.setShown(saved.id, $0) }
                DisclosureGroup(isExpanded: Binding {
                    expanded.contains(saved.id)
                } set: {
                    if $0 { expanded.insert(saved.id) } else { expanded.remove(saved.id) }
                }) {
                    HitList(session: session, query: saved.query)
                } label: {
                    HStack {
                        Label(session.search.isIndexing ? saved.query : "\(saved.query) (\(hits.total))", systemImage: "magnifyingglass")
                        Spacer()
                        VisibilityButton(isShown: visibility)
                    }
                }
                .contextMenu {
                    VisibilityCommand(isShown: visibility)
                    Divider()
                    Button("Search for This") { session.search.text = saved.query }
                    Button("Remove", role: .destructive) { session.savedSearches.remove(saved.id) }
                }
            }
        }
    }
}

/// A search's results; choosing one shows it on the map.
private struct HitList: View {
    let session: WorldSession
    let query: String
    var body: some View {
        let search = session.search
        let hits = session.search.listedHits(for: query, where: session.presentation.lists)
        if (search.isIndexing || search.isSearching) && hits.rows.isEmpty {
            Label {
                Text("Searching the world…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        } else if hits.rows.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        } else {
            ForEach(hits.rows) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.detail).lineLimit(2)
                    Text(location(hit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(SidebarItem.hit(query: query, id: hit.id))
                .id(SidebarItem.hit(query: query, id: hit.id))
                .selectionDisabled(hit.position == nil)
            }
            if hits.total > hits.rows.count {
                Text("Showing the first \(hits.rows.count) of \(hits.total)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func location(_ hit: SearchHit) -> String {
        guard let position = hit.position else { return hit.title }
        return "\(hit.title) · \(Coordinates.text(position))"
    }
}
