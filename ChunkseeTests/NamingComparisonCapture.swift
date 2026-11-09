import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Evidence only. Read the actual scene and renderer; do not recreate names or collision rules.
@MainActor
enum NamingComparisonCapture {
    static let size = CGSize(width: 1024, height: 768)
    static let locale = Locale(identifier: "en_US")

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(value)
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoded(value), options: [.fragmentsAllowed])
    }

    static func point(_ value: CGPoint) -> [Double] { [Double(value.x), Double(value.y)] }
    static func frame(_ value: CGRect) -> [Double] {
        [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
    }

    static func target(_ value: MapTarget) -> [String: Any] {
        switch value {
        case .searchHit(let id): return ["kind": "searchHit", "id": id]
        case .row(let row):
            switch row {
            case .worldInfo: return ["kind": "worldInfo"]
            case .storage: return ["kind": "storage"]
            case .savedPlace(let id): return ["kind": "savedPlace", "id": id.uuidString]
            case .structure(let id): return ["kind": "structure", "id": id]
            case .place(let id): return ["kind": "place", "id": id]
            case .creature(let id): return ["kind": "creature", "id": id]
            case .mobType(let id): return ["kind": "mobType", "id": id]
            case .mobCreature(let id): return ["kind": "mobCreature", "id": id]
            case .biome(let id): return ["kind": "biome", "id": id]
            case .inGameMap(let id): return ["kind": "inGameMap", "id": id]
            case .player(let id): return ["kind": "player", "id": id.uuidString]
            case .hit(let query, let id): return ["kind": "hit", "query": query, "id": id]
            }
        }
    }

    static func item(_ value: MapScene.Item) -> [String: Any] {
        ["id": value.id, "layer": value.layer.rawValue, "target": target(value.target),
         "position": point(value.position), "y": value.y as Any? ?? NSNull(),
         "anchor": point(value.anchor), "point": point(value.point), "frame": frame(value.frame),
         "scale": Double(value.scale), "priority": value.labelPriority.rawValue, "dimmed": value.isDimmed]
    }

    /// The recorder is active only for this synchronous drawing call. It retains strings and
    /// rectangles, never a session, drawing context, image, or library.
    static func render(_ session: WorldSession) throws -> (MapImage?, NamingComparisonTrace.Recorder) {
        try #require(NamingComparisonTrace.recorder == nil)
        let recorder = NamingComparisonTrace.Recorder()
        NamingComparisonTrace.recorder = recorder
        defer { NamingComparisonTrace.recorder = nil }
        let map = try #require(session.map)
        let image = MapImage.render(map, content: MapContent(session: session),
            portalStatus: { session.presentation.linkStatus(for: $0) }, size: size, scale: 1,
            colorScheme: .light, locale: locale)
        return (image, recorder)
    }

    static func imageKey(_ key: RegionTileRenderer.ImageKey) throws -> [String: Any] {
        ["surface": try object(key.surface),
         "heightScale": try key.preparation.heightScale.map(object) ?? NSNull(),
         "usesSavedLighting": key.preparation.usesSavedLighting,
         "chunk": key.chunk.map { [$0.x, $0.z] } as Any? ?? NSNull()]
    }

    /// Pack rows without padding, preserving every pixel's bytes and image-format metadata.
    static func image(_ value: CGImage) throws -> (Data, [String: Any]) {
        try #require(value.bitsPerPixel == 32)
        let data = try #require(value.dataProvider?.data) as Data
        try #require(data.count >= value.bytesPerRow * value.height)
        var pixels = Data(capacity: value.width * value.height * 4)
        for row in 0..<value.height {
            pixels.append(data[(row * value.bytesPerRow)..<(row * value.bytesPerRow + value.width * 4)])
        }
        return (pixels, ["width": value.width, "height": value.height,
                        "bitsPerComponent": value.bitsPerComponent, "bitmapInfo": value.bitmapInfo.rawValue,
                        "colorSpace": value.colorSpace?.name as Any? ?? NSNull()])
    }

    static func capture(_ session: WorldSession, picks: [CGPoint], hover: CGPoint,
                        to folder: URL) async throws -> [String: Data] {
        var proof: [String: Data] = [:]
        do {
            let map = try #require(session.map)
            map.loadTopBlocks(at: hover)
            await map.waitForTopBlocks()
            let content = MapContent(session: session)
            let scene = content.scene(viewport: map.viewport, size: size)
            let (rendered, recorder) = try render(session)
            proof["render.png"] = rendered?.data
            proof["caption-passes.json"] = try encoded(recorder.passes)
            proof["caption-state.json"] = try json([
                "unfinishedPass": recorder.hasUnfinishedPass, "imageProduced": rendered != nil,
            ])
            try #require(rendered != nil && !recorder.hasUnfinishedPass && !recorder.passes.isEmpty)
            for pass in recorder.passes {
                let candidates = pass.candidates.map(\.id)
                try #require(Set(candidates).count == candidates.count)
                try #require(Set(pass.drawnIDs).count == pass.drawnIDs.count)
                try #require(Set(pass.drawnIDs).isSubset(of: Set(candidates)))
                try #require(Set(candidates).isSubset(of: Set(pass.formatted.map(\.id))))
                try #require(pass.candidates.allSatisfy {
                    $0.frame.count == 4 && $0.frame.allSatisfy(\.isFinite) && $0.frame[2] > 0 && $0.frame[3] > 0
                })
            }
            proof["scene.json"] = try json([
                    "center": point(map.viewport.center), "scale": Double(map.viewport.scale),
                    "structures": scene.structures.map {
                        ["item": item($0.item), "outline": frame($0.outline),
                         "portalRoom": $0.portalRoom.map(point) as Any? ?? NSNull()] as [String: Any]
                    },
                    "items": scene.items.map(item),
                    "biomes": scene.biomeAreas.map {
                        ["id": $0.area.id, "point": point($0.point), "frame": frame($0.frame)] as [String: Any]
                    },
                ])
            proof["accessible.json"] = try json(content.accessibleLocations(viewport: map.viewport, size: size).map {
                    ["id": $0.id, "name": $0.name, "position": point($0.position), "y": $0.y as Any? ?? NSNull(),
                     "target": $0.target.map(target) as Any? ?? NSNull(),
                     "anchor": $0.anchor.map(point) as Any? ?? NSNull(), "frame": frame($0.frame)] as [String: Any]
                })
            // This records the caption hook only. An empty trace does not prove that an unrelated
            // formatter was never called; keep that limit separate from the routing result.
            try #require(NamingComparisonTrace.recorder == nil)
            let pickingTrace = NamingComparisonTrace.Recorder()
            NamingComparisonTrace.recorder = pickingTrace
            let picked = picks.map { position -> [String: Any] in
                let hit = content.hit(at: position, viewport: map.viewport, size: size)
                return ["point": point(position), "target": hit.map { target($0.target) } as Any? ?? NSNull(),
                        "position": hit.map { point($0.position) } as Any? ?? NSNull(),
                        "y": hit?.y as Any? ?? NSNull()]
            }
            NamingComparisonTrace.recorder = nil
            proof["picking.json"] = try json(picked)
            proof["picking-caption-state.json"] = try json([
                "unfinishedPass": pickingTrace.hasUnfinishedPass, "passes": try object(pickingTrace.passes),
            ])
            try #require(!pickingTrace.hasUnfinishedPass && pickingTrace.passes.isEmpty)
            let block = map.topBlock(at: hover)
            proof["readout.json"] = try json([
                "point": point(hover),
                "raw": block.map {
                    ["id": $0.id, "y": $0.y, "waterDepth": $0.waterDepth,
                     "nightLight": $0.nightLight.map { $0.rawValue as Any } ?? NSNull(),
                     "hasGameDefinition": $0.hasGameDefinition.map { $0 as Any } ?? NSNull()] as [String: Any]
                } as Any? ?? NSNull(),
                "text": NamingComparisonAdapter.readout(at: hover, block: block, content: content),
            ])
            let renderer = try #require(map.currentRenderer)
            var keys: [String: Any] = [:], formats: [String: Any] = [:]
            func retain(_ value: CGImage, name: String) throws {
                let (bytes, format) = try image(value)
                proof[name + ".rgba"] = bytes
                formats[name] = format
            }
            for region in map.viewport.visibleRegions(in: size, among: map.availableRegions) {
                let name = "r\(region.x).\(region.z)"
                let tile = try #require(map.tiles[region])
                try #require(renderer.accepts(tile.key))
                keys[name + "-full"] = try imageKey(tile.key)
                try retain(tile.image, name: name + "-full")
                if let normals = tile.normals { try retain(normals, name: name + "-normals") }
                if let preview = map.previews[region] {
                    try #require(renderer.accepts(preview.key))
                    keys[name + "-preview"] = try imageKey(preview.key)
                    try retain(preview.image, name: name + "-preview")
                    if let normals = preview.normals { try retain(normals, name: name + "-preview-normals") }
                }
                if let shadow = map.shadowImages[region] { try retain(shadow, name: name + "-shadow") }
            }
            for (chunk, tile) in map.detailImages.sorted(by: { ($0.key.x, $0.key.z) < ($1.key.x, $1.key.z) }) {
                guard let rect = map.viewport.viewRect(for: chunk, in: size),
                      rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                try #require(renderer.accepts(tile.key))
                let name = "detail-\(chunk.x).\(chunk.z)"
                keys[name] = try imageKey(tile.key)
                try retain(tile.image, name: name)
                if let normals = tile.normals { try retain(normals, name: name + "-normals") }
            }
            proof["terrain-keys.json"] = try json(keys)
            proof["image-formats.json"] = try json(formats)
            proof["presentation.json"] = try json([
                "style": map.chosenStyle.rawValue, "surface": map.depth.isSurface, "y": map.depth.y,
                "lighting": map.lightingMode.rawValue, "castsShadows": map.castsShadows,
                "artwork": renderer.gameArtwork != nil, "data": renderer.gameData?.sourceKey as Any? ?? NSNull(),
            ])
        } catch {
            // A failed assertion keeps everything captured before it, including any full image.
            try? NamingComparison.write(proof, to: folder)
            throw error
        }
        try NamingComparison.write(proof, to: folder)
        return proof
    }
}
