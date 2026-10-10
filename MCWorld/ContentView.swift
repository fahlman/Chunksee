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
            List(selection: $session.selectedDimensionID) {
                if !session.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsSection(session: session)
                }
                Section("Dimensions") {
                    ForEach(session.dimensions, id: \.id) { dimension in
                        Label(dimension.displayName, systemImage: symbol(for: dimension.id))
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
                MapView(map: map, structures: session.visibleStructures, places: session.visiblePlaces,
                        selectedPortal: session.selectedPortal, portalStatus: { session.linkStatus(for: $0) },
                        hits: session.visibleHits, selectedHitID: session.selectedHitID,
                        onSelectPortal: { session.selectedPortal = $0 }, markers: session.markers)
                    .id(map.dimension.id)
                    .overlay(alignment: .topLeading) {
                        if let portal = session.selectedPortal {
                            PortalCard(session: session, portal: portal)
                                .padding(10)
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            LayerMenu(title: "Structures", systemImage: "building.columns",
                                      help: "Choose which structures appear on the map",
                                      empty: "No structures found in explored areas",
                                      groups: map.structures.map(\.group), shown: $session.shownStructureGroups)
                        }
                        ToolbarItem {
                            LayerMenu(title: "Places", systemImage: "mappin.and.ellipse",
                                      help: "Choose which places (portals, bells, beds, workstations…) appear on the map",
                                      empty: "No places recorded in this dimension",
                                      groups: map.places.map(\.group), shown: $session.shownPlaceGroups)
                        }
                        ToolbarItem {
                            Toggle("Show Players", systemImage: "person.2", isOn: $session.showsPlayers)
                                .help("Show players, their last deaths and respawn points on the map")
                        }
                    }
                    .navigationTitle(session.displayName)
                    .navigationSubtitle(map.dimension.displayName)
            } else {
                ContentUnavailableView("No Dimensions", systemImage: "questionmark.folder",
                                       description: Text("This world has no saved terrain yet."))
            }
        }
        .searchable(text: $session.searchText, placement: .toolbar, prompt: Text("Find items, signs and books"))
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
        let dimension = session.dimensions.first { $0.id == position.dimension }?.displayName ?? position.dimension
        return "\(dimension)  X \(Int(position.x.rounded(.down)))  Z \(Int(position.z.rounded(.down)))"
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

/// A group of map markers that a toolbar menu can show or hide.
protocol MapLayerGroup: CaseIterable, Hashable {
    var name: String { get }
    var symbol: String { get }
}

extension StructureGroup: MapLayerGroup {}
extension PlaceGroup: MapLayerGroup {}

/// Chooses which groups of markers the map shows. Lists only groups present, with their counts.
private struct LayerMenu<Group: MapLayerGroup>: View where Group.AllCases: RandomAccessCollection {
    let title: LocalizedStringKey
    let systemImage: String
    let help: LocalizedStringKey
    let empty: LocalizedStringKey
    let groups: [Group]
    @Binding var shown: Set<Group>

    var body: some View {
        let counts = Dictionary(grouping: groups, by: { $0 }).mapValues(\.count)
        Menu {
            if counts.isEmpty {
                Text(empty)
            } else {
                ForEach(Group.allCases.filter { counts[$0] != nil }, id: \.self) { group in
                    Toggle(isOn: Binding(
                        get: { shown.contains(group) },
                        set: { if $0 { shown.insert(group) } else { shown.remove(group) } }
                    )) {
                        Label("\(group.name) (\(counts[group] ?? 0))", systemImage: group.symbol)
                    }
                }
                Divider()
                Button("Show All") { shown.formUnion(counts.keys) }
                Button("Hide All") { shown.subtract(counts.keys) }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .help(help)
    }
}

/// Where the selected Nether portal leads, and whether the link goes both ways.
private struct PortalCard: View {
    let session: WorldSession
    let portal: NetherPortal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Nether Portal", systemImage: "oval.portrait.fill").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { session.selectedPortal = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text("X \(Int(portal.centerX.rounded(.down)))  Y \(portal.minY)  Z \(Int(portal.centerZ.rounded(.down)))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider()
            switch session.link(for: portal) {
            case .portal(let target, _)?:
                Text("Leads to the portal in \(dimensionName(target.dimension)) at X \(Int(target.centerX.rounded(.down))), Z \(Int(target.centerZ.rounded(.down))).")
                if session.linkStatus(for: portal) == .oneWay, case .portal(let back, _)? = session.link(for: target) {
                    Label("One-way: that portal leads back to a different one, at X \(Int(back.centerX.rounded(.down))), Z \(Int(back.centerZ.rounded(.down))).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("Show the Other Side") { session.show(target) }
            case .wouldCreateNewPortal(let destination)?:
                Label("No portal in \(dimensionName(NetherPortal.targetDimension(from: portal.dimension) ?? "")) is close enough. Going through would make the game build a new one near X \(destination.x), Z \(destination.z).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case nil:
                ProgressView().controlSize(.small)
            }
            Text("Predicted with Minecraft’s linking rule from the portal’s bottom center.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func dimensionName(_ id: String) -> String {
        session.dimensions.first { $0.id == id }?.displayName ?? id
    }
}

/// Places matching the search, most items first. Choosing one shows it on the map.
private struct SearchResultsSection: View {
    let session: WorldSession

    var body: some View {
        Section {
            if session.isIndexing {
                Label {
                    Text("Searching every container and sign…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            } else if session.searchResults.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            } else {
                ForEach(session.searchResults.prefix(200)) { hit in
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
                    .listRowBackground(hit.id == session.selectedHitID ? Color.yellow.opacity(0.25) : nil)
                }
                if session.searchResults.count > 200 {
                    Text("Showing the first 200 of \(session.searchResults.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Search Results")
        }
    }

    private func location(_ hit: SearchHit) -> String {
        guard let dimension = hit.dimension, let position = hit.position else { return hit.title }
        let name = session.dimensions.first { $0.id == dimension }?.displayName ?? dimension
        return "\(hit.title) · \(name) X \(Int(position.x.rounded(.down))) Z \(Int(position.y.rounded(.down)))"
    }
}
