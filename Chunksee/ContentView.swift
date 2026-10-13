import ChunkseeKit
import SwiftUI

struct WorldView: View {
    @Bindable var session: WorldSession
    /// Worlds can hold dozens of maps, so the list starts collapsed.
    @State private var showsInGameMaps = false

    var body: some View {
        @Bindable var visibility = session.visibility
        @Bindable var search = session.search
        @Bindable var heatMap = session.heatMap
        NavigationSplitView {
            List {
                if search.isActive {
                    SearchResultsSection(session: session)
                }
                Section("World") {
                    Button {
                        session.inspector = session.inspector == .world ? nil : .world
                    } label: {
                        Label("World Info", systemImage: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.inspector == .world ? Color.accentColor : .primary)
                    .help("Show the world’s settings, time, weather and game rules")
                    Button {
                        session.inspector = session.inspector == .storage ? nil : .storage
                    } label: {
                        Label("Storage", systemImage: "shippingbox")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.inspector == .storage ? Color.accentColor : .primary)
                    .help("Show totals of the items stored in this dimension’s containers")
                    Toggle(isOn: $heatMap.isShown) {
                        Label("Time Spent", systemImage: "flame")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Color the map by how long players spent near each chunk")
                    Toggle(isOn: $visibility.showsGrid) {
                        Label("Grid", systemImage: "grid")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show block, chunk and region lines; block lines appear from 8× zoom")
                }
                if !session.savedSearches.all.isEmpty {
                    SavedSearchesSection(session: session)
                }
                SavedPlacesSection(session: session)
                let index = session.selectedIndex
                LayerSection(title: "Structures", markers: index.structures, origin: session.spawnPoint,
                             shown: $visibility.structures) { session.center(on: $0.position) }
                LayerSection(title: "Places", markers: index.places, origin: session.spawnPoint,
                             shown: $visibility.places) { place in
                    if let portal = place.portal { session.show(portal) } else { session.center(on: place.position) }
                }
                LayerSection(title: "Creatures", markers: index.creatures, origin: session.spawnPoint,
                             shown: $visibility.creatures) { creature in
                    session.center(on: creature.position)
                    session.selection = .creature(creature)
                }
                LayerSection(title: "Biomes", markers: index.biomeAreas, origin: session.spawnPoint,
                             shown: $visibility.biomes) { session.center(on: $0.position) }
                if !session.inGameMaps.isEmpty {
                    Section("In-Game Maps", isExpanded: $showsInGameMaps) {
                        ForEach(session.inGameMaps, id: \.id) { map in
                            InGameMapRow(session: session, map: map)
                        }
                    }
                }
                if !session.players.isEmpty {
                    Section("Players") {
                        ForEach(session.players, id: \.uuid) { player in
                            PlayerRow(session: session, player: player)
                        }
                        // A row rather than a section footer: sidebar lists don't show footers.
                        if session.hasUnnamedPlayers {
                            SettingsLink {
                                Label("Find Player Names…", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            // Names come from the chosen Minecraft folder and, when allowed, from Mojang; look again
            // whenever either setting changes.
            .task(id: NameSources(folder: session.names.minecraftFolder, online: session.names.looksUpOnline)) {
                await session.names.reloadLocal()
                await session.names.lookUp(session.players.filter(PlayerPresentation.isMappable).map(\.uuid))
            }
        } detail: {
            if let map = session.map {
                MapView(session: session, map: map, content: session.mapContent, portalStatus: { session.linkStatus(for: $0) },
                        onSelect: { session.mapClicked($0) })
                    .id(map.dimension.id)
                    // Remember the position a second after the map stops moving.
                    .task(id: map.viewport) {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { session.saveView() }
                    }
                    .overlay(alignment: .topLeading) {
                        Group {
                            switch session.selection {
                            case .portal(let portal)?: PortalCard(session: session, portal: portal)
                            case .creature(let creature)?: CreatureCard(session: session, marker: creature)
                            case .inGameMap(let item)?: InGameMapCard(session: session, map: item)
                            case nil: EmptyView()
                            }
                        }
                        .padding(10)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if heatMap.isShown {
                            HeatMapLegend(isLoading: heatMap.isLoading)
                                .padding(10)
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            ShareLink(item: SharedMapImage { [session] in session.renderMapImage() },
                                      preview: SharePreview("Map of \(session.displayName)", image: Image(systemName: "map"))) {
                                Label("Share Map Image", systemImage: "square.and.arrow.up")
                            }
                            .help("Share an image of the map as shown")
                        }
                    }
                    // The document's folder names the window, so the subtitle names the world.
                    .navigationSubtitle(session.displayName)
            } else {
                ContentUnavailableView("No Dimensions", systemImage: "questionmark.folder",
                                       description: Text("This world has no saved terrain yet."))
            }
        }
        .searchable(text: $search.text, placement: .toolbar, prompt: Text("Find items, signs and pets"))
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
        .sheet(isPresented: $session.showsCoordinateSheet) {
            GoToCoordinatesView(session: session)
        }
        .sheet(item: $session.placeDraft) { draft in
            SavedPlaceEditor(session: session, draft: draft)
        }
        .inspector(isPresented: inspectorShown) {
            Group {
                switch session.inspector {
                case .world?:
                    WorldInfoView(session: session)
                case .storage?:
                    StorageView(session: session)
                case .player(let id)?:
                    if let player = session.players.first(where: { $0.uuid == id }) {
                        PlayerDetailView(session: session, player: player)
                            .id(player.uuid)
                    }
                case nil:
                    EmptyView()
                }
            }
            // Capped so a wide row can't push the inspector past the window's edge.
            .inspectorColumnWidth(min: 320, ideal: 340, max: 420)
        }
        .focusedSceneValue(\.worldSession, session.showsCoordinateSheet || session.placeDraft != nil ? nil : session)
        .background { WorldKeyboardShortcuts(session: session) }
    }

    private var inspectorShown: Binding<Bool> {
        Binding { session.inspector != nil } set: {
            if !$0 { session.inspector = nil }
            else if session.inspector == nil { session.inspector = .world }
        }
    }

}

/// A player in the sidebar. Choosing one shows their last position on the map.
private struct PlayerRow: View {
    let session: WorldSession
    let player: PlayerInfo

    var body: some View {
        HStack {
            Button {
                if let position = player.position { session.focus(on: position) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name(of: player))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.fill")
                }
            }
            .buttonStyle(.plain)
            .disabled(!canFocus)
            .opacity(canFocus && !session.isOutdated(player) ? 1 : 0.6)
            .help(help)
            Spacer(minLength: 0)
            VisibilityButton(isShown: Binding {
                isShown
            } set: { setShown($0) })
            Button("Show Details", systemImage: "info.circle") {
                toggleDetails()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(session.inspector == .player(player.uuid) ? Color.accentColor : .secondary)
            .help("Show inventory, health and experience")
        }
        .accessibilityElement(children: .combine)
        // Native sidebar rows combine their controls. Their context menu keeps each action reachable.
        .contextMenu {
            Button(isShown ? "Hide from Map" : "Show on Map") { setShown(!isShown) }
            Button(session.inspector == .player(player.uuid) ? "Hide Details" : "Show Details") { toggleDetails() }
        }
    }

    private var isShown: Bool { !session.visibility.hiddenPlayers.contains(player.uuid) }

    private func setShown(_ shown: Bool) {
        if shown { session.visibility.hiddenPlayers.remove(player.uuid) }
        else { session.visibility.hiddenPlayers.insert(player.uuid) }
    }

    private func toggleDetails() {
        session.inspector = session.inspector == .player(player.uuid) ? nil : .player(player.uuid)
    }

    private var canFocus: Bool {
        guard PlayerPresentation.isMappable(player), let position = player.position else { return false }
        return session.dimensions.contains { $0.id == position.dimension }
    }

    private var detail: String {
        if player.isFromBukkitServer {
            if let world = player.bukkitWorldName { return String(localized: "May be in another world, “\(world)”") }
            return String(localized: "May be in another world")
        }
        guard let position = player.position else { return String(localized: "Location unknown") }
        return session.dimensionName(position.dimension) + "  " + Coordinates.text(x: position.x, z: position.z)
    }

    private var help: String {
        if player.isFromBukkitServer {
            return String(localized: "This player’s file came from a server with several worlds, so this location may not be in this world.")
        }
        if session.isOutdated(player) {
            return String(localized: "This player hasn’t joined since the world was upgraded, so this is an old location.")
        }
        return String(localized: "Show on the map")
    }
}

private struct NameSources: Equatable {
    var folder: URL?
    var online: Bool
}

/// Places matching the search, most items first. Choosing one shows it on the map.
private struct SearchResultsSection: View {
    let session: WorldSession

    var body: some View {
        let search = session.search
        Section {
            HitList(session: session, hits: search.results)
        } header: {
            HStack {
                Text("Search Results")
                Spacer()
                Button("Save Search", systemImage: "plus.circle") { session.saveSearch() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(session.savedSearches.contains(search.text.trimmingCharacters(in: .whitespaces)))
                    .help("Keep this search in the sidebar")
            }
        }
    }
}

/// Searches kept in the sidebar. Each lists its results when expanded and pins them on the map
/// while its eye is open.
private struct SavedSearchesSection: View {
    let session: WorldSession

    var body: some View {
        Section("Saved Searches") {
            ForEach(session.savedSearches.all) { saved in
                let hits = session.search.results(for: saved.query)
                DisclosureGroup {
                    HitList(session: session, hits: hits)
                } label: {
                    HStack {
                        Label(session.search.isIndexing ? saved.query : "\(saved.query) (\(hits.count))", systemImage: "magnifyingglass")
                        Spacer()
                        VisibilityButton(isShown: Binding {
                            saved.isShown
                        } set: {
                            session.savedSearches.setShown(saved.id, $0)
                        })
                    }
                }
                .contextMenu {
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
    let hits: [SearchHit]

    var body: some View {
        let search = session.search
        if (search.isIndexing || search.isSearching) && hits.isEmpty {
            Label {
                Text("Searching the world…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        } else if hits.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        } else {
            ForEach(hits.prefix(200)) { hit in
                Button {
                    session.show(hit)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.detail).lineLimit(2)
                        Text(location(hit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(hit.position == nil)
                .padding(.vertical, 2)
                .listRowBackground(hit.id == search.selectedHitID ? Color.yellow.opacity(0.25) : nil)
            }
            if hits.count > 200 {
                Text("Showing the first 200 of \(hits.count)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func location(_ hit: SearchHit) -> String {
        guard let dimension = hit.dimension, let position = hit.position else { return hit.title }
        return "\(hit.title) · \(session.dimensionName(dimension))  \(Coordinates.text(position))"
    }
}
