import ChunkseeIndex
import ChunkseeKit
import CryptoKit
import Foundation
import Testing
@testable import ChunkseeTestHost

extension NamingComparison {
    @concurrent static func verify(_ root: URL, against expected: [String: String]) async throws {
        try verifyFiles(root, against: expected)
    }

    // Foundation's synchronous enumerator cannot be iterated in an async function.
    // The concurrent entry point keeps this blocking file scan off the main actor.
    nonisolated private static func verifyFiles(_ root: URL, against expected: [String: String]) throws {
        try #require(!expected.isEmpty)
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try #require(rootValues.isDirectory == true && rootValues.isSymbolicLink == false)
        let manager = FileManager.default
        let fields: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let iterator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: Array(fields)))
        var actual: [String: String] = [:]
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: fields)
            try #require(values.isSymbolicLink == false)
            if values.isDirectory == true { continue }
            try #require(values.isRegularFile == true && url.path.hasPrefix(root.path + "/"))
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
            actual[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        try #require(actual == expected)
    }

    static func hit(_ value: SearchHit, names: GameNames) -> [String: Any] {
        let source: [String: Any]
        switch value.source {
        case .container(let kind): source = ["kind": "container", "container": kind]
        case .sign: source = ["kind": "sign"]
        case .block(let block): source = ["kind": "block", "block": block.rawValue]
        case .inventory(let id): source = ["kind": "inventory", "player": id.uuidString]
        case .enderChest(let id): source = ["kind": "enderChest", "player": id.uuidString]
        case .layer(let layer, let markerID):
            let kind: String, group: String
            switch layer {
            case .structure(let value): kind = "structure"; group = value.rawValue
            case .place(let value): kind = "place"; group = value.rawValue
            case .creature(let value): kind = "creature"; group = value.rawValue
            case .biome(let value): kind = "biome"; group = value.id
            }
            source = ["kind": "layer", "layer": kind, "group": group, "markerID": markerID]
        }
        return ["id": value.id, "source": source, "dimension": value.dimension as Any? ?? NSNull(),
                "position": value.position.map(NamingComparisonCapture.point) as Any? ?? NSNull(),
                "y": value.y as Any? ?? NSNull(), "count": value.count,
                "display": NamingComparisonAdapter.hitText(value, names: names)]
    }

    static func snapshot(_ session: WorldSession, to folder: URL) async throws {
        let resources = session.resources
        var result: [String: Data] = [
            "world-info.json": try NamingComparisonCapture.json(NamingComparisonCapture.worldInfo(resources)),
            "index.json": try NamingComparisonCapture.json(NamingComparisonCapture.indexProof(session.search.index)),
            "players.json": try NamingComparisonCapture.json(NamingComparisonCapture.playerProof(session)),
            "saved-maps.json": try NamingComparisonCapture.encoded(resources.details.maps.sorted { $0.id < $1.id }),
            "storage-source-order.json": try NamingComparisonCapture.json(
                NamingComparisonAdapter.storage(session).map {
                    ["id": $0.id, "name": $0.name, "count": $0.count, "containers": $0.containers] as [String: Any]
                }),
            "linked-pet-order.json": try NamingComparisonCapture.json(
                resources.players.sorted { $0.uuid.uuidString < $1.uuid.uuidString }.map { player in
                    ["player": player.uuid.uuidString,
                     "pets": session.presentation.linkedPets(to: player.uuid).map {
                         ["id": $0.id, "dimension": $0.dimension]
                     }] as [String: Any]
                }),
            "names.json": try NamingComparisonCapture.json([
                "languageCode": resources.gameNames.name(key: "language.code", fallback: "(missing)"),
                "coal": resources.gameNames.item("minecraft:coal"),
                "villager": resources.gameNames.name("minecraft:villager", in: "entity"),
            ]),
            "saved-queries.json": try NamingComparisonCapture.json(session.savedSearches.all.map {
                ["query": $0.query, "shown": $0.isShown,
                 "hits": session.search.results(for: $0.query).map { hit($0, names: resources.gameNames) }] as [String: Any]
            }),
        ]
        for (id, reader) in resources.readers.sorted(by: { $0.key < $1.key }) {
            for region in reader.availableRegions.sorted(by: { ($0.x, $0.z) < ($1.x, $1.z) }) {
                let facts = try #require(await reader.facts(region))
                var value = try #require(NamingComparisonCapture.object(facts) as? [String: Any])
                // These two saved fields are sets; all ordered facts remain in their original order.
                for key in ["blockIDs", "paletteBlockIDs"] {
                    if let ids = value[key] as? [String] { value[key] = ids.sorted() }
                }
                let name = id.replacingOccurrences(of: ":", with: "_") + "-\(region.x)-\(region.z)"
                result[name + "-facts.json"] = try NamingComparisonCapture.json(value)
                let dimension = await reader.dimension
                result[name + "-scan-key.json"] = try NamingComparisonCapture.encoded(
                    ScanCache.Key(dimension: dimension, region: region, options: .init(reader.scanOptions)))
            }
        }
        try write(result, to: folder)
    }
}
