import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@MainActor
enum MapComparisonState {
    static func choices(_ session: WorldSession) throws -> [String: Any] {
        let map = try #require(session.map), layers = session.visibility
        return [
            "style": map.chosenStyle.rawValue,
            "depth": ["y": map.depth.y, "surface": map.depth.isSurface],
            "lightingMode": map.lightingMode.rawValue, "castsShadows": map.castsShadows,
            "blending": map.blendsBiomeColors,
            "blockFilter": ["enabled": map.blockFilter.isEnabled, "hidden": map.blockFilter.hiddenIDs.sorted(),
                            "highlighted": map.blockFilter.highlightedIDs.sorted()] as [String: Any],
            "viewport": [Double(map.viewport.center.x), Double(map.viewport.center.y), Double(map.viewport.scale)],
            "overlays": [
                "structures": layers.structures.map(\.rawValue).sorted(),
                "places": layers.places.map(\.rawValue).sorted(),
                "creatures": layers.creatures.map(\.rawValue).sorted(),
                "mobs": layers.mobTypes.sorted(), "biomes": layers.biomes.map(\.id).sorted(),
                "hiddenPlayers": layers.hiddenPlayers.map(\.uuidString).sorted(),
                "grid": layers.showsGrid, "savedPlaces": layers.showsSavedPlaces,
                "worldBorder": layers.showsWorldBorder, "timeSpent": session.heatMap.isShown,
                "slimeChunks": session.slimeChunks.isShown, "darkSpots": map.showsDarkSpots,
            ] as [String: Any],
        ]
    }

    /// Keep raw retained pixels and typed cache keys beside each rendered picture. This exposes
    /// equal-looking output backed by incompatible caches and keeps missing coverage explicit.
    static func capture(_ session: WorldSession, to folder: URL) async throws -> [String: Bool] {
        let map = try #require(session.map)
        map.loadTopBlocks(at: MapComparisonEvidence.water)
        await map.waitForTopBlocks()
        let content = MapContent(session: session)
        let renderer = try requiredRenderer(map)
        let block = map.topBlock(at: MapComparisonEvidence.water)
        var artifacts: [String: Data] = [:], formats: [String: Any] = [:], keys: [String: Any] = [:]
        var nonemptyShadow = false, hasDetail = false
        func retain(_ image: CGImage, name: String) throws {
            let (bytes, format) = try MapComparisonEvidence.rawImage(image)
            artifacts[name + ".rgba"] = bytes
            formats[name] = format
            if name.hasSuffix("-shadow") {
                nonemptyShadow = nonemptyShadow || stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
            }
        }
        do {
            for region in map.viewport.visibleRegions(in: MapComparisonEvidence.size, among: map.availableRegions) {
                let name = "r\(region.x).\(region.z)"
                let tile = try #require(map.tiles[region])
                try #require(renderer.accepts(tile.key))
                keys[name + "-full"] = try MapComparisonEvidence.imageKey(tile.key)
                try retain(tile.image, name: name + "-full")
                if let normals = tile.normals { try retain(normals, name: name + "-normals") }
                if let preview = map.previews[region] {
                    try #require(renderer.accepts(preview.key))
                    keys[name + "-preview"] = try MapComparisonEvidence.imageKey(preview.key)
                    try retain(preview.image, name: name + "-preview")
                    if let normals = preview.normals { try retain(normals, name: name + "-preview-normals") }
                }
                if let shadow = map.shadowImages[region] { try retain(shadow, name: name + "-shadow") }
            }
            for (chunk, tile) in map.detailImages.sorted(by: { ($0.key.x, $0.key.z) < ($1.key.x, $1.key.z) }) {
                guard let rect = map.viewport.viewRect(for: chunk, in: MapComparisonEvidence.size),
                      rect.intersects(CGRect(origin: .zero, size: MapComparisonEvidence.size)) else { continue }
                try #require(renderer.accepts(tile.key))
                let name = "detail-\(chunk.x).\(chunk.z)"
                keys[name] = try MapComparisonEvidence.imageKey(tile.key)
                try retain(tile.image, name: name)
                if let normals = tile.normals { try retain(normals, name: name + "-normals") }
                hasDetail = true
            }
            for (region, image) in session.heatMap.visibleImages ?? [:] {
                try retain(image, name: "heat-\(region.x).\(region.z)")
            }
            for (region, image) in session.slimeChunks.visibleImages {
                try retain(image, name: "slime-\(region.x).\(region.z)")
            }
            artifacts["choices.json"] = try MapComparisonEvidence.json(choices(session))
            artifacts["readout.json"] = try MapComparisonEvidence.json([
                "point": [-256, -256],
                "raw": block.map {
                    ["id": $0.id, "y": $0.y, "waterDepth": $0.waterDepth,
                     "nightLight": $0.nightLight.map { $0.rawValue as Any } ?? NSNull(),
                     "hasGameDefinition": $0.hasGameDefinition.map { $0 as Any } ?? NSNull()] as [String: Any]
                } as Any? ?? NSNull(),
                "text": MapView.readout(at: MapComparisonEvidence.water, block: block,
                    biomes: content.biomeDescription(at: MapComparisonEvidence.water),
                    gameNames: content.gameNames, locale: MapComparisonEvidence.locale),
            ])
            artifacts["resolved.json"] = try MapComparisonEvidence.json([
                "style": map.style.rawValue,
                "heightScale": try map.heightScale.map(MapComparisonEvidence.object) ?? NSNull(),
                "gameDataAvailable": session.resources.mapGameResources.data != nil,
                "gameArtworkAvailable": session.resources.mapGameResources.artwork != nil,
                "lighting": map.lighting.map {
                    ["direction": [$0.direction.x, $0.direction.y, $0.direction.z],
                     "sunAngle": $0.saved.sunAngle, "moonAngle": $0.saved.moonAngle,
                     "skyLightFactor": $0.saved.skyLightFactor,
                     "skyLightColor": [$0.saved.skyLightColor.x, $0.saved.skyLightColor.y, $0.saved.skyLightColor.z]]
                } as Any? ?? NSNull(),
                "shadowLight": map.shadowLight.map { ["x": $0.x, "z": $0.z, "rise": $0.rise] as [String: Any] } as Any? ?? NSNull(),
                "nightRuleAvailable": map.nightLighting != nil,
                "mapLoading": map.isLoading, "heatLoading": session.heatMap.isLoading,
                "slimeLoading": session.slimeChunks.isLoading,
                "heatRegions": (session.heatMap.visibleImages ?? [:]).count,
                "slimeRegions": session.slimeChunks.visibleImages.count,
            ])
            artifacts["terrain-keys.json"] = try MapComparisonEvidence.json(keys)
            artifacts["image-formats.json"] = try MapComparisonEvidence.json(formats)
            try #require(!map.isLoading && !session.heatMap.isLoading && !session.slimeChunks.isLoading)
        } catch {
            try? MapComparisonEvidence.write(artifacts, to: folder)
            throw error
        }
        try MapComparisonEvidence.write(artifacts, to: folder)
        return ["nonemptyShadow": nonemptyShadow, "detail": hasDetail,
                "savedLighting": map.lighting != nil, "waterBlock": block?.id == "minecraft:water",
                "waterDepth8": block?.waterDepth == 8]
    }
}

