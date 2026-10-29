import ChunkseeKit
import Foundation
import Observation

/// Preferences shared by all documents, and the worlds whose dimensions are open. macOS owns
/// open documents and Open Recent.
@Observable
final class AppModel {
    let names: PlayerNames
    let savedSearches: SavedSearches
    let worldFolders: WorldFolders
    @ObservationIgnored private var openWorlds: [String: WeakResources] = [:]
    private var openingReads: [String: OpeningRead] = [:]
    private let defaults: UserDefaults
    private let cacheRoot: URL?
    private let readWorld: @Sendable (URL) async throws -> WorldSnapshot
    private let readRegion: RegionReader.Read

    /// Readers waiting for initial metadata; returned snapshots hold their own opening instead.
    var openingRequestCount: Int { openingReads.values.reduce(0) { $0 + $1.requests.count } }

    private struct OpeningRead {
        let id: UUID
        let task: Task<WorldOpening, any Error>
        var requests: [UUID: URL] = [:]
    }

    private final class WeakResources {
        weak var value: WorldResources?
        init(_ value: WorldResources) { self.value = value }
    }

    init(defaults: UserDefaults, cacheRoot: URL?,
         readWorld: @escaping @Sendable (URL) async throws -> WorldSnapshot = { try await WorldSnapshot.read($0) },
         readRegion: @escaping RegionReader.Read = RegionReader.scan) {
        self.defaults = defaults
        self.cacheRoot = cacheRoot
        self.readWorld = readWorld
        self.readRegion = readRegion
        // The old window model's bookmarks cannot serve native document restoration.
        for key in ["openWorlds", "recentWorlds", "lastWorldBookmark"] {
            defaults.removeObject(forKey: key)
        }
        names = PlayerNames(defaults: defaults)
        savedSearches = SavedSearches(defaults: defaults)
        worldFolders = WorldFolders(defaults: defaults)
    }

    /// The open resources of a snapshot's world, which its other dimensions share, or new ones.
    func resources(for snapshot: WorldSnapshot, folder: WorldFolders.Folder) async throws -> WorldResources {
        var adopted = false
        let trace = UUID()
        OpeningTrace.event("resources.start resources=\(trace) world=\(OpeningTrace.path(folder.url))")
        defer { OpeningTrace.event("resources.exit resources=\(trace) adopted=\(adopted) cancelled=\(Task.isCancelled)") }
        defer { if !adopted { snapshot.access.release() } }
        try Task.checkCancellation()
        openWorlds = openWorlds.filter { $0.value.value.map { !$0.isClosed } ?? false }
        let key = snapshot.access.url.resolvingSymlinksInPath().path
        if let open = openWorlds[key]?.value,
           Set(snapshot.dimensions.map(\.id)).isSubset(of: Set(open.dimensions.map(\.id))) {
            return open
        }
        OpeningTrace.event("resources.prepare.wait resources=\(trace)")
        let prepared = try await WorldPreparation.read(snapshot, minecraft: names.minecraft)
        OpeningTrace.event("resources.prepare.ready resources=\(trace)")
        try Task.checkCancellation()
        // Another document may have finished opening this world while game data was loading.
        // Reuse it before creating any readers or starting another index.
        if let open = openWorlds[key]?.value, !open.isClosed {
            open.includeDimensions(from: prepared)
            return open
        }
        let resources = WorldResources(prepared: prepared, names: names, savedSearches: savedSearches,
                                       settings: WorldSettings(folder: folder, defaults: defaults), cacheRoot: cacheRoot,
                                       readRegion: readRegion)
        openWorlds[key] = WeakResources(resources)
        adopted = true
        return resources
    }

    /// Normal Quit flushes the live views before their debounced SwiftUI tasks are cancelled.
    func saveViews() {
        for world in openWorlds.values { world.value?.saveViews() }
    }

    /// URLs are resolved by the reader off the main actor, before looking up shared resources.
    func initialDimension(at documentURL: URL, in folder: WorldFolders.Folder) async throws -> DimensionSnapshot? {
        let opening = try await openingWorld(folder, documentURL: documentURL)
        do {
            try Task.checkCancellation()
            guard let resources = opening.resources else { throw CancellationError() }
            guard let dimensionID = resources.dimensionDocuments[documentURL.path] else {
                // A live catalog may predate a newly created dimension. Let the fresh reader
                // validate an unknown folder rather than treating the cached catalog as proof.
                opening.finish()
                return nil
            }
            return DimensionSnapshot(source: .opening(opening), folder: folder,
                                     dimensionID: dimensionID, documentURL: documentURL)
        } catch {
            opening.finish()
            throw error
        }
    }

    private func openingWorld(_ folder: WorldFolders.Folder, documentURL: URL) async throws -> WorldOpening {
        OpeningTrace.event("opening.start world=\(OpeningTrace.path(folder.url)) path=\(OpeningTrace.path(documentURL))")
        try Task.checkCancellation()
        let url = folder.url
        let key = url.path
        if let open = openWorlds[key]?.value, !open.isClosed { return try open.opening() }
        let pending: OpeningRead
        if let read = openingReads[key] { pending = read }
        else {
            let id = UUID(), read = readWorld
            // The task's result holds one opening until every awaiting requester has received
            // its own. A canceled requester therefore cannot close a sibling's new resources.
            let task = Task {
                OpeningTrace.event("opening.read.start opening=\(id)")
                defer { completeOpeningRead(key: key, generation: id) }
                let snapshot = try await read(url)
                OpeningTrace.event("opening.read.ready opening=\(id)")
                do {
                    try Task.checkCancellation()
                    guard let waiting = openingReads[key], waiting.id == id else { throw CancellationError() }
                    let paths = Set(snapshot.dimensionDocuments.keys)
                    // An invalid folder must not start background indexing just to be rejected.
                    guard waiting.requests.values.contains(where: { paths.contains($0.path) }) else { throw WorldOpenError.notADimension }
                }
                catch { snapshot.access.release(); throw error }
                return try await self.resources(for: snapshot, folder: folder).opening()
            }
            pending = OpeningRead(id: id, task: task)
            openingReads[key] = pending
        }
        let request = UUID(), generation = pending.id, task = pending.task
        openingReads[key]?.requests[request] = documentURL
        OpeningTrace.event("opening.join opening=\(generation) request=\(request) count=\(openingReads[key]?.requests.count ?? 0)")
        return try await withTaskCancellationHandler {
            defer { finishOpeningRead(request, key: key, generation: generation) }
            do {
                let holding = try await task.value
                OpeningTrace.event("opening.ready opening=\(generation) request=\(request) cancelled=\(Task.isCancelled)")
                try Task.checkCancellation()
                guard let resources = holding.resources else { throw CancellationError() }
                return try resources.opening()
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishOpeningRead(request, key: key, generation: generation) }
        }
    }

    private func finishOpeningRead(_ request: UUID, key: String, generation: UUID) {
        OpeningTrace.event("opening.finish opening=\(generation) request=\(request)")
        guard var pending = openingReads[key], pending.id == generation,
              pending.requests.removeValue(forKey: request) != nil else { return }
        if pending.requests.isEmpty {
            pending.task.cancel()
            openingReads[key] = nil
        } else { openingReads[key] = pending }
    }

    private func completeOpeningRead(key: String, generation: UUID) {
        OpeningTrace.event("opening.complete opening=\(generation)")
        if openingReads[key]?.id == generation { openingReads[key] = nil }
    }
}
