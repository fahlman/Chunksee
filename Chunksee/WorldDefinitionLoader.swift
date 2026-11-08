import ChunkseeKit
import Foundation
import Observation

/// Definitions and players interpreted with them have one publication. Independent saved-version
/// metadata can advance even when the dependent player read needs to be retried.
@Observable
final class WorldDefinitionLoader: PlayerSnapshotSource {
    nonisolated struct Facts: Sendable {
        var definitions: WorldDefinitions
        let borders: [String: WorldBorder]
        let players: PlayerSnapshot
        /// The game source of the completed definition/player read, retained during replacement.
        /// Prepared new dimensions may extend settings before the next complete read.
        let source: WorldGameDataSource.Identity
    }

    nonisolated struct Value: Sendable {
        var facts: Facts?
        var savedVersion: SavedMinecraftVersion
    }

    nonisolated private struct DimensionInput: Equatable, Sendable {
        let settings: DimensionSettings?
    }

    nonisolated private struct Source: Equatable, Sendable {
        var game: WorldGameDataSource
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

    typealias ReadDefinitions = @Sendable (World, GameDataLibrary?) async throws -> WorldResources.DefinitionSnapshot
    typealias ReadPlayers = @Sendable (World, [String: EnchantmentDefinition]) async -> [PlayerInfo]?

    /// The production operations and injected test operations are captured once per pass.
    private final class Reads {
        var definitions: ReadDefinitions = { try await WorldResources.readDefinitions($0, library: $1) }
        var players: ReadPlayers = { await WorldResources.readPlayers($0, enchantments: $1) }
    }

    private let loader: RefreshLoader<Source, Request, Value>
    private let reads: Reads
    private let unavailable: Value
    private let emptyPlayers = PlayerSnapshot([])
    @ObservationIgnored var published: @MainActor (Value) -> Void = { _ in }

    var value: Value { loader.value ?? unavailable }
    var snapshot: PlayerSnapshot { value.facts?.players ?? emptyPlayers }
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

    init(world: World, work: BackgroundWork, gameSource: WorldGameDataSource,
         dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions,
         borders: [String: WorldBorder], players: [PlayerInfo], savedVersion: SavedMinecraftVersion) {
        let reads = Reads()
        self.reads = reads
        unavailable = Value(facts: nil, savedVersion: savedVersion)
        let source = Source(game: gameSource,
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        let initial = Value(facts: Facts(definitions: definitions, borders: borders,
            players: PlayerSnapshot(players), source: source.game.identity), savedVersion: savedVersion)
        loader = RefreshLoader(partialRead: { source, request, previous in
            let readDefinitions = await reads.definitions, readPlayers = await reads.players
            try Task.checkCancellation()
            switch request {
            case .definitions:
                guard case .loaded(let library) = source.game.selection else { throw CancellationError() }
                let updated = try await readDefinitions(world, library)
                try Task.checkCancellation()
                let players = await readPlayers(world, updated.definitions.enchantments)
                try Task.checkCancellation()
                guard let players else {
                    return .partial(Value(facts: previous?.facts, savedVersion: updated.savedVersion))
                }
                return .complete(Value(facts: Facts(definitions: updated.definitions, borders: updated.borders,
                    players: PlayerSnapshot(players), source: source.game.identity), savedVersion: updated.savedVersion))
            case .players:
                guard let previous, let facts = previous.facts,
                      let players = await readPlayers(world, facts.definitions.enchantments) else {
                    throw CancellationError()
                }
                return .complete(Value(facts: Facts(definitions: facts.definitions, borders: facts.borders,
                    players: PlayerSnapshot(players), source: facts.source), savedVersion: previous.savedVersion))
            }
        }, work: work, priority: .utility, whenInactive: .finish, source: source, initialValue: initial,
            firstRequest: .definitions, merge: { $0.merging($1) }, retainingValue: { value, previous, current in
                var retained = value
                // An unread unknown would discard reader caches and the user's Height choice.
                // Keep the complete facts with their original provenance until a replacement
                // succeeds; RefreshLoader still cancels and rejects every retired in-flight read.
                let added = Set(current.preparedDimensions.keys).subtracting(previous.preparedDimensions.keys)
                for id in added {
                    retained.facts?.definitions.dimensionSettings[id] = current.preparedDimensions[id]?.settings
                }
                return retained
            })
        loader.published = { [weak self] _, current in
            guard let self, !self.isClosed else { return }
            self.published(current.value ?? self.unavailable)
        }
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
