import ChunkseeIndex
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

    var heightRange: ClosedRange<Int>? {
        guard let source, let id = source.selectedDimensionID else { return nil }
        return source.details.dimensionSettings[id]?.type?.buildRange
    }

    /// Map controls and drawing share availability; the default border has no practical limit.
    var limitedWorldBorder: WorldBorder? {
        guard let source, !source.isClosed, source.map != nil, let id = source.selectedDimensionID,
              let border = source.details.borders[id], border.isLimited else { return nil }
        return border
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
        dimensionNameStyle.format(id)
    }

    /// Shared images and accessibility identify both the dimension and the world it belongs to.
    func mapTitle(in dimensionID: String, locale: Locale) -> String {
        let dimension = dimensionNameStyle.locale(locale).format(dimensionID)
        return String(localized: "Map of \(dimension) in \(displayName)", locale: locale)
    }

    var dimensionNameStyle: NameStyle {
        NameStyle(dimensionIDs: source?.dimensions.map(\.id) ?? [])
    }

    /// Immutable naming context derived from the live catalog, without retaining the document.
    nonisolated struct NameStyle: FormatStyle, Sendable {
        private let dimensionIDs: [String]
        private var locale = Locale.autoupdatingCurrent

        init(dimensionIDs: [String]) { self.dimensionIDs = dimensionIDs }

        func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        func format(_ id: String) -> String {
            let name = name(id)
            let isAmbiguous = dimensionIDs.contains { $0 != id && self.name($0) == name }
            return isAmbiguous ? String(localized: "\(name) (\(id))", locale: locale) : name
        }

        private func name(_ id: String) -> String {
            switch id {
            case "minecraft:overworld": String(localized: "Overworld", locale: locale)
            case "minecraft:the_nether": String(localized: "The Nether", locale: locale)
            case "minecraft:the_end": String(localized: "The End", locale: locale)
            default: ReadableName.from(id)
            }
        }
    }

    var spawnPoint: CGPoint {
        guard let source else { return .zero }
        return Self.spawnPoint(in: source.world, dimensionID: source.selectedDimensionID)
    }

    var worldSpawn: MapDestination? {
        guard let source else { return nil }
        return Self.worldSpawn(in: source.world)
    }

    /// Initial placement, distance sorting and both spawn controls consume this same destination.
    private static func worldSpawn(in world: World) -> MapDestination? {
        guard let spawn = world.level.spawnPosition, let dimension = world.level.spawnDimension else { return nil }
        return MapDestination(coordinates: Coordinates(CGPoint(x: spawn.x, y: spawn.z), y: spawn.y),
                              dimension: dimension, isBlockPosition: true)
    }

    /// The world's spawn in this dimension, otherwise the origin, shared with initial map placement.
    static func spawnPoint(in world: World, dimensionID: String?) -> CGPoint {
        guard let spawn = worldSpawn(in: world), spawn.dimension == dimensionID else { return .zero }
        return spawn.anchor
    }

    var drawnPlayerMarkers: [MapMarker] {
        guard let source, source.map != nil, let id = source.selectedDimensionID else { return [] }
        return PlayerPresentation.markers(for: source.players.filter { !source.visibility.hiddenPlayers.contains($0.uuid) }, in: id,
                                          singleplayerUUID: source.world.level.singleplayerUUID,
                                          worldDataVersion: source.world.level.dataVersion) { [names = source.names] in names.name(for: $0) }
    }

    /// Every indexed portal in the Overworld and Nether, using SearchModel's shared publications.
    var portalsByDimension: [String: [NetherPortal]] { source?.search.portals ?? [:] }

    func isWaitingForPortalLink(_ portal: NetherPortal) -> Bool {
        guard let source, !source.isClosed, let target = NetherPortal.targetDimension(from: portal.dimension) else { return false }
        return source.resources.index.isWaitingForPortals(in: target) ||
            source.resources.index.isWaitingForPortals(in: portal.dimension)
    }

    func roundTrip(for portal: NetherPortal) -> NetherPortal.RoundTrip? {
        PortalLinkStatus.roundTrip(of: portal, portals: portalsByDimension)
    }

    func linkStatus(for portal: NetherPortal) -> PortalLinkStatus? {
        PortalLinkStatus.status(of: portal, portals: portalsByDimension)
    }

    var inGameMaps: [MapItem] {
        source?.details.maps.filter { lists($0.dimension) } ?? []
    }

    func canShow(_ map: MapItem) -> Bool {
        source?.routing.canFocus(Coordinates(CGPoint(x: map.centerX, y: map.centerZ)), in: map.dimension) ?? false
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

    /// Owned pets elsewhere need links; pets on this player's shoulders already show full details.
    func linkedPets(to playerID: UUID) -> [CreatureMarker] {
        guard let source else { return [] }
        return source.search.index.creatures.map(\.value).filter { $0.creature.owner == playerID && $0.carrier != playerID }
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
