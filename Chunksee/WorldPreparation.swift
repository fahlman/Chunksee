import ChunkseeKit

/// The game source and the opening facts it interprets travel together. Region readers must
/// never start with a temporary option set that evicts the same world's completed disk cache.
struct WorldPreparation {
    typealias ReadDefinitions = @Sendable (World, [ChunkseeKit.Dimension], GameDataLibrary?) async throws -> WorldDefinitions
    let snapshot: WorldSnapshot
    let source: WorldGameAssetSource
    let library: GameResourceLibrary?

    private init(snapshot: WorldSnapshot, source: WorldGameAssetSource, library: GameResourceLibrary?) {
        self.snapshot = snapshot
        self.source = source
        self.library = library
    }

    static func read(_ snapshot: WorldSnapshot, minecraft: MinecraftResources,
                     readDefinitions: @escaping ReadDefinitions = {
                         try await WorldDefinitions.read($0, dimensions: $1, library: $2).value
                     }) async throws -> Self {
        while true {
            try Task.checkCancellation()
            let source = WorldGameAssetSource(generation: minecraft.generation)
            let library = await minecraft.library()
            try Task.checkCancellation()
            guard source.generation == minecraft.generation else { continue }
            do {
                let definitions = try await readDefinitions(snapshot.world, snapshot.dimensions, library?.data)
                try Task.checkCancellation()
                guard source.generation == minecraft.generation else { continue }
                var details = snapshot.details
                details.definitions = definitions
                let prepared = WorldSnapshot(access: snapshot.access, world: snapshot.world, dimensions: snapshot.dimensions,
                    dimensionDocuments: snapshot.dimensionDocuments, players: snapshot.players, details: details)
                return Self(snapshot: prepared, source: source, library: library)
            } catch {
                try Task.checkCancellation()
                // Removing access retires the old actor while its read is draining. Retry with
                // the new source rather than publishing that result or failing the document.
                guard source.generation == minecraft.generation else { continue }
                throw error
            }
        }
    }
}
