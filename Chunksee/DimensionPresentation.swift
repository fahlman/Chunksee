import CoreGraphics
import Foundation
import ChunkseeKit

/// Read-only labels and listing rules for one document, derived from its existing data owners.
final class DimensionPresentation {
    private weak var source: WorldSession?

    init(source: WorldSession) { self.source = source }

    var selectedDimension: ChunkseeKit.Dimension? {
        guard let source else { return nil }
        return source.dimensions.first { $0.id == source.selectedDimensionID }
    }

    var displayName: String {
        guard let source else { return "" }
        return source.world.level.name ?? source.url.lastPathComponent
    }

    var selectedIndex: DimensionIndex {
        guard let source, let id = source.selectedDimensionID else { return DimensionIndex() }
        return source.search.index.dimensions[id] ?? DimensionIndex()
    }

    /// An entirely legacy dimension has no drawable terrain; mixed dimensions show readable chunks.
    var isSavedBeforeReadableFormat: Bool {
        guard let source else { return false }
        return (source.world.level.dataVersion ?? 0) < DataVersion.flatChunkRoot || selectedIndex.formats.isOnlyLegacy
    }

    /// Do not list unread or unsupported biome data as known-empty.
    var possibleBiomes: [BiomeGroup] {
        guard let source, !isSavedBeforeReadableFormat, let dimension = selectedDimension,
              source.search.index.dimensions[dimension.id] != nil else { return [] }
        return dimension.vanillaBiomes.map(BiomeGroup.init(id:))
    }

    func dimensionName(_ id: String) -> String {
        let name = Self.dimensionName(id)
        let isAmbiguous = source?.dimensions.contains { $0.id != id && Self.dimensionName($0.id) == name } ?? false
        return isAmbiguous ? String(localized: "\(name) (\(id))") : name
    }

    private static func dimensionName(_ id: String) -> String {
        switch id {
        case "minecraft:overworld": String(localized: "Overworld")
        case "minecraft:the_nether": String(localized: "The Nether")
        case "minecraft:the_end": String(localized: "The End")
        default: ReadableName.from(id)
        }
    }

    var spawnPoint: CGPoint {
        guard let source else { return .zero }
        return Self.spawnPoint(in: source.world, dimensionID: source.selectedDimensionID)
    }

    /// The world's spawn in this dimension, otherwise the origin, shared with initial map placement.
    static func spawnPoint(in world: World, dimensionID: String?) -> CGPoint {
        guard let spawn = world.level.spawnPosition,
              world.level.spawnDimension == dimensionID else { return .zero }
        return MapCoordinates.center(of: CGPoint(x: spawn.x, y: spawn.z))
    }

    var drawnPlayerMarkers: [MapMarker] {
        guard let source, source.map != nil, let id = source.selectedDimensionID else { return [] }
        return PlayerPresentation.markers(for: source.players.filter { !source.visibility.hiddenPlayers.contains($0.uuid) }, in: id,
                                          singleplayerUUID: source.world.level.singleplayerUUID,
                                          worldDataVersion: source.world.level.dataVersion) { [names = source.names] in names.name(for: $0) }
    }

    /// Every indexed portal in the Overworld and Nether, using SearchModel's shared publications.
    var portalsByDimension: [String: [NetherPortal]] { source?.search.portals ?? [:] }

    func link(for portal: NetherPortal) -> NetherPortal.Link? {
        guard let target = NetherPortal.targetDimension(from: portal.dimension),
              let candidates = portalsByDimension[target] else { return nil }
        return portal.link(into: candidates)
    }

    func isWaitingForPortalLink(_ portal: NetherPortal) -> Bool {
        guard let source, !source.isClosed, let target = NetherPortal.targetDimension(from: portal.dimension) else { return false }
        return source.resources.index.isWaitingForPortals(in: target)
    }

    func linkStatus(for portal: NetherPortal) -> PortalLinkStatus? {
        PortalLinkStatus.status(of: portal, portals: portalsByDimension)
    }

    var inGameMaps: [MapItem] {
        source?.details.maps.filter { lists($0.dimension) } ?? []
    }

    func canShow(_ map: MapItem) -> Bool {
        source?.dimensions.contains { $0.id == map.dimension } ?? false
    }

    func name(of player: PlayerInfo) -> String {
        PlayerPresentation.name(of: player, singleplayerUUID: source?.world.level.singleplayerUUID,
                                knownName: source?.names.name(for: player.uuid))
    }

    func name(ofPlayerWith uuid: UUID) -> String {
        if let player = source?.players.first(where: { $0.uuid == uuid }) { return name(of: player) }
        return PlayerPresentation.absentPlayerName(uuid, knownName: source?.names.name(for: uuid))
    }

    /// Each dimension lists its own records; missing/unavailable dimensions use the first dimension.
    func lists(_ dimension: String?) -> Bool {
        guard let source, let id = source.selectedDimensionID else { return false }
        if let dimension, source.dimensions.contains(where: { $0.id == dimension }) { return dimension == id }
        return id == source.dimensions.first?.id
    }

    var listedPlayers: [PlayerInfo] {
        source?.players.filter { lists(PlayerPresentation.position(of: $0)?.dimension) } ?? []
    }

    /// Current indexed pets match their saved owner UUID, across this world's dimensions.
    func linkedPets(to playerID: UUID) -> [CreatureMarker] {
        guard let source else { return [] }
        return source.search.index.creatures.map(\.value).filter { $0.creature.owner == playerID }
            .sorted { ($0.dimension, $0.name, $0.id) < ($1.dimension, $1.name, $1.id) }
    }

    var hasUnnamedPlayers: Bool {
        guard let source else { return false }
        return source.players.contains { source.names.name(for: $0.uuid) == nil }
    }

    func isOutdated(_ player: PlayerInfo) -> Bool {
        PlayerPresentation.isOutdated(player, worldDataVersion: source?.world.level.dataVersion)
    }
}
