import ChunkseeKit
import Foundation

/// The game source and the opening facts it interprets travel together. Region readers must
/// never start with a temporary option set that evicts the same world's completed disk cache.
struct WorldPreparation {
    let snapshot: WorldSnapshot
    let source: WorldGameAssetSource
    let library: GameResourceLibrary?

    private init(snapshot: WorldSnapshot, source: WorldGameAssetSource, library: GameResourceLibrary?) {
        self.snapshot = snapshot
        self.source = source
        self.library = library
    }

    static func read(_ snapshot: WorldSnapshot, minecraft: MinecraftResources,
                     readGameData: @escaping @Sendable (WorldSnapshot, GameDataLibrary) async throws -> WorldSnapshot = readingGameData) async throws -> Self {
        let trace = UUID()
        OpeningTrace.event("prepare.start prepare=\(trace) world=\(OpeningTrace.path(snapshot.access.url))")
        defer { OpeningTrace.event("prepare.exit prepare=\(trace) cancelled=\(Task.isCancelled)") }
        while true {
            try Task.checkCancellation()
            let source = WorldGameAssetSource(generation: minecraft.generation)
            OpeningTrace.event("prepare.library.wait prepare=\(trace)")
            let library = await minecraft.library()
            OpeningTrace.event("prepare.library.ready prepare=\(trace) available=\(library != nil)")
            try Task.checkCancellation()
            guard source.generation == minecraft.generation else { continue }
            do {
                let prepared: WorldSnapshot
                if let library {
                    OpeningTrace.event("prepare.definitions.wait prepare=\(trace)")
                    prepared = try await readGameData(snapshot, library.data)
                    OpeningTrace.event("prepare.definitions.ready prepare=\(trace)")
                }
                else { prepared = snapshot }
                try Task.checkCancellation()
                guard source.generation == minecraft.generation else { continue }
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

    @concurrent
    nonisolated static func readingGameData(_ snapshot: WorldSnapshot, library: GameDataLibrary) async throws -> WorldSnapshot {
        var details = snapshot.details
        details.definitions = try await library.definitions(in: snapshot.world)
        let players = snapshot.world.players(enchantments: details.definitions.enchantments)
        try Task.checkCancellation()
        return WorldSnapshot(access: snapshot.access, world: snapshot.world, dimensions: snapshot.dimensions,
                             dimensionDocuments: snapshot.dimensionDocuments, players: players, details: details)
    }
}
