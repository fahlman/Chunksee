import ChunkseeKit
import Foundation
import Observation

/// One permission and bookmark for the installed game's name caches and assets.
/// Reads retain their access until they finish, even when Settings removes the folder.
@Observable
final class MinecraftResources {
    enum Change { case source, artwork }

    private(set) var generation = UUID()
    var usesGameArtwork: Bool {
        didSet {
            guard usesGameArtwork != oldValue else { return }
            defaults.set(usesGameArtwork, forKey: Self.artworkKey)
            for observer in observers.values { observer(.artwork) }
        }
    }
    var folder: URL? { access?.url }
    private(set) var access: WorldReadAccess?
    private let defaults: UserDefaults
    private let work = BackgroundWork()
    @ObservationIgnored private lazy var reads = work.makeScope()
    private var libraries = GameResourceLibraries()
    @ObservationIgnored private var observers: [UUID: (Change) -> Void] = [:]
    private static let bookmarkKey = "minecraftFolderBookmark"
    private static let artworkKey = "usesGameArtwork"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        usesGameArtwork = defaults.object(forKey: Self.artworkKey) as? Bool ?? true
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale) else {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        access = WorldReadAccess(url)
    }

    isolated deinit { work.close() }

    func choose(_ url: URL) {
        retire()
        access = WorldReadAccess(url)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        for observer in observers.values { observer(.source) }
    }

    func forget() {
        retire()
        for observer in observers.values { observer(.source) }
    }

    func observeChanges(_ action: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    private func retire() {
        generation = UUID()
        reads.cancel()
        let previousLibraries = libraries, previousAccess = access
        access = nil
        libraries = GameResourceLibraries()
        // Hidden native tabs may not run a view task when the generation changes. Retire all
        // previous readers here, keeping permission until their current actor work finishes.
        work.start(priority: .utility) {
            await previousLibraries.close()
            withExtendedLifetime(previousAccess) {}
        }
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    /// This is the only artwork-policy decision; the data handle exposes no artwork methods.
    func artwork(for library: GameResourceLibrary?) -> GameArtworkLibrary? {
        usesGameArtwork ? library?.artwork : nil
    }

    func library() async -> GameResourceLibrary? {
        guard let access, !Task.isCancelled else { return nil }
        let generation = generation, libraries = libraries
        var result: GameResourceLibrary?
        guard let task = reads.start(priority: .utility, operation: { [weak self] in
            let loaded = try? await libraries.library(under: access.url)
            withExtendedLifetime(access) {}
            guard !Task.isCancelled, self?.generation == generation else { return }
            result = loaded
        }) else { return nil }
        await task.value
        return Task.isCancelled || self.generation != generation ? nil : result
    }

    func waitUntilIdle() async { await work.waitUntilFinished() }
}

/// Jar reads and validation are serial off-main. Live windows using the same file share one
/// immutable archive and picture cache; a closed world's library need not remain in memory.
actor GameResourceLibraries {
    nonisolated private struct Identity: Hashable {
        let url: URL
        let size: Int
        let modified: Int64
    }
    nonisolated private final class WeakLibrary {
        weak var value: GameResourceLibrary?
        weak var data: GameDataLibrary?
        weak var artwork: GameArtworkLibrary?
        init(_ value: GameResourceLibrary) {
            self.value = value
            data = value.data
            artwork = value.artwork
        }
    }
    private var live: [Identity: WeakLibrary] = [:]
    private var versions: [Identity: GameAssets.Version] = [:]
    private var isClosed = false

    func close() async {
        isClosed = true
        // A view may outlive its world's source handle. Track each reader independently so
        // removing permission also retires those retained capabilities before releasing access.
        let readers = live.values.map { (data: $0.data, artwork: $0.artwork) }
        live.removeAll()
        versions.removeAll()
        for reader in readers {
            await reader.artwork?.close()
            await reader.data?.close()
        }
    }

    func library(under folder: URL) throws -> GameResourceLibrary? {
        try Task.checkCancellation()
        guard !isClosed else { return nil }
        let directory = folder.appendingPathComponent("versions", isDirectory: true)
        let installed = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        live = live.filter { $0.value.data != nil }
        var seen: Set<Identity> = []
        var selected: (key: Identity, version: GameAssets.Version, assets: GameAssets?)?
        for entry in installed.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let url = entry.appendingPathComponent(entry.lastPathComponent + ".jar").resolvingSymlinksInPath()
            // Bound one archive, and retain at most the best uncached candidate during discovery.
            guard let stamp = CacheKey.fileStamp(for: url), (1...134_217_728).contains(stamp.size) else { continue }
            let key = Identity(url: url, size: stamp.size, modified: stamp.modified)
            seen.insert(key)
            let assets: GameAssets?
            let version: GameAssets.Version
            if let known = versions[key] {
                assets = nil
                version = known
            } else {
                guard let opened = try? GameAssets(contentsOf: url),
                      let after = CacheKey.fileStamp(for: url), after.size == stamp.size, after.modified == stamp.modified else { continue }
                assets = opened
                version = opened.version
                versions[key] = version
            }
            if let best = selected, !Self.prefers(version, over: best.version) { continue }
            selected = (key, version, assets)
        }
        versions = versions.filter { seen.contains($0.key) }
        guard let selected else { return nil }
        let key = selected.key
        guard let stamp = CacheKey.fileStamp(for: key.url), stamp.size == key.size, stamp.modified == key.modified else { return nil }
        if let cached = live[key]?.value { return cached }
        if let data = live[key]?.data, let artwork = live[key]?.artwork {
            let library = GameResourceLibrary(data: data, artwork: artwork)
            live[key]?.value = library
            return library
        }
        guard let assets = try selected.assets ?? GameAssets(contentsOf: key.url),
              let after = CacheKey.fileStamp(for: key.url), after.size == stamp.size, after.modified == stamp.modified else { return nil }
        try Task.checkCancellation()
        let data = live[key]?.data ?? GameDataLibrary(assets: assets,
            sourceKey: CacheKey.hash("\(key.url.absoluteString)|\(stamp.size)|\(stamp.modified)|\(assets.version.id)|\(assets.version.dataVersion)"))
        let pictures = GameResourceLibrary(data: data, artwork: GameArtworkLibrary(assets: assets, data: data))
        live[key] = WeakLibrary(pictures)
        return pictures
    }

    /// The jar declares whether it is a release and when it was built. Missing dates use the
    /// saved-format revision as an ordering fallback, never a version-name guess or world gate.
    nonisolated static func prefers(_ candidate: GameAssets.Version, over current: GameAssets.Version) -> Bool {
        if (candidate.isStable == true) != (current.isStable == true) { return candidate.isStable == true }
        if let a = candidate.buildTime, let b = current.buildTime, a != b { return a > b }
        return candidate.dataVersion > current.dataVersion
    }
}

/// Shared source lifetime, with an artwork handle visible only to MinecraftResources.
/// Consumers receive data directly and ask that owner for the optional artwork capability.
nonisolated final class GameResourceLibrary: Sendable {
    let data: GameDataLibrary
    fileprivate let artwork: GameArtworkLibrary
    var identity: UUID { data.identity }
    var sourceKey: String { data.sourceKey }
    var version: GameAssets.Version { data.version }

    init(assets: GameAssets, sourceKey: String, readTexture: @escaping GameArtworkLibrary.TextureRead = { $0.texture($1) }) {
        data = GameDataLibrary(assets: assets, sourceKey: sourceKey)
        artwork = GameArtworkLibrary(assets: assets, data: data, readTexture: readTexture)
    }

    fileprivate init(data: GameDataLibrary, artwork: GameArtworkLibrary) {
        self.data = data
        self.artwork = artwork
    }
}
