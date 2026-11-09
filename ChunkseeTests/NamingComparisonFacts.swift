import ChunkseeKit
import ChunkseeIndex
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

// Evidence serializers retained from the reviewed index/query probe. No world rules are added.
extension NamingComparisonCapture {
    static func worldInfo(_ resources: WorldResources) -> [String: Any] {
        let info = resources.infoSnapshot, level = resources.world.level
        var result: [String: Any] = [
            "seed": info.seed as Any? ?? NSNull(), "dayTime": info.dayTime as Any? ?? NSNull(),
            "gameRules": info.gameRules.mapValues { value -> [String: Any] in
                switch value {
                case .bool(let flag): ["type": "bool", "value": flag]
                case .int(let number): ["type": "int", "value": number]
                }
            },
            "weather": info.weather.map { value in
                ["rain": value.isRaining, "thunder": value.isThundering, "rainTime": value.rainTime,
                 "thunderTime": value.thunderTime, "clearTime": value.clearTime] as [String: Any]
            } as Any? ?? NSNull(),
            "borders": info.borders.mapValues { value in
                ["x": number(value.centerX), "z": number(value.centerZ), "size": number(value.size),
                 "targetSize": number(value.targetSize), "lerpTime": value.lerpTime,
                 "damage": number(value.damagePerBlock), "safeZone": number(value.safeZone),
                 "warningBlocks": value.warningBlocks, "warningTime": value.warningTime] as [String: Any]
            },
            "dragon": info.dragonFight.map { value in
                ["dragonKilled": value.dragonKilled, "previouslyKilled": value.previouslyKilled,
                 "remainingGateways": value.remainingGateways, "needsStateScanning": value.needsStateScanning] as [String: Any]
            } as Any? ?? NSNull(),
            "trader": info.wanderingTrader.map { value in
                ["spawnDelay": value.spawnDelay, "spawnChance": value.spawnChance]
            } as Any? ?? NSNull(),
        ]
        result["level"] = [
            "name": level.name as Any? ?? NSNull(), "dataVersion": level.dataVersion as Any? ?? NSNull(),
            "versionName": level.versionName as Any? ?? NSNull(), "snapshot": level.isSnapshot as Any? ?? NSNull(),
            "history": level.versionHistory, "lastPlayed": level.lastPlayed?.timeIntervalSince1970 as Any? ?? NSNull(),
            "time": level.time as Any? ?? NSNull(), "gameType": level.gameType as Any? ?? NSNull(),
            "difficulty": level.difficulty as Any? ?? NSNull(), "hardcore": level.isHardcore as Any? ?? NSNull(),
            "difficultyLocked": level.difficultyLocked as Any? ?? NSNull(), "commands": level.allowCommands as Any? ?? NSNull(),
            "singleplayer": level.singleplayerUUID?.uuidString as Any? ?? NSNull(),
            "spawnDimension": level.spawnDimension as Any? ?? NSNull(),
            "spawn": level.spawnPosition.map { [$0.x, $0.y, $0.z] } as Any? ?? NSNull(),
            "features": level.enabledFeatures, "enabledPacks": level.enabledDataPacks,
            "disabledPacks": level.disabledDataPacks, "wasModded": level.wasModded, "brands": level.serverBrands,
        ] as [String: Any]
        return result
    }

    static func location(_ value: PlayerInfo.Location?) -> Any {
        value.map { ["dimension": $0.dimension, "x": number($0.x), "y": number($0.y), "z": number($0.z)] as [String: Any] } as Any? ?? NSNull()
    }
    static func portal(_ value: NetherPortal) -> [String: Any] {
        ["dimension": value.dimension, "blocks": value.blocks.map { [$0.x, $0.y, $0.z] }]
    }
    static func creature(_ value: CreatureMarker) throws -> [String: Any] {
        ["id": value.id, "group": value.group.rawValue, "dimension": value.dimension,
         "carrier": value.carrier?.uuidString as Any? ?? NSNull(), "creature": try object(value.creature)]
    }

    /// Area/member/edge order is unspecified in Kit. Preserve each subpath's commands and
    /// sort only independent subpaths; drawing direction and coordinates are not discarded.
    static func geometry(_ path: Path) throws -> [Any] {
        var parts: [[[Any]]] = [], current: [[Any]] = []
        path.forEach { element in
            switch element {
            case .move(to: let p):
                if !current.isEmpty { parts.append(current) }
                current = [["move", point(p)]]
            case .line(to: let p): current.append(["line", point(p)])
            case .quadCurve(to: let p, control: let c): current.append(["quad", point(p), point(c)])
            case .curve(to: let p, control1: let a, control2: let b): current.append(["curve", point(p), point(a), point(b)])
            case .closeSubpath: current.append(["close"])
            }
        }
        if !current.isEmpty { parts.append(current) }
        return try parts.map { (try json($0), $0) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 }
    }

    static func indexProof(_ index: SearchIndex) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (dimension, part) in index.dimensions {
            let deposits = part.blocks.sorted {
                if $0.deposit.count != $1.deposit.count { return $0.deposit.count > $1.deposit.count }
                return ($0.chunk.x, $0.chunk.z, $0.deposit.block.rawValue) < ($1.chunk.x, $1.chunk.z, $1.deposit.block.rawValue)
            }.map { ["chunk": [$0.chunk.x, $0.chunk.z], "block": $0.deposit.block.rawValue,
                     "count": $0.deposit.count, "minY": $0.deposit.minY, "maxY": $0.deposit.maxY] as [String: Any] }
            let biomes = part.biomes.sorted { ($0.key.x, $0.key.z) < ($1.key.x, $1.key.z) }.map {
                ["chunk": [$0.key.x, $0.key.z], "biome": $0.value] as [String: Any]
            }
            let caves = part.caveBiomes.sorted { ($0.key.x, $0.key.z) < ($1.key.x, $1.key.z) }.map {
                ["chunk": [$0.key.x, $0.key.z], "biomes": $0.value.sorted()] as [String: Any]
            }
            let places: [[String: Any]] = part.places.map { value in
                ["id": value.id, "type": value.type, "group": value.group.rawValue, "position": point(value.position),
                 "y": value.y, "claimed": value.isClaimed, "portal": value.portal.map(portal) as Any? ?? NSNull(),
                 "mob": value.mob as Any? ?? NSNull(), "lootTable": value.lootTable as Any? ?? NSNull(),
                 "blockPosition": value.blockPosition.map { [$0.x, $0.y, $0.z] } as Any? ?? NSNull()]
            }
            let areas: [[String: Any]] = try part.biomeAreas.sorted { $0.id < $1.id }.map { value in
                ["id": value.id, "biome": value.group.id, "chunkCount": value.chunkCount,
                 "position": point(value.position), "bounds": frame(value.bounds),
                 "chunks": try geometry(value.chunks), "outline": try geometry(value.outline)]
            }
            result[dimension] = [
                "regions": part.regions.keys.sorted { ($0.x, $0.z) < ($1.x, $1.z) }.map { [$0.x, $0.z] },
                "sharedDimension": part.shared?.dimension as Any? ?? NSNull(),
                "containers": try part.containers.map(object),
                "storage": part.storage.map { ["id": $0.id, "count": $0.count, "containers": $0.containers] as [String: Any] },
                "signs": try part.signs.map(object), "structures": try part.structures.map(object),
                "places": places, "creatures": try part.creatures.map(creature),
                "biomes": biomes, "caveBiomes": caves, "biomeAreas": areas, "deposits": deposits,
                "formats": ["readable": part.formats.readable, "legacy": part.formats.legacy],
            ] as [String: Any]
        }
        return result
    }

    static func playerProof(_ session: WorldSession) throws -> [String: Any] {
        let snapshot = session.search.playerSnapshot
        try #require(snapshot === session.resources.playerSnapshot)
        try #require(snapshot === session.resources.index.playerSnapshot)
        let players = snapshot.players.sorted { $0.uuid.uuidString < $1.uuid.uuidString }.map {
            ["uuid": $0.uuid.uuidString, "dimension": $0.dimension as Any? ?? NSNull(),
             "rawDimension": $0.unrecognizedDimension as Any? ?? NSNull(), "position": location($0.position),
             "lastDeath": location($0.lastDeath), "respawn": location($0.respawn),
             "health": number($0.health), "maximum": number($0.maxHealth)] as [String: Any]
        }
        let shoulders = try snapshot.shoulderPets.sorted { $0.id < $1.id }.map {
            ["id": $0.id, "carrier": $0.carrier.uuidString, "location": location($0.location),
             "creature": try object($0.creature), "projectedMarker": try $0.marker.map(creature) as Any? ?? NSNull()] as [String: Any]
        }
        return ["players": players, "shoulders": shoulders, "coherentRosterAndProjection": true]
    }
    static func number(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value.isFinite ? value as Any : String(value) as Any
    }
}
