import ChunkseeKit
import Foundation
import Observation

/// Definitions publish independently of saved players. Health resolves the saved inputs against
/// this snapshot; a failed player read must not hold back a successful definition refresh.
@Observable
final class WorldDefinitionLoader {
    nonisolated struct Facts: Sendable {
        var definitions: WorldDefinitions
        let enchantmentNames: GameNames.Enchantments
        /// The game source that supplied these facts, retained during replacement.
        /// Prepared new dimensions may extend settings before the next complete read.
        let source: WorldGameDataSource.Identity

        init(definitions: WorldDefinitions, source: WorldGameDataSource.Identity,
             previous: Self?) {
            self.definitions = definitions
            self.source = source
            enchantmentNames = (previous?.enchantmentNames ?? .empty).replacing(with: definitions.enchantments)
        }
    }

    nonisolated private struct DimensionInput: Equatable, Sendable {
        let settings: DimensionSettings?
    }

    nonisolated private struct Source: Equatable, Sendable {
        var game: WorldGameDataSource
        let world: WorldReadSource
        /// Prepared metadata supplies only newly included dimensions. Completed definition reads
        /// remain authoritative thereafter; old seed values never replace a later read.
        var preparedDimensions: [String: DimensionInput]
    }

    typealias ReadDefinitions = @Sendable (World, GameDataLibrary?, WorldDefinitions?) async throws -> RefreshRead<WorldDefinitions>

    /// The production operations and injected test operations are captured once per pass.
    private final class Reads {
        var definitions: ReadDefinitions = { try await WorldResources.readDefinitions($0, library: $1, retaining: $2) }
    }

    private let loader: RefreshLoader<Source, RefreshInvalidation, Facts>
    private let reads: Reads
    @ObservationIgnored var published: @MainActor (Facts?) -> Void = { _ in }

    var value: Facts? { loader.value }
    var work: BackgroundWork.Scope { loader.work }
    var isClosed: Bool { loader.isClosed }
    var readDefinitions: ReadDefinitions {
        get { reads.definitions }
        set { reads.definitions = newValue }
    }

    init(world: WorldReadSource, work: BackgroundWork, gameSource: WorldGameDataSource,
         dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions) {
        let reads = Reads()
        self.reads = reads
        let source = Source(game: gameSource, world: world,
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        let initial = Facts(definitions: definitions, source: source.game.identity, previous: nil)
        loader = RefreshLoader(partialRead: { source, _, previous in
            let readDefinitions = await reads.definitions
            try Task.checkCancellation()
            guard case .loaded(let library) = source.game.selection else { throw CancellationError() }
            let compatible = previous?.source == source.game.identity ? previous?.definitions : nil
            let updated = try await readDefinitions(source.world.world, library, compatible)
            try Task.checkCancellation()
            if !updated.isComplete, let previous, previous.source != source.game.identity {
                // A partial replacement cannot mix old categories into a new source identity.
                // Retain the coherent old snapshot until the replacement succeeds.
                return .partial(previous)
            }
            let facts = Facts(definitions: updated.value, source: source.game.identity, previous: previous)
            return updated.isComplete ? .complete(facts) : .partial(facts)
        }, work: work, priority: .utility, whenInactive: .finish, source: source, initialValue: initial,
            firstRequest: .refresh, merge: { _, newer in newer }, retainingValue: { value, previous, current in
                guard previous.world == current.world else { return nil }
                var retained = value
                // An unread unknown would discard reader caches and the user's Height choice.
                // Keep the complete facts with their original provenance until a replacement
                // succeeds; RefreshLoader still cancels and rejects every retired in-flight read.
                let added = Set(current.preparedDimensions.keys).subtracting(previous.preparedDimensions.keys)
                for id in added {
                    retained.definitions.dimensionSettings[id] = current.preparedDimensions[id]?.settings
                }
                return retained
            })
        loader.published = { [weak self] _, current in
            guard let self, !self.isClosed else { return }
            self.published(current.value)
        }
    }

    func replaceWorld(_ world: WorldReadSource, gameSource: WorldGameDataSource,
                      dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions) {
        let source = Source(game: gameSource, world: world,
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        loader.replace(source: source,
            value: Facts(definitions: definitions, source: gameSource.identity, previous: nil))
    }

    func refreshDefinitions(gameSource: WorldGameDataSource) {
        var source = loader.source
        source.game = gameSource
        requestDefinitions(source: source)
    }

    /// Prepared new-dimension settings are a source addition, not another editable definition store.
    func include(_ dimensions: [ChunkseeKit.Dimension], settings: [String: DimensionSettings]) {
        var source = loader.source
        for dimension in dimensions {
            source.preparedDimensions[dimension.id] = DimensionInput(settings: settings[dimension.id])
        }
        requestDefinitions(source: source)
    }

    private func requestDefinitions(source: Source) {
        guard !isClosed else { return }
        // An unread selection cannot yet say which definitions are missing. Source
        // replacement and late-publication rejection belong to the shared loader.
        loader.request(source: source, isEnabled: source.game.selection.isLoaded, refresh: .refresh)
    }

    func close() { loader.close() }
}
