import ChunkseeKit
import Foundation

/// Definitions and model geometry remain available independently of whether artwork is enabled.
/// The immutable archive is shared with the artwork reader; only this actor owns material data.
actor GameDataLibrary {
    nonisolated let identity = UUID()
    nonisolated let version: GameAssets.Version
    nonisolated let sourceKey: String
    private var assets: GameAssets?
    private nonisolated let materials = Materials()

    /// NSCache synchronizes access; entries are immutable and only the actor inserts them.
    nonisolated private final class Materials: @unchecked Sendable {
        let values = NSCache<Key, MapBlockMaterial>()
        init() {
            values.countLimit = 512
            values.totalCostLimit = 16 * 1024 * 1024
        }
    }

    nonisolated private final class Key: NSObject {
        let state: BlockState
        init(_ state: BlockState) { self.state = state }
        override var hash: Int { state.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.state == state }
    }

    init(assets: GameAssets, sourceKey: String) {
        self.assets = assets
        self.sourceKey = sourceKey
        version = assets.version
    }

    func close() {
        assets = nil
        materials.values.removeAllObjects()
    }

    func checkAvailable() throws {
        try Task.checkCancellation()
        guard assets != nil else { throw CancellationError() }
    }

    nonisolated func cachedMapMaterials(for states: [BlockState]) -> [MapBlockMaterial]? {
        var result: [MapBlockMaterial] = []
        result.reserveCapacity(states.count)
        for state in states {
            guard let entry = materials.values.object(forKey: Key(state)) else { return nil }
            result.append(entry)
        }
        return result
    }

    func mapMaterials(for states: [BlockState]) throws -> [MapBlockMaterial] {
        try checkAvailable()
        return try states.map { state in
            try Task.checkCancellation()
            let key = Key(state)
            if let cached = materials.values.object(forKey: key) { return cached }
            let material = MapBlockMaterial(state: state, model: assets?.blockModel(for: state))
            let cost = material.model?.parts.reduce(1) { total, part in
                total + part.alternatives.reduce(0) { $0 + GameModelRenderer.modelCost($1.model) }
            } ?? 1
            materials.values.setObject(material, forKey: key, cost: cost + material.biomeTints.count * 32)
            return material
        }
    }

    func language(_ preference: String, minecraftDirectory: URL?) -> GameLanguage? {
        guard !Task.isCancelled, let assets else { return nil }
        let choices = assets.languageCodes(minecraftDirectory: minecraftDirectory)
        return GameLanguageChoice.language(for: preference, available: choices) { code in
            guard !Task.isCancelled else { return nil }
            return assets.language(code, minecraftDirectory: minecraftDirectory)
        }
    }

    func advancementDefinitions(in world: World, for identifiers: Set<String>) throws -> [String: AdvancementDefinition] {
        try checkAvailable()
        return try world.advancementDefinitions(for: identifiers, assets: assets)
    }

    func definitions(in world: World) throws -> WorldDefinitions {
        try checkAvailable()
        return try WorldDefinitions.read(world, assets: assets)
    }

    func lighting(in world: World) throws -> [String: MapLighting] {
        try checkAvailable()
        return try MapLighting.read(in: world, assets: assets)
    }

    func nightLighting(in world: World) throws -> [String: MonsterSpawnLight] {
        try checkAvailable()
        return try world.nightMonsterLighting(assets: assets)
    }

    func biomeColors(in world: World, artwork: GameArtworkLibrary?) async throws -> MapBiomeColors {
        let maps = try await artwork?.colorMaps() ?? [:]
        try checkAvailable()
        return try MapBiomeColors.read(in: world, source: GameResourceSource(data: self, artwork: artwork),
                                       assets: assets, colorMaps: maps)
    }
}

/// Data identity and artwork availability are separate parts of every affected cache key.
nonisolated struct GameResourceSource: Hashable, Sendable {
    enum Artwork: Hashable, Sendable {
        case unavailable
        case game(String)

        var cacheKey: String {
            switch self {
            case .unavailable: "none"
            case .game(let source): "game-" + source
            }
        }
    }

    let data: String?
    let artwork: Artwork

    init(data: GameDataLibrary?, artwork: GameArtworkLibrary?) {
        self.data = data?.sourceKey
        self.artwork = artwork.map { .game($0.sourceKey) } ?? .unavailable
    }

    init(data: String?, artwork: Artwork) {
        self.data = data
        self.artwork = artwork
    }

    static let unavailable = Self(data: nil as String?, artwork: .unavailable)
    var cacheKey: String { CacheKey.hash((data ?? "no-game-data") + "\nartwork:" + artwork.cacheKey) }
}
