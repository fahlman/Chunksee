import ChunkseeKit
import Foundation
import Synchronization

/// Definitions and model geometry remain available independently of whether artwork is enabled.
/// The immutable archive is shared with the artwork reader; only this actor owns material data.
actor GameDataLibrary {
    typealias MaterialRead = @Sendable (BlockState) -> MapBlockMaterial?
    nonisolated let identity = UUID()
    nonisolated let version: GameAssets.Version
    nonisolated let sourceKey: String
    private var assets: GameAssets?
    private nonisolated let materials = Materials()
    private let blockDefinitions = NSCache<NSString, DefinitionEntry>()

    nonisolated private final class DefinitionEntry {
        let present: Bool?
        init(_ present: Bool?) { self.present = present }
    }

    /// NSCache synchronizes warm lookups of immutable entries. The lock serializes misses
    /// from this actor and job-scoped coverage readers, and drains them before retirement.
    nonisolated private final class Materials: @unchecked Sendable {
        let values = NSCache<Key, MapBlockMaterial>()
        private let retired = Mutex(false)
        init() {
            values.countLimit = 512
            values.totalCostLimit = 16 * 1024 * 1024
        }

        func read(_ state: BlockState, assets: GameAssets) -> MapBlockMaterial? {
            retired.withLock { retired in
                guard !retired, !Task.isCancelled else { return nil }
                let key = Key(state)
                if let cached = values.object(forKey: key) { return cached }
                let material: MapBlockMaterial
                do {
                    material = MapBlockMaterial(state: state, model: try assets.readBlockModel(for: state))
                } catch AssetReadError.missingModel {
                    material = MapBlockMaterial(state: state, model: nil, modelIsMissing: true)
                } catch {
                    material = MapBlockMaterial(state: state, model: nil)
                }
                guard !Task.isCancelled else { return nil }
                let cost = material.model?.parts.reduce(1) { total, part in
                    total + part.alternatives.reduce(0) { $0 + GameModelRenderer.modelCost($1.model) }
                } ?? 1
                values.setObject(material, forKey: key, cost: cost + material.biomeTints.count * 32)
                return material
            }
        }

        func close() {
            retired.withLock {
                $0 = true
                values.removeAllObjects()
            }
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
        blockDefinitions.countLimit = 4096
        blockDefinitions.totalCostLimit = 1024 * 1024
    }

    func close() {
        assets = nil
        materials.close()
        blockDefinitions.removeAllObjects()
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
        let read = try mapMaterialReader()
        return try states.map { state in
            guard let material = read(state) else { throw CancellationError() }
            return material
        }
    }

    /// A job reads only states reached by its column walk, through the same material owner.
    /// The immutable archive stays retained, but retirement prevents subsequent reads or writes.
    func mapMaterialReader() throws -> MaterialRead {
        try checkAvailable()
        guard let assets else { throw CancellationError() }
        return { [materials] state in materials.read(state, assets: assets) }
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

    /// Presence is a data fact, independent of whether artwork can be drawn or is enabled.
    /// A nil answer never means that the game rejects the saved block.
    func blockDefinitions(for ids: Set<String>) throws -> [String: Bool] {
        try checkAvailable()
        var result: [String: Bool] = [:]
        for id in ids {
            try Task.checkCancellation()
            let key = id as NSString
            let entry: DefinitionEntry
            if let cached = blockDefinitions.object(forKey: key) { entry = cached }
            else {
                entry = DefinitionEntry(assets?.containsBlockDefinition(id))
                let cost = 64 + id.utf8.count
                if cost <= blockDefinitions.totalCostLimit {
                    blockDefinitions.setObject(entry, forKey: key, cost: cost)
                }
            }
            result[id] = entry.present
        }
        return result
    }

    /// Kit owns the game's entity-to-egg relationship; the ordinary item path draws it.
    func spawnEgg(for species: String) throws -> ItemStack? {
        try checkAvailable()
        return assets?.spawnEggItemID(for: species).map { ItemStack(id: $0.description) }
    }

    func blockItem(for block: BlockState) throws -> ItemStack? {
        try checkAvailable()
        return assets?.blockItemID(for: block.id).map { ItemStack(id: $0.description) }
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
