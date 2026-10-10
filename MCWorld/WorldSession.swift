import CoreGraphics
import Foundation
import MCWorldKit
import Observation

/// The world the user opened, and the security-scoped access that lets the sandboxed app read it.
@Observable
final class WorldSession {
    let url: URL
    let world: World
    let dimensions: [MCWorldKit.Dimension]
    var selectedDimensionID: String? {
        didSet { if oldValue != selectedDimensionID { makeMapForSelection() } }
    }
    private(set) var map: MapModel?
    /// Players with saved data, most recently saved first.
    let players: [PlayerInfo]
    var showsPlayers = true
    /// App-wide player names, shared across worlds.
    let names: PlayerNames

    private let isAccessingSecurityScope: Bool

    private init(url: URL, world: World, players: [PlayerInfo], names: PlayerNames, isAccessingSecurityScope: Bool) {
        self.url = url
        self.names = names
        self.world = world
        self.players = players
        self.dimensions = world.dimensions()
        self.isAccessingSecurityScope = isAccessingSecurityScope
        self.selectedDimensionID = dimensions.first?.id
        makeMapForSelection()
        Self.maintainTileCache(forWorldAt: url)
    }

    /// The tile cache is limited to about 1 GB across all worlds; the least recently opened worlds'
    /// tiles go first, never the one being opened.
    private static func maintainTileCache(forWorldAt url: URL) {
        guard let root = TileCache.root, let worldFolder = TileCache.worldFolder(forWorldAt: url) else { return }
        Task.detached(priority: .background) {
            TileCache.markUsed(worldFolder: worldFolder)
            TileCache.prune(root: root, limit: 1 << 30, keeping: worldFolder)
        }
    }

    /// Opens a world folder. `url` must come from the Open panel or a resolved bookmark.
    static func open(_ url: URL, names: PlayerNames) async throws -> WorldSession {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let (world, players) = try await load(url)
            return WorldSession(url: url, world: world, players: players, names: names, isAccessingSecurityScope: accessing)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Reading `level.dat`, listing dimensions and reading player files touches the disk, so it
    /// runs off the main actor.
    @concurrent
    private nonisolated static func load(_ url: URL) async throws -> (World, [PlayerInfo]) {
        do {
            let world = try World(contentsOf: url)
            return (world, world.players())
        } catch WorldError.missingLevelDat {
            throw WorldOpenError.notAWorld
        } catch {
            throw WorldOpenError.unreadable
        }
    }

    var displayName: String { world.level.name ?? url.lastPathComponent }

    func name(of player: PlayerInfo) -> String {
        PlayerPresentation.name(of: player, singleplayerUUID: world.level.singleplayerUUID, knownName: names.name(for: player.uuid))
    }

    /// Whether any player still has no real name.
    var hasUnnamedPlayers: Bool { players.contains { names.name(for: $0.uuid) == nil } }

    func isOutdated(_ player: PlayerInfo) -> Bool {
        PlayerPresentation.isOutdated(player, worldDataVersion: world.level.dataVersion)
    }

    /// Player, death and respawn markers for the selected dimension, when players are shown.
    var markers: [MapMarker] {
        guard showsPlayers, let id = selectedDimensionID else { return [] }
        let names = names
        return PlayerPresentation.markers(for: players, in: id, singleplayerUUID: world.level.singleplayerUUID,
                                          worldDataVersion: world.level.dataVersion, knownName: { names.name(for: $0) })
    }

    /// Shows a location: switches to its dimension if needed and centers the map on it.
    func focus(on location: PlayerInfo.Location) {
        guard dimensions.contains(where: { $0.id == location.dimension }) else { return }
        selectedDimensionID = location.dimension
        map?.viewport.center = CGPoint(x: location.x, y: location.z)
        if let map, map.viewport.scale < 2 { map.viewport.scale = 2 }
    }

    var selectedDimension: MCWorldKit.Dimension? {
        dimensions.first { $0.id == selectedDimensionID }
    }

    private func makeMapForSelection() {
        map?.cancel()
        guard let dimension = selectedDimension else {
            map = nil
            return
        }
        // Start at the world spawn when it's in this dimension, otherwise at the origin.
        var center = CGPoint.zero
        if let spawn = world.level.spawnPosition, (world.level.spawnDimension ?? "minecraft:overworld") == dimension.id {
            center = CGPoint(x: spawn.x, y: spawn.z)
        }
        map = MapModel(dimension: dimension, center: center,
                       cacheDirectory: TileCache.directory(forWorldAt: url, dimensionID: dimension.id))
    }

    /// Stops rendering and gives up file access. Call before replacing the session.
    func close() {
        map?.cancel()
        if isAccessingSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

enum WorldOpenError: LocalizedError {
    case notAWorld
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notAWorld:
            String(localized: "That folder isn’t a Minecraft world. Choose a world’s folder inside your saves folder.")
        case .unreadable:
            String(localized: "MCWorld couldn’t read this world. It may be from a version MCWorld doesn’t support, or damaged.")
        }
    }
}

extension MCWorldKit.Dimension {
    /// The dimension's name as players know it.
    var displayName: String {
        switch id {
        case "minecraft:overworld": String(localized: "Overworld")
        case "minecraft:the_nether": String(localized: "The Nether")
        case "minecraft:the_end": String(localized: "The End")
        default: id
        }
    }
}
