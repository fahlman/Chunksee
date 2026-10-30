import ChunkseeKit
import Foundation
import Observation

/// The world owns one read and completed value per requested player. Windows own only handles.
final class PlayerRecordStore {
    nonisolated struct GameSource: Equatable, Sendable {
        let generation: UUID
        let selection: WorldDefinitionLoader.GameSelection
    }

    nonisolated fileprivate struct Source: Equatable, Sendable {
        let game: GameSource?
        let name: String?
        var isReady: Bool { game?.selection.isLoaded == true }
    }

    typealias Read = @Sendable (World, UUID, String?, GameDataLibrary?, PlayerRecords?) async throws -> RefreshRead<PlayerRecords>
    var read: Read = { try await PlayerRecords.load(from: $0, uuid: $1, name: $2, library: $3, previous: $4) }

    fileprivate final class Entry {
        let loader: RefreshLoader<Source, RefreshInvalidation, PlayerRecords>
        var users = 0
        init(_ loader: RefreshLoader<Source, RefreshInvalidation, PlayerRecords>) { self.loader = loader }
    }

    private let world: World
    private let work: BackgroundWork
    private let names: PlayerNames
    private let gameSource: @MainActor () -> GameSource?
    private var entries: [UUID: Entry] = [:]
    private var isClosed = false

    init(world: World, work: BackgroundWork, names: PlayerNames,
         gameSource: @escaping @MainActor () -> GameSource?) {
        self.world = world
        self.work = work
        self.names = names
        self.gameSource = gameSource
        observeSources()
    }

    func acquire(_ uuid: UUID) -> Handle? {
        guard !isClosed, !work.isClosed else { return nil }
        let entry: Entry
        if let existing = entries[uuid] {
            entry = existing
        } else {
            let loader = RefreshLoader<Source, RefreshInvalidation, PlayerRecords>(partialRead: { [weak self, world] source, _, previous in
                guard case .loaded(let library) = source.game?.selection, let read = await self?.read else {
                    throw CancellationError()
                }
                return try await read(world, uuid, source.name, library, previous)
            }, work: work, priority: .utility, whenInactive: .cancel, source: source(for: uuid),
                firstRequest: .refresh, merge: { _, _ in .refresh }, retainingValue: { previous, old, new in
                    // Game replacement changes title definitions, not this player's saved progress.
                    // A legacy-name replacement can also change which statistics file is read.
                    guard new.game != nil else { return nil }
                    var retained = previous
                    if let name = previous.statisticsName, name != new.name {
                        retained.statistics = nil
                        retained.statisticsName = nil
                    }
                    if old.game != new.game { retained.advancementDefinitions = [:] }
                    return retained
                })
            entry = Entry(loader)
            entries[uuid] = entry
        }
        entry.users += 1
        update(entry, uuid: uuid, reread: false)
        return Handle(uuid: uuid, entry: entry, owner: self)
    }

    /// Save notifications are demand, not evidence that any displayed title has changed.
    func refresh() {
        guard !isClosed else { return }
        for (uuid, entry) in entries { update(entry, uuid: uuid, reread: true) }
    }

    private func source(for uuid: UUID) -> Source {
        Source(game: gameSource(), name: names.name(for: uuid))
    }

    private func update(_ entry: Entry, uuid: UUID, reread: Bool) {
        let source = source(for: uuid)
        entry.loader.request(source: source, isEnabled: source.isReady, reread: reread)
    }

    /// All sources are main-actor publications. didSet invalidates old work synchronously,
    /// including when a window is hidden, without a view task or another request counter.
    private func observeSources() {
        guard !isClosed else { return }
        withObservationTracking(options: [.didSet]) {
            _ = gameSource()
            _ = names.local
            _ = names.online
        } onChange: { [weak self] event in
            event.cancel()
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.observeSources()
                for (uuid, entry) in self.entries { self.update(entry, uuid: uuid, reread: false) }
            }
        }
    }

    private func release(_ uuid: UUID, entry: Entry) {
        guard entries[uuid] === entry else { return }
        entry.users -= 1
        if entry.users == 0 {
            entries[uuid] = nil
            entry.loader.close()
        }
    }

    func waitUntilFinished() async {
        await work.waitUntilFinished(in: entries.values.map { $0.loader.work })
    }

    func close() {
        isClosed = true
        for entry in entries.values { entry.loader.close() }
        entries = [:]
    }

    final class Handle {
        let uuid: UUID
        private let entry: Entry
        private weak var owner: PlayerRecordStore?
        var records: PlayerRecords? { owner == nil ? nil : entry.loader.value }

        fileprivate init(uuid: UUID, entry: Entry, owner: PlayerRecordStore) {
            self.uuid = uuid
            self.entry = entry
            self.owner = owner
        }

        func close() {
            owner?.release(uuid, entry: entry)
            owner = nil
        }

        isolated deinit { close() }
    }
}
