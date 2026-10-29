import ChunkseeKit
import Foundation
import Observation

/// Provenance of a definition request, also used by independently loaded advancement titles.
/// A newer request invalidates those titles immediately; it does not cancel a same-source pass.
nonisolated struct WorldDefinitionInput: Hashable, Sendable {
    private let identity = UUID()
}

/// Definitions and players interpreted with them have one publication. Independent saved-version
/// metadata can advance even when the dependent player read needs to be retried.
@Observable
final class WorldDefinitionLoader: PlayerSnapshotSource {
    nonisolated struct GameSource: Equatable, Sendable {
        let generation: UUID
        let libraryID: UUID?
    }

    nonisolated struct Facts: Sendable {
        var definitions: WorldDefinitions
        let borders: [String: WorldBorder]
        let players: PlayerSnapshot
        let input: WorldDefinitionInput
        /// The game source of the completed definition/player read, retained during replacement.
        /// Prepared new dimensions may extend settings before the next complete read.
        let source: GameSource
    }

    nonisolated struct Value: Sendable {
        var facts: Facts?
        var savedVersion: SavedMinecraftVersion
    }

    nonisolated private struct DimensionInput: Equatable, Sendable {
        let settings: DimensionSettings?
    }

    nonisolated private struct Source: Equatable, Sendable {
        var generation: UUID
        var library: GameDataLibrary?
        /// Prepared metadata supplies only newly included dimensions. Completed definition reads
        /// remain authoritative thereafter; old seed values never replace a later read.
        var preparedDimensions: [String: DimensionInput]

        var gameSource: GameSource { .init(generation: generation, libraryID: library?.identity) }

        func sharesGameData(with other: Self) -> Bool {
            generation == other.generation && library === other.library
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sharesGameData(with: rhs) && lhs.preparedDimensions == rhs.preparedDimensions
        }
    }

    nonisolated private enum Request: Sendable {
        case players
        case definitions(WorldDefinitionInput)

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
    private(set) var requestedDefinitions: WorldDefinitionInput
    @ObservationIgnored var published: @MainActor (Value, Value, Set<String>) -> Void = { _, _, _ in }

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

    init(world: World, work: BackgroundWork, generation: UUID, library: GameDataLibrary?,
         dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions,
         borders: [String: WorldBorder], players: [PlayerInfo], savedVersion: SavedMinecraftVersion) {
        let input = WorldDefinitionInput(), reads = Reads()
        self.reads = reads
        requestedDefinitions = input
        unavailable = Value(facts: nil, savedVersion: savedVersion)
        let source = Source(generation: generation, library: library,
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        let initial = Value(facts: Facts(definitions: definitions, borders: borders,
            players: PlayerSnapshot(players), input: input, source: source.gameSource), savedVersion: savedVersion)
        loader = RefreshLoader(partialRead: { source, request, previous in
            let readDefinitions = await reads.definitions, readPlayers = await reads.players
            try Task.checkCancellation()
            switch request {
            case .definitions(let input):
                let updated = try await readDefinitions(world, source.library)
                try Task.checkCancellation()
                let players = await readPlayers(world, updated.definitions.enchantments)
                try Task.checkCancellation()
                guard let players else {
                    return .partial(Value(facts: previous?.facts, savedVersion: updated.savedVersion))
                }
                return .complete(Value(facts: Facts(definitions: updated.definitions, borders: updated.borders,
                    players: PlayerSnapshot(players), input: input, source: source.gameSource), savedVersion: updated.savedVersion))
            case .players:
                guard let previous, let facts = previous.facts,
                      let players = await readPlayers(world, facts.definitions.enchantments) else {
                    throw CancellationError()
                }
                return .complete(Value(facts: Facts(definitions: facts.definitions, borders: facts.borders,
                    players: PlayerSnapshot(players), input: facts.input, source: facts.source), savedVersion: previous.savedVersion))
            }
        }, work: work, priority: .utility, whenInactive: .finish, source: source, initialValue: initial,
            firstRequest: .definitions(input), merge: { $0.merging($1) }, retainingValue: { value, previous, current in
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
        loader.published = { [weak self] previous, current in
            guard let self, !self.isClosed else { return }
            let added = Set(current.source.preparedDimensions.keys).subtracting(previous.source.preparedDimensions.keys)
            self.published(previous.value ?? self.unavailable, current.value ?? self.unavailable, added)
        }
    }

    func refreshDefinitions(generation: UUID, library: GameDataLibrary?) {
        var source = loader.source
        source.generation = generation
        source.library = library
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
        let input = WorldDefinitionInput()
        requestedDefinitions = input
        // A synchronous title observer can request a newer source or close the world.
        guard !isClosed, requestedDefinitions == input else { return }
        loader.request(source: source, isEnabled: true, refresh: .definitions(input))
    }

    func refreshPlayers() {
        loader.request(source: loader.source, isEnabled: true, refresh: .players)
    }

    func close() { loader.close() }
}
