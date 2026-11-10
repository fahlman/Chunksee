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
        var measures: [String: Any] = [:]
        let captureStart = NamingComparisonMeasures.Stamp()
        do {
            let map = try #require(session.map)
            map.loadTopBlocks(at: hover)
            await map.waitForTopBlocks()
            let content = MapContent(session: session)
            let scene = content.scene(viewport: map.viewport, size: size)
            let setupEnd = NamingComparisonMeasures.Stamp()
            let overlayIntervals = try NamingComparisonMeasures.overlays(session, content: content)
            let copyStart = NamingComparisonMeasures.Stamp()
            let rendered = MapImage.render(map, content: content,
                portalStatus: { session.presentation.linkStatus(for: $0) }, size: size, scale: 1,
                colorScheme: .light, locale: locale)
            let copyEnd = NamingComparisonMeasures.Stamp()
            measures = [
                "setup": captureStart.until(setupEnd),
                "viewCategory": map.viewport.scale == 1 ? "overview" : "caption-visible",
                "overlayPrimary": true, "copyPrimary": false,
                "pickingAndReadoutPrimary": map.viewport.scale == 1,
                "overlayCalls": overlayIntervals,
                "copy": copyStart.until(copyEnd),
                "scope": "Overlay call is primary; full Copy is reported separately. Setup/capture are outside both.",
            ]
            proof["render.png"] = rendered?.data
            try #require(rendered != nil)
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
            let pickingStart = NamingComparisonMeasures.Stamp()
            let found = picks.map { content.hit(at: $0, viewport: map.viewport, size: size) }
            let pickingEnd = NamingComparisonMeasures.Stamp()
            measures["picking"] = pickingStart.until(pickingEnd)
            let picked = zip(picks, found).map { position, hit -> [String: Any] in
                return ["point": point(position), "target": hit.map { target($0.target) } as Any? ?? NSNull(),
                        "position": hit.map { point($0.position) } as Any? ?? NSNull(),
                        "y": hit?.y as Any? ?? NSNull()]
            }
            proof["picking.json"] = try json(picked)
            let block = map.topBlock(at: hover)
            let readoutStart = NamingComparisonMeasures.Stamp()
            let text = NamingComparisonAdapter.readout(at: hover, block: block, content: content)
            let readoutEnd = NamingComparisonMeasures.Stamp()
            measures["readout"] = readoutStart.until(readoutEnd)
            proof["readout.json"] = try json([
                "point": point(hover),
                "raw": block.map {
                    ["id": $0.id, "y": $0.y, "waterDepth": $0.waterDepth,
                     "nightLight": $0.nightLight.map { $0.rawValue as Any } ?? NSNull(),
                     "hasGameDefinition": $0.hasGameDefinition.map { $0 as Any } ?? NSNull()] as [String: Any]
                } as Any? ?? NSNull(),
                "text": text,
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
            try NamingComparison.write(proof, to: folder)
            let captureEnd = NamingComparisonMeasures.Stamp()
            measures["completeCaptureIncludingProductCalls"] = captureStart.until(captureEnd)
            try NamingComparison.write(["measurements.json": json(measures)], to: folder)
        } catch {
            // A failed assertion keeps everything captured before it, including any full image.
            try? NamingComparison.write(proof, to: folder)
            try? NamingComparison.write(["failure-measurements.json": json(measures)], to: folder)
            throw error
        }
        return proof
    }
}
