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

    private let isAccessingSecurityScope: Bool

    private init(url: URL, world: World, isAccessingSecurityScope: Bool) {
        self.url = url
        self.world = world
        self.dimensions = world.dimensions()
        self.isAccessingSecurityScope = isAccessingSecurityScope
        self.selectedDimensionID = dimensions.first?.id
        makeMapForSelection()
    }

    /// Opens a world folder. `url` must come from the Open panel or a resolved bookmark.
    static func open(_ url: URL) async throws -> WorldSession {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let world = try await load(url)
            return WorldSession(url: url, world: world, isAccessingSecurityScope: accessing)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Reading `level.dat` and listing dimensions touches the disk, so it runs off the main actor.
    @concurrent
    private nonisolated static func load(_ url: URL) async throws -> World {
        do {
            return try World(contentsOf: url)
        } catch WorldError.missingLevelDat {
            throw WorldOpenError.notAWorld
        } catch {
            throw WorldOpenError.unreadable
        }
    }

    var displayName: String { world.level.name ?? url.lastPathComponent }

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
