import ChunkseeKit
import Foundation
import Observation

/// Definitions and players interpreted with them have one publication. Independent saved facts
/// belong to WorldInfoSnapshot and never wait for this dependent pair.
@Observable
final class WorldDefinitionLoader: PlayerSnapshotSource {
    nonisolated struct Facts: Sendable {
        var definitions: WorldDefinitions
        let players: PlayerSnapshot
        let enchantmentNames: GameNames.Enchantments
        /// The game source of the completed definition/player read, retained during replacement.
        /// Prepared new dimensions may extend settings before the next complete read.
        let source: WorldGameDataSource.Identity

        init(definitions: WorldDefinitions, players: PlayerSnapshot, source: WorldGameDataSource.Identity,
             previous: Self?) {
            self.definitions = definitions
            self.players = players
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

    nonisolated private enum Request: Sendable {
        case players
        case definitions

        func merging(_ newer: Self) -> Self {
            if case .definitions = newer { return newer }
            return self
        }
    }

    typealias ReadDefinitions = @Sendable (World, GameDataLibrary?) async throws -> WorldDefinitions
    typealias ReadPlayers = @Sendable (World, [String: EnchantmentDefinition]) async -> [PlayerInfo]?

    /// The production operations and injected test operations are captured once per pass.
    private final class Reads {
        var definitions: ReadDefinitions = { try await WorldResources.readDefinitions($0, library: $1) }
        var players: ReadPlayers = { await WorldResources.readPlayers($0, enchantments: $1) }
    }

    private let loader: RefreshLoader<Source, Request, Facts>
    private let reads: Reads
    private let emptyPlayers = PlayerSnapshot([])
    @ObservationIgnored var published: @MainActor (Facts?) -> Void = { _ in }

    var value: Facts? { loader.value }
    var snapshot: PlayerSnapshot { value?.players ?? emptyPlayers }
    var work: BackgroundWork.Scope { loader.work }
    var isClosed: Bool { loader.isClosed }
    var readDefinitions: ReadDefinitions {
        get { reads.definitions }
        set { reads.definitions = newValue }
    }
    var readPlayers: ReadPlayers {
        get { reads.players }
        set { reads.players = newValue }
    }

    init(world: WorldReadSource, work: BackgroundWork, gameSource: WorldGameDataSource,
         dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions,
         players: [PlayerInfo]) {
        let reads = Reads()
        self.reads = reads
        let source = Source(game: gameSource, world: world,
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        let initial = Facts(definitions: definitions, players: PlayerSnapshot(players), source: source.game.identity, previous: nil)
        loader = RefreshLoader(partialRead: { source, request, previous in
            let readDefinitions = await reads.definitions, readPlayers = await reads.players
            try Task.checkCancellation()
            switch request {
            case .definitions:
                guard case .loaded(let library) = source.game.selection else { throw CancellationError() }
                let updated = try await readDefinitions(source.world.world, library)
                try Task.checkCancellation()
                guard let players = await readPlayers(source.world.world, updated.enchantments) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return .complete(Facts(definitions: updated, players: PlayerSnapshot(players), source: source.game.identity,
                    previous: previous))
            case .players:
                guard let previous,
                      let players = await readPlayers(source.world.world, previous.definitions.enchantments) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return .complete(Facts(definitions: previous.definitions,
                    players: PlayerSnapshot(players), source: previous.source, previous: previous))
            }
        }, work: work, priority: .utility, whenInactive: .finish, source: source, initialValue: initial,
            firstRequest: .definitions, merge: { $0.merging($1) }, retainingValue: { value, previous, current in
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
                      dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions, players: [PlayerInfo]) {
        let source = Source(game: gameSource, world: world,
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        loader.replace(source: source,
            value: Facts(definitions: definitions, players: PlayerSnapshot(players), source: gameSource.identity, previous: nil))
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
        loader.request(source: source, isEnabled: source.game.selection.isLoaded, refresh: .definitions)
    }

    func refreshPlayers() {
        loader.request(source: loader.source, isEnabled: loader.source.game.selection.isLoaded, refresh: .players)
    }

    func close() { loader.close() }
}
