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
    /// Worlds can hold dozens of maps, so the list starts collapsed.
    @State private var showsInGameMaps = false

    var body: some View {
        @Bindable var visibility = session.visibility
        @Bindable var search = session.search
        @Bindable var heatMap = session.heatMap
        NavigationSplitView {
            List(selection: $session.selectedDimensionID) {
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
                    .keyboardShortcut("i")
                    .help("Show the world’s settings, time, weather and game rules")
                    Toggle(isOn: $heatMap.isShown) {
                        Label("Time Spent", systemImage: "flame")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Color the map by how long players spent near each chunk")
                }
                Section("Dimensions") {
                    ForEach(session.dimensions, id: \.id) { dimension in
                        Label(dimension.displayName, systemImage: symbol(for: dimension.id))
                    }
                }
                if let map = session.map {
                    LayerSection(title: "Structures", markers: map.structures, origin: session.spawnPoint,
                                 shown: $visibility.structures) { session.center(on: $0.position) }
                    LayerSection(title: "Places", markers: map.places, origin: session.spawnPoint,
                                 shown: $visibility.places) { place in
                        if let portal = place.portal { session.show(portal) } else { session.center(on: place.position) }
                    }
                    LayerSection(title: "Creatures", markers: map.creatures, origin: session.spawnPoint,
                                 shown: $visibility.creatures) { creature in
                        session.center(on: creature.position)
                        session.selection = .creature(creature)
                    }
                    LayerSection(title: "Biomes", markers: map.biomeAreas, origin: session.spawnPoint,
                                 shown: $visibility.biomes) { session.center(on: $0.position) }
                }
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
                MapView(map: map, content: session.mapContent, portalStatus: { session.linkStatus(for: $0) },
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
                    .inspector(isPresented: inspectorShown) {
                        Group {
                            switch session.inspector {
                            case .world?:
                                WorldInfoView(session: session)
                            case .player(let id)?:
                                if let player = session.players.first(where: { $0.uuid == id }) {
                                    PlayerDetailView(session: session, player: player)
                                }
                            case nil:
                                EmptyView()
                            }
                        }
                        // Capped so a wide row can't push the inspector past the window's edge.
                        .inspectorColumnWidth(min: 320, ideal: 340, max: 420)
                    }
                    .navigationTitle(session.displayName)
                    .navigationSubtitle(map.dimension.displayName)
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
                    Label(filter.prompt, systemImage: filter.symbol).searchCompletion(filter.rawValue + ":")
                }
            }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding { session.inspector != nil } set: { if !$0 { session.inspector = nil } }
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
                !session.visibility.hiddenPlayers.contains(player.uuid)
            } set: {
                if $0 { session.visibility.hiddenPlayers.remove(player.uuid) } else { session.visibility.hiddenPlayers.insert(player.uuid) }
            })
            Button("Show Details", systemImage: "info.circle") {
                session.inspector = session.inspector == .player(player.uuid) ? nil : .player(player.uuid)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(session.inspector == .player(player.uuid) ? Color.accentColor : .secondary)
            .help("Show inventory, health and experience")
        }
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
            if search.isIndexing {
                Label {
                    Text("Searching the world…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            } else if search.results.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            } else {
                ForEach(search.results.prefix(200)) { hit in
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
                if search.results.count > 200 {
                    Text("Showing the first 200 of \(search.results.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Search Results")
        }
    }

    private func location(_ hit: SearchHit) -> String {
        guard let dimension = hit.dimension, let position = hit.position else { return hit.title }
        return "\(hit.title) · \(session.dimensionName(dimension))  \(Coordinates.text(position))"
    }
}
