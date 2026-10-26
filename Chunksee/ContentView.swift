import ChunkseeKit
import ChunkseeIndex
import SwiftUI

struct WorldView: View {
    @Bindable var session: WorldSession
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sidebarDisclosure = SidebarDisclosure()
    /// A new request also reveals a selected row again after the user scrolls away or collapses it.
    @State private var sidebarRevealID = UUID()
    @State private var showsCoordinateSheet = false
    @State private var showsImageExport = false
    @State private var showsBlockFilter = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isSidebarFocused: Bool
    @State private var sidebarModifiers: EventModifiers = []

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
                        SearchResultsSection(session: session, isExpanded: sectionExpanded(.searchResults))
                    }
                    Section("World", isExpanded: sectionExpanded(.world)) {
                        Label("World Info", systemImage: WorldInfoView.symbol)
                            .tag(SidebarItem.worldInfo)
                            .help("Show the world’s settings, time, weather and game rules")
                        Label("Storage", systemImage: StorageView.symbol)
                            .tag(SidebarItem.storage)
                            .help("Show totals of the items stored in this dimension’s containers")
                        MapVisibilityRow(isShown: $heatMap.isShown) {
                            Label("Time Spent", systemImage: "clock.fill")
                        }
                        .help("Color the map by how long players spent near each chunk")
                        MapVisibilityRow(isShown: $slimeChunks.isShown) {
                            Label("Slime Chunks", systemImage: "square.grid.3x3.fill")
                        }
                        .disabled(!slimeChunks.isAvailable)
                        .help("Mark Overworld chunks where slimes can spawn below Y 40")
                        MapVisibilityRow(isShown: Binding {
                            session.map?.showsDarkSpots ?? false
                        } set: { session.setDarkSpots($0) }) {
                            Label("Dark Spots", systemImage: DarkSpots.symbol)
                        }
                        .disabled(session.map == nil)
                        .help(DarkSpots.explanation)
                        MapVisibilityRow(isShown: $visibility.showsGrid) {
                            Label("Grid", systemImage: "grid")
                        }
                        .help("Show block, chunk and region lines; block lines appear from \(ZoomPercentage.text(MapGrid.minimumBlockSpacing)) zoom")
                        MapVisibilityRow(isShown: session.presentation.limitedWorldBorder == nil ? .constant(false) : $visibility.showsWorldBorder) {
                            Label("World Border", systemImage: "square.dashed")
                        }
                        .disabled(session.presentation.limitedWorldBorder == nil)
                        .help("Show the saved world border when it is smaller than the default limit")
                    }
                    if !session.savedSearches.all.isEmpty {
                        SavedSearchesSection(session: session, isExpanded: sectionExpanded(.savedSearches),
                                             expanded: $sidebarDisclosure.savedSearches)
                    }
                    let index = session.presentation.selectedIndex
                    if !index.structures.isEmpty {
                        Section("Structures", isExpanded: sectionExpanded(.structures)) {
                            LayerGroups(session: session, markers: index.structures, origin: session.presentation.spawnPoint,
                                        shown: $visibility.structures, item: { SidebarItem.structure($0.id) },
                                        expandedGroups: $sidebarDisclosure.structures)
                        }
                    }
                    Section("Places", isExpanded: sectionExpanded(.places)) {
                        SavedPlacesGroup(session: session, isExpanded: $sidebarDisclosure.showsSavedPlaces)
                        LayerGroups(session: session, markers: index.places, origin: session.presentation.spawnPoint,
                                    shown: $visibility.places, item: { SidebarItem.place($0.id) },
                                    expandedGroups: $sidebarDisclosure.places)
                    }
                    if !index.creatures.isEmpty {
                        Section("Creatures", isExpanded: sectionExpanded(.creatures)) {
                            LayerGroups(session: session, markers: index.creatures, origin: session.presentation.spawnPoint,
                                        shown: $visibility.creatures, item: { SidebarItem.creature($0.id) },
                                        expandedGroups: $sidebarDisclosure.creatures)
                        }
                    }
                    // Every biome the dimension can have, once it's been read, so one not found yet shows 0.
                    if !index.biomeAreas.isEmpty || !session.presentation.possibleBiomes.isEmpty {
                        Section("Biomes", isExpanded: sectionExpanded(.biomes)) {
                            LayerGroups(session: session, markers: index.biomeAreas, origin: session.presentation.spawnPoint,
                                        shown: $visibility.biomes, allGroups: session.presentation.possibleBiomes,
                                        item: { SidebarItem.biome($0.id) }, expandedGroups: $sidebarDisclosure.biomes)
                        }
                    }
                    if !session.presentation.inGameMaps.isEmpty {
                        Section("In-Game Maps", isExpanded: sectionExpanded(.inGameMaps)) {
                            ForEach(session.presentation.inGameMaps, id: \.id) { map in
                                InGameMapRow(session: session, map: map)
                            }
                        }
                    }
                    if !session.presentation.listedPlayers.isEmpty {
                        Section("Players", isExpanded: sectionExpanded(.players)) {
                            if session.presentation.hasUnnamedPlayers {
                                SidebarActionRow(help: "Choose how Chunksee finds player names in Settings") {
                                    SettingsLink {
                                        Label("Find Player Names…", systemImage: "gearshape.fill")
                                    }
                                }
                            }
                            ForEach(session.presentation.listedPlayers, id: \.uuid) { player in
                                PlayerRow(session: session, player: player)
                            }
                        }
                    }
                }
                .focused($isSidebarFocused)
                .onModifierKeysChanged(mask: [.command, .shift, .control, .option]) { _, modifiers in
                    sidebarModifiers = modifiers
                }
                .environment(\.sidebarPlainClick, sidebarModifiers.isEmpty)
                // Clicking the selected row need not change the List binding, but must still
                // move keyboard input from the map to the sidebar. Keep native row/control actions.
                .simultaneousGesture(TapGesture().onEnded { isSidebarFocused = true })
                // A new dimension can receive its jump before this view appears.
                .onChange(of: session.selection.sidebarRevealRequest, initial: true) {
                    guard session.selection.sidebarRevealRequest != nil, let item = session.selection.sidebarSelection else { return }
                    withAnimation(.default, completionCriteria: .removed) {
                        sidebarDisclosure.reveal(item, in: session)
                    } completion: {
                        finishSidebarReveal(item)
                    }
                }
                .onChange(of: sidebarRevealID) {
                    if let item = session.selection.sidebarSelection { proxy.scrollTo(item, anchor: .center) }
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
                let content = MapContent(session: session)
                MapView(session: session, map: map, content: content, portalStatus: { session.presentation.linkStatus(for: $0) },
                        onSelect: selectOnMap)
                    .id(map.dimension.id)
                    .onChange(of: map.depth) { session.saveView() }
                    .onChange(of: map.style) { session.saveView() }
                    .onChange(of: map.blendsBiomeColors) { session.saveView() }
                    .onChange(of: map.lightingMode) { session.saveView() }
                    .onChange(of: map.castsShadows) { session.saveView() }
                    .onChange(of: map.blockFilter) { session.saveView() }
                    // Edit ▸ Copy copies the map as shown, while the map has focus.
                    .copyable([SharedMapImage { [session, colorScheme, locale, contrast] in MapImage.render(session: session, colorScheme: colorScheme, locale: locale, contrast: contrast) }])
                    // Remember the position a second after the map stops moving.
                    .task(id: map.viewport) {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { session.saveView() }
                    }
                    .modifier(MapLegendOverlay(layers: content))
                    .toolbar {
                        ToolbarItem {
                            Menu {
                                ShareLink(item: SharedMapImage { [session, colorScheme, locale, contrast] in MapImage.render(session: session, colorScheme: colorScheme, locale: locale, contrast: contrast) },
                                          preview: SharePreview(session.presentation.mapTitle(in: map.dimension.id, locale: locale), image: Image(systemName: ItemAppearance.mapSymbol))) {
                                    Text("Share Current View")
                                }
                                Button("Create Map Image…") { showsImageExport = true }
                            } label: {
                                Label("Share Map Image", systemImage: "square.and.arrow.up")
                            }
                            .help("Share the current view or create an image of a larger area")
                            .accessibilityIdentifier("map-share-menu")
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
        .sheet(isPresented: $showsImageExport) {
            MapExportView(session: session)
        }
        .sheet(isPresented: $showsBlockFilter) {
            if let map = session.map { MapBlockFilterView(session: session, map: map) }
        }
        .sheet(item: $annotations.draft) { draft in
            SavedPlaceEditor(session: session, draft: draft)
        }
        .sheet(item: $annotations.portalDraft) { draft in
            PortalPlanView(session: session, draft: draft)
        }
        .inspector(isPresented: inspectorShown) {
            WorldInspector(session: session)
                // Capped so a wide row can't push the inspector past the window's edge.
                .inspectorColumnWidth(min: 320, ideal: 340, max: 420)
        }
        .focusedSceneValue(\.worldSession, showsCoordinateSheet || showsImageExport || showsBlockFilter || annotations.draft != nil || annotations.portalDraft != nil ? nil : session)
        .focusedSceneValue(\.focusSearch, showsCoordinateSheet || showsImageExport || showsBlockFilter || annotations.draft != nil || annotations.portalDraft != nil ? nil : SearchFocusAction { isSearchFocused = true })
        .focusedSceneValue(\.coordinateSheet, $showsCoordinateSheet)
        .focusedSceneValue(\.mapImageSheet, $showsImageExport)
        .focusedSceneValue(\.mapBlockFilterSheet, $showsBlockFilter)
        .background { WorldKeyboardShortcuts(session: session) }
        .modifier(WorldGameAssets(world: session.resources))
    }

    /// Only input through the native List binding navigates and requests sidebar focus.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding { session.selection.sidebarSelection } set: { item in
            if item != nil { isSidebarFocused = true }
            session.selection.choose(item)
        }
    }

    private func selectOnMap(_ target: MapTarget?, y: Double?) {
        var selected: SidebarItem?
        withAnimation(.default, completionCriteria: .removed) {
            if sidebarDisclosure.selectOnMap(target, y: y, in: session) {
                selected = session.selection.sidebarSelection
            }
        } completion: {
            if let selected { finishSidebarReveal(selected) }
        }
    }

    private func finishSidebarReveal(_ item: SidebarItem) {
        // Expansion above the visible rows can preserve their scroll position. Reveal the
        // chosen row after that native adjustment, unless another action changed selection.
        guard !session.isClosed, session.selection.sidebarSelection == item else { return }
        sidebarRevealID = UUID()
    }

    private func sectionExpanded(_ section: SidebarSection) -> Binding<Bool> {
        Binding { !sidebarDisclosure.collapsedSections.contains(section) } set: {
            if $0 { sidebarDisclosure.collapsedSections.remove(section) }
            else { sidebarDisclosure.collapsedSections.insert(section) }
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
        let availability = session.routing.availability(of: player)
        let isOutdated = session.presentation.isOutdated(player)
        MapVisibilityRow(isShown: visibility) {
            LocationLabel(title: Text(session.presentation.name(of: player)),
                          isDimmed: !availability.canNavigate || isOutdated) {
                Image(systemName: MarkerStyle.playerAppearance(.player).symbol)
            }
            .repeatSidebarSelection(.player(player.uuid), in: session.selection)
        } commands: {
            if let location = PlayerPresentation.position(of: player) {
                LocationMenu(session: session, position: CGPoint(x: location.x, y: location.z),
                             dimension: location.dimension, y: location.y)
            }
        }
        .tag(SidebarItem.player(player.uuid))
        .id(SidebarItem.player(player.uuid))
        .help(help(availability: availability, isOutdated: isOutdated))
    }

    private var isShown: Bool { !session.visibility.hiddenPlayers.contains(player.uuid) }
    private var visibility: Binding<Bool> { Binding { isShown } set: { setShown($0) } }

    private func setShown(_ shown: Bool) {
        if shown { session.visibility.hiddenPlayers.remove(player.uuid) }
        else { session.visibility.hiddenPlayers.insert(player.uuid) }
    }

    private func help(availability: LocationAvailability, isOutdated: Bool) -> String {
        guard availability.canNavigate else { return availability.help }
        if isOutdated {
            return String(localized: "This player hasn’t joined since the world was upgraded, so this is an old location")
        }
        return String(localized: "Show this player’s details and center the map on their last location")
    }
}

/// Places matching the search, most items first. Choosing one shows it on the map.
private struct SearchResultsSection: View {
    let session: WorldSession
    @Binding var isExpanded: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let search = session.search
        let hits = search.listedHits(for: search.text, where: session.presentation.lists)
        Section(isExpanded: $isExpanded) {
            SidebarActionRow(help: "Keep this search in the sidebar") {
                Button("Save Search", systemImage: "plus.circle") { session.search.saveSearch() }
                    .disabled(!session.search.canSaveSearch)
            }
            HitList(session: session, query: search.text)
        } header: {
            Text(CountedText.label(String(localized: "Search Results", locale: locale),
                                  count: search.isIndexing || search.isSearching ? nil : hits.total,
                                  shown: hits.rows.count, locale: locale))
        }
    }
}

/// Searches kept in the sidebar. Each lists its results when expanded and pins them on the map
/// while its eye is open.
private struct SavedSearchesSection: View {
    let session: WorldSession
    @Binding var isExpanded: Bool
    @Binding var expanded: Set<UUID>
    @Environment(\.locale) private var locale

    var body: some View {
        Section("Saved Searches", isExpanded: $isExpanded) {
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
                    MapVisibilityRow(isShown: visibility) {
                        Label(CountedText.label(saved.query, count: session.search.isIndexing || session.search.isSearching ? nil : hits.total,
                                                shown: hits.rows.count, locale: locale), systemImage: "magnifyingglass")
                    } commands: {
                        Button("Search for This") { session.search.text = saved.query }
                        Button("Remove", role: .destructive) { session.savedSearches.remove(saved.id) }
                    }
                }
            }
        }
    }
}

/// A search's results; selection shares details and navigation with the item's other entry points.
private struct HitList: View {
    let session: WorldSession
    let query: String
    var body: some View {
        let search = session.search
        let hits = session.search.listedHits(for: query, where: session.presentation.lists)
        if (search.isIndexing || search.isSearching) && hits.rows.isEmpty {
            ProgressView("Searching the world…")
                .controlSize(.small)
                .foregroundStyle(.secondary)
        } else if hits.rows.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        } else {
            ForEach(hits.rows) { hit in
                let availability = session.routing.availability(of: hit.position.map { Coordinates($0, y: hit.y.map(Double.init)) },
                                                                in: hit.dimension)
                LocationLabel(title: Text(hit.title), isDimmed: !availability.canNavigate) {
                    Image(systemName: MarkerStyle.search.symbol.name)
                }
                .tag(SidebarItem.hit(query: query, id: hit.id))
                .repeatSidebarSelection(.hit(query: query, id: hit.id), in: session.selection)
                .id(SidebarItem.hit(query: query, id: hit.id))
                .help(help(for: hit, availability: availability))
                .locationMenu(session: session, position: hit.position, dimension: hit.dimension,
                              y: hit.y.map(Double.init))
            }
        }
    }

    private func help(for hit: SearchHit, availability: LocationAvailability) -> String {
        if case .enderChest = hit.source {
            return String(localized: "Show this player’s details; an Ender Chest has no single location")
        }
        return availability.help
    }
}
