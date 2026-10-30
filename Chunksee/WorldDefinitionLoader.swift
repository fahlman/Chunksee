import ChunkseeKit
import Foundation
import Observation

/// Definitions and players interpreted with them have one publication. Independent saved facts
/// belong to WorldInfoSnapshot and never wait for this dependent pair.
@Observable
final class WorldDefinitionLoader: PlayerSnapshotSource {
    nonisolated enum GameSelection: Equatable, Sendable {
        case loading
        case loaded(GameDataLibrary?)

        var isLoaded: Bool {
            if case .loaded = self { true } else { false }
        }

        var libraryID: UUID? {
            if case .loaded(let library) = self { library?.identity } else { nil }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): true
            case (.loaded(let first), .loaded(let second)): first === second
            default: false
            }
        }
    }

    nonisolated struct GameSource: Equatable, Sendable {
        let generation: UUID
        let libraryID: UUID?
    }

    nonisolated struct Facts: Sendable {
        var definitions: WorldDefinitions
        let players: PlayerSnapshot
        /// The game source of the completed definition/player read, retained during replacement.
        /// Prepared new dimensions may extend settings before the next complete read.
        let source: GameSource
    }

    nonisolated private struct DimensionInput: Equatable, Sendable {
        let settings: DimensionSettings?
    }

    nonisolated private struct Source: Equatable, Sendable {
        var generation: UUID
        var selection: GameSelection
        /// Prepared metadata supplies only newly included dimensions. Completed definition reads
        /// remain authoritative thereafter; old seed values never replace a later read.
        var preparedDimensions: [String: DimensionInput]

        var gameSource: GameSource { .init(generation: generation, libraryID: selection.libraryID) }

        func sharesGameData(with other: Self) -> Bool {
            generation == other.generation && selection == other.selection
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sharesGameData(with: rhs) && lhs.preparedDimensions == rhs.preparedDimensions
        }
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

    init(world: World, work: BackgroundWork, generation: UUID, library: GameDataLibrary?,
         dimensions: [ChunkseeKit.Dimension], definitions: WorldDefinitions,
         players: [PlayerInfo]) {
        let reads = Reads()
        self.reads = reads
        let source = Source(generation: generation, selection: .loaded(library),
            preparedDimensions: Dictionary(uniqueKeysWithValues: dimensions.map {
                ($0.id, DimensionInput(settings: definitions.dimensionSettings[$0.id]))
            }))
        let initial = Facts(definitions: definitions, players: PlayerSnapshot(players), source: source.gameSource)
        loader = RefreshLoader(partialRead: { source, request, previous in
            let readDefinitions = await reads.definitions, readPlayers = await reads.players
            try Task.checkCancellation()
            switch request {
            case .definitions:
                guard case .loaded(let library) = source.selection else { throw CancellationError() }
                let updated = try await readDefinitions(world, library)
                try Task.checkCancellation()
                guard let players = await readPlayers(world, updated.enchantments) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return .complete(Facts(definitions: updated, players: PlayerSnapshot(players), source: source.gameSource))
            case .players:
                guard let previous,
                      let players = await readPlayers(world, previous.definitions.enchantments) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return .complete(Facts(definitions: previous.definitions,
                    players: PlayerSnapshot(players), source: previous.source))
            }
        }, work: work, priority: .utility, whenInactive: .finish, source: source, initialValue: initial,
            firstRequest: .definitions, merge: { $0.merging($1) }, retainingValue: { value, previous, current in
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

    func refreshDefinitions(generation: UUID, selection: GameSelection) {
        var source = loader.source
        source.generation = generation
        source.selection = selection
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
        loader.request(source: source, isEnabled: source.selection.isLoaded, refresh: .definitions)
    }

    func refreshPlayers() {
        loader.request(source: loader.source, isEnabled: loader.source.selection.isLoaded, refresh: .players)
    }

    func close() { loader.close() }
}
