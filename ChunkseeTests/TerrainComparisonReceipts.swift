import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@MainActor
enum TerrainComparisonReceipts {
    /// Captures only images selected by the settled view. This does not render a second
    /// reference or substitute a renderer; pixel correctness remains with the edge tests.
    static func view(_ session: WorldSession, environment: TerrainComparisonWorkload.Environment,
                     to folder: URL) throws -> Data {
        let map = try #require(session.map), content = MapContent(session: session)
        let size = environment.size
        let regions = map.viewport.visibleRegions(in: size, among: map.availableRegions)
        let full = map.needsFullResolution(displayScale: environment.displayScale)
        let renderer = try requiredRenderer(map)
        var images: [String: Any] = [:], geometry: [String: Any] = [:], terrainGeometry: [String: Any] = [:]
        var chunks: [[Int]] = []
        var terrainCount = 0, shadowCount = 0, heatCount = 0, slimeCount = 0
        var visibleHeat = false, visibleSlime = false

        func retain(_ image: CGImage, _ name: String) throws {
            let (bytes, format) = try packed(image)
            try TerrainComparisonFiles.write([name + ".pixels": bytes], to: folder)
            images[name] = format
        }

        func tile(_ image: MapTileImage, _ name: String) throws {
            try retain(image.image, name)
            if let normals = image.normals { try retain(normals, name + "-normals") }
        }

        for region in regions {
            let key = "r\(region.x).\(region.z)"
            let image = try #require(map.image(for: region, fullResolution: full))
            let cached = try #require(full ? (map.tiles[region] ?? map.previews[region])
                : (map.previews[region] ?? map.tiles[region]))
            try #require(renderer.accepts(cached.key))
            let rect = try #require(map.viewport.viewRect(for: region, in: size))
            geometry[key] = rectangle(rect)
            terrainGeometry[key] = rectangle(TerrainComparisonAdapter.terrainRectangle(rect, scale: map.viewport.scale))
            try tile(image, "terrain-" + key)
            terrainCount += 1
            if content.terrain.includesDetail && map.viewport.scale >= MapDetailRenderer.minimumScale {
                for chunk in map.detailImages.keys.filter({ $0.region == region }).sorted(by: {
                    ($0.x, $0.z) < ($1.x, $1.z)
                }) {
                    guard let rect = map.viewport.viewRect(for: chunk, in: size),
                          rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                    let value = try #require(map.detailImages[chunk])
                    try #require(renderer.accepts(value.key))
                    let name = "detail-\(chunk.x).\(chunk.z)"
                    try tile(value.picture, name)
                    geometry[name] = rectangle(rect)
                    chunks.append([chunk.x, chunk.z])
                }
            }
            if content.terrain.shadowLight != nil, let shadow = map.shadowImages[region] {
                try retain(shadow, "shadow-" + key)
                shadowCount += 1
            }
            if let heat = content.heatMap[region] {
                try retain(heat, "heat-" + key)
                heatCount += 1
                visibleHeat = try visibleHeat || containsVisibleAlpha(heat, rect: rect, size: size)
            }
            if let slime = content.slimeChunks[region] {
                try retain(slime, "slime-" + key)
                slimeCount += 1
                visibleSlime = try visibleSlime || containsVisibleAlpha(slime, rect: rect, size: size)
            }
        }
        try #require(terrainCount > 0)
        var receipt = try configuration(session, content: content, environment: environment)
        receipt["visibleRegions"] = regions.map { [$0.x, $0.z] }
        receipt["visibleChunks"] = chunks
        receipt["fullResolutionRequested"] = full
        receipt["images"] = images
        receipt["selectedLayerCounts"] = ["terrain": terrainCount, "detail": chunks.count,
            "shadow": shadowCount, "heat": heatCount, "slime": slimeCount]
        receipt["visibleHeatNonempty"] = visibleHeat
        receipt["visibleSlimeNonempty"] = visibleSlime
        receipt["viewport"] = [Double(map.viewport.center.x), Double(map.viewport.center.y), Double(map.viewport.scale)]
        // Exact source bounds are common. Endpoint-specific padding and callback coverage
        // are recorded separately; neither belongs in cross-endpoint payload equality.
        try TerrainComparisonFiles.write(["source-bounds.json": TerrainComparisonFiles.json(geometry)], to: folder)
        try TerrainComparisonFiles.write(["derived-terrain-bounds.json": TerrainComparisonFiles.json(terrainGeometry)], to: folder)
        let data = try TerrainComparisonFiles.json(receipt)
        try TerrainComparisonFiles.write(["inputs.json": data], to: folder)
        return data
    }

    static func configuration(_ session: WorldSession, content: MapContent,
                              environment: TerrainComparisonWorkload.Environment) throws -> [String: Any] {
        let map = try #require(session.map), input = content.terrain
        try #require(content.structures.isEmpty && content.places.isEmpty && content.creatures.isEmpty)
        try #require(content.players.isEmpty && content.hits.isEmpty && content.savedPlaces.isEmpty)
        try #require(content.biomeAreas.isEmpty && content.inGameMap == nil && content.border == nil)
        try #require(!content.showsGrid && content.selection == nil)
        try #require(!content.ruler.isEnabled && content.ruler.start == nil && content.ruler.end == nil)
        try #require(!map.isLoading && map.unfinishedCacheWrites == 0)
        try #require(!session.heatMap.isLoading && !session.slimeChunks.isLoading)
        let lighting: Any
        if let value = input.lighting {
            let direction = value.direction, tint = value.tint(increasedContrast: false)
            lighting = [
                "direction": [direction.x, direction.y, direction.z], "tint": [tint.x, tint.y, tint.z],
                "sunAngle": value.saved.sunAngle, "moonAngle": value.saved.moonAngle,
                "skyLightFactor": value.saved.skyLightFactor,
                "skyLightColor": [value.saved.skyLightColor.x, value.saved.skyLightColor.y, value.saved.skyLightColor.z],
                "moonPhase": String(describing: value.saved.moonPhase),
            ] as [String: Any]
        } else { lighting = NSNull() }
        let shadow: Any = input.shadowLight.map {
            ["x": $0.x, "z": $0.z, "rise": $0.rise] as [String: Any]
        } as Any? ?? NSNull()
        let drawing: [String: Any] = [
            "style": input.style.rawValue, "depth": try TerrainComparisonFiles.object(input.depth),
            "heightScale": try input.heightScale.map(TerrainComparisonFiles.object) ?? NSNull(),
            "blockFilter": try TerrainComparisonFiles.object(input.blockFilter),
            "blendsBiomeColors": input.blendsBiomeColors, "showsDarkSpots": input.showsDarkSpots,
            "protectsWater": input.protectsWater, "includesDetail": input.includesDetail,
            "lighting": lighting, "shadowLight": shadow,
        ]
        return ["presentation": try TerrainComparisonFiles.object(map.presentation), "drawingInput": drawing,
                "savedDayTime": session.details.dayTime.map { $0 as Any } ?? NSNull(),
                "gameDataAvailable": session.resources.mapGameResources.data != nil,
                "gameArtworkAvailable": session.resources.mapGameResources.artwork != nil,
                "contrast": environment.contrast, "appearance": environment.appearance, "locale": environment.locale,
                "slimeSeed": content.slimeSeed.map { $0 as Any } ?? NSNull(),
                "showsHeatMap": content.showsHeatMap, "otherMarkersHidden": true]
    }

    static func export(_ session: WorldSession, plan: MapExportPlan,
                       environment: TerrainComparisonWorkload.Environment, to folder: URL) throws -> Data {
        let map = try #require(session.map), content = MapContent(session: session)
        let regions = plan.viewport.visibleRegions(in: plan.size, among: map.availableRegions)
        var receipt = try configuration(session, content: content, environment: environment)
        receipt["bounds"] = rectangle(plan.bounds)
        receipt["blocksPerPixel"] = plan.blocksPerPixel
        receipt["visibleRegions"] = regions.map { [$0.x, $0.z] }
        var overlays: [String: Any] = [:]
        var visibleHeat = false
        for region in regions {
            if let image = content.heatMap[region] {
                let name = "heat-r\(region.x).\(region.z)"
                let (bytes, format) = try packed(image)
                try TerrainComparisonFiles.write([name + ".pixels": bytes], to: folder)
                overlays[name] = format
                if let rect = plan.viewport.viewRect(for: region, in: plan.size) {
                    visibleHeat = try visibleHeat || containsVisibleAlpha(image, rect: rect, size: plan.size)
                }
            }
        }
        receipt["overlays"] = overlays
        receipt["visibleHeatNonempty"] = visibleHeat
        try #require(content.slimeChunks.isEmpty)
        let data = try TerrainComparisonFiles.json(receipt)
        try TerrainComparisonFiles.write(["inputs.json": data], to: folder)
        return data
    }

    /// Preserve source bytes and pixel format, removing row padding only. Both endpoints
    /// must supply the same real image payloads; no color conversion conceals differences.
    nonisolated static func packed(_ image: CGImage) throws -> (Data, [String: Any]) {
        try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
        let source = try #require(image.dataProvider?.data) as Data
        try #require(source.count >= image.bytesPerRow * image.height)
        var bytes = Data(capacity: image.width * image.height * 4)
        for row in 0..<image.height {
            bytes.append(source[(row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width * 4)])
        }
        return (bytes, ["width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
            "bitsPerPixel": image.bitsPerPixel, "bitmapInfo": image.bitmapInfo.rawValue,
            "alphaInfo": image.alphaInfo.rawValue, "colorSpace": image.colorSpace?.name.map { $0 as String } ?? "none",
            "sha256": TerrainComparisonFiles.digest(bytes)])
    }

    static func rectangle(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    /// Coverage checks the visible source portion, without counting the legend as overlay
    /// evidence. This is an alpha-presence check, not a replacement rendering reference.
    private static func containsVisibleAlpha(_ image: CGImage, rect: CGRect, size: CGSize) throws -> Bool {
        let visible = rect.intersection(CGRect(origin: .zero, size: size))
        guard !visible.isNull && !visible.isEmpty else { return false }
        let sx = CGFloat(image.width) / rect.width, sy = CGFloat(image.height) / rect.height
        let pixels = CGRect(x: (visible.minX - rect.minX) * sx, y: (visible.minY - rect.minY) * sy,
                            width: visible.width * sx, height: visible.height * sy).integral
        let cropped = try #require(image.cropping(to: pixels))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: cropped.width * cropped.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cropped.width, height: cropped.height,
                bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        }
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
    }
}
