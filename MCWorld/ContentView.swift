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
                MapView(map: map, structures: session.visibleStructures, places: session.visiblePlaces, markers: session.markers)
                    .id(map.dimension.id)
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
