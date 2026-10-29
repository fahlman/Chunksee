import ChunkseeKit
import SwiftUI

nonisolated enum MapLightingMode: String, CaseIterable, Sendable {
    case savedTime, daylight

    var title: LocalizedStringResource {
        switch self {
        case .savedTime: "Saved Time"
        case .daylight: "Daylight"
        }
    }
}

/// Display policy over Kit's saved facts. It does not define or advance Minecraft's clocks.
nonisolated struct MapLighting: Equatable, Sendable {
    let saved: SkyLighting

    init?(saved: SkyLighting, time: DimensionTime?) {
        guard time?.hasSkylight == true else { return nil }
        self.saved = saved
    }

    static func read(in world: World, assets: GameAssets?) throws -> [String: MapLighting] {
        let types = try world.dimensionTypes(assets: assets)
        return try world.savedSkyLighting(assets: assets).reduce(into: [:]) { result, entry in
            result[entry.key] = MapLighting(saved: entry.value, time: types[entry.key]?.time)
        }
    }

    /// Minecraft's sun is overhead at zero degrees and travels from east (+X) to west.
    /// A dimension's own moon angle supplies the light when its sun is below the horizon.
    var direction: SIMD3<Float> {
        func direction(_ degrees: Float) -> SIMD3<Float> {
            let angle = Double(degrees).truncatingRemainder(dividingBy: 360) * .pi / 180
            return SIMD3(Float(-sin(angle)), Float(cos(angle)), 0)
        }
        let sun = direction(saved.sunAngle)
        return sun.y >= 0 ? sun : direction(saved.moonAngle)
    }

    /// This is a readable map, not a simulation of a dark game screen. Keep an ambient floor,
    /// preserve block-color recognition, and give Increase Contrast a brighter, milder tint.
    func tint(increasedContrast: Bool) -> SIMD3<Float> {
        let level = min(1, max(0, saved.skyLightFactor))
        let floor: Float = increasedContrast ? 0.8 : 0.55
        let blend: Float = increasedContrast ? 0.25 : 0.5
        let brightness = floor + (1 - floor) * level
        func channel(_ value: Float) -> Float { brightness * (1 - blend + blend * min(1, max(0, value))) }
        return SIMD3(channel(saved.skyLightColor.x), channel(saved.skyLightColor.y), channel(saved.skyLightColor.z))
    }

    var moonPhase: LocalizedStringResource {
        switch saved.moonPhase {
        case .fullMoon: "Full Moon"
        case .waningGibbous: "Waning Gibbous"
        case .thirdQuarter: "Third Quarter"
        case .waningCrescent: "Waning Crescent"
        case .newMoon: "New Moon"
        case .waxingCrescent: "Waxing Crescent"
        case .firstQuarter: "First Quarter"
        case .waxingGibbous: "Waxing Gibbous"
        }
    }

    @MainActor
    func shader(normals: CGImage, rect: CGRect, protectsWater: Bool, increasedContrast: Bool) -> Shader {
        let direction = direction, tint = tint(increasedContrast: increasedContrast)
        return ShaderLibrary.mapSavedLighting(
            .image(Image(decorative: normals, scale: 1)),
            .float4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
            .float3(direction.x, direction.y, direction.z), .float3(tint.x, tint.y, tint.z),
            .float(protectsWater ? 1 : 0))
    }
}

/// Immutable drawing inputs share the existing full/preview eviction owner. A normal image
/// costs one additional image-sized slot; no full-resolution Canvas survives in the model.
nonisolated final class MapTileImage: @unchecked Sendable { // Both CGImages are immutable.
    let image: CGImage
    let normals: CGImage?

    init(_ image: CGImage, normals: CGImage? = nil) {
        self.image = image
        self.normals = normals
    }

    var storageUnits: Int { normals == nil ? 1 : 2 }
}

/// A retained picture always carries the complete surface and preparation that produced it.
nonisolated final class CachedMapImage: Sendable {
    let key: RegionTileRenderer.ImageKey
    let picture: MapTileImage

    init(key: RegionTileRenderer.ImageKey, picture: MapTileImage) {
        self.key = key
        self.picture = picture
    }

    var image: CGImage { picture.image }
    var normals: CGImage? { picture.normals }
    var storageUnits: Int { picture.storageUnits }
}
