import ChunkseeKit
import Foundation
import Observation

/// One permission and bookmark for the installed game's name caches and assets.
/// Reads retain their access until they finish, even when Settings removes the folder.
@Observable
final class MinecraftResources {
    private(set) var generation = UUID()
    var folder: URL? { access?.url }
    private(set) var access: WorldReadAccess?
    private let defaults: UserDefaults
    private let work = BackgroundWork()
    @ObservationIgnored private lazy var reads = work.makeScope()
    private var libraries = GameAssetLibraries()
    private static let bookmarkKey = "minecraftFolderBookmark"

    init(defaults: UserDefaults) {
        self.defaults = defaults
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
        forget()
        access = WorldReadAccess(url)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    func forget() {
        generation = UUID()
        reads.cancel()
        let previousLibraries = libraries, previousAccess = access
        access = nil
        libraries = GameAssetLibraries()
        // Hidden native tabs may not run a view task when the generation changes. Retire all
        // previous readers here, keeping permission until their current actor work finishes.
        work.start(priority: .utility) {
            await previousLibraries.close()
            withExtendedLifetime(previousAccess) {}
        }
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    func pictures(for version: GameAssetVersion) async -> GameItemPictures? {
        guard let access, !Task.isCancelled else { return nil }
        let generation = generation, libraries = libraries
        var result: GameItemPictures?
        guard let task = reads.start(priority: .utility, operation: { [weak self] in
            let loaded = try? await libraries.pictures(for: version, under: access.url)
            withExtendedLifetime(access) {}
            guard !Task.isCancelled, self?.generation == generation else { return }
            result = loaded
        }) else { return nil }
        await task.value
        return Task.isCancelled || self.generation != generation ? nil : result
    }

    func waitUntilIdle() async { await work.waitUntilFinished() }
}

nonisolated struct GameAssetVersion: Hashable, Sendable {
    let name: String
    let dataVersion: Int32

    init?(name: String?, dataVersion: Int?) {
        guard let name, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              let dataVersion, let saved = Int32(exactly: dataVersion) else { return nil }
        self.name = name
        self.dataVersion = saved
    }
}

/// Jar reads and validation are serial off-main. Live windows using the same file share one
/// immutable archive and picture cache; a closed world's library need not remain in memory.
actor GameAssetLibraries {
    nonisolated private struct Identity: Hashable {
        let url: URL
        let size: Int
        let modified: Int64
    }
    nonisolated private final class WeakLibrary {
        weak var value: GameItemPictures?
        init(_ value: GameItemPictures) { self.value = value }
    }
    private var live: [Identity: WeakLibrary] = [:]
    private var isClosed = false

    func close() async {
        isClosed = true
        let pictures = live.values.compactMap(\.value)
        live.removeAll()
        for library in pictures { await library.close() }
    }

    func pictures(for version: GameAssetVersion, under folder: URL) throws -> GameItemPictures? {
        try Task.checkCancellation()
        guard !isClosed else { return nil }
        let url = folder.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version.name, isDirectory: true)
            .appendingPathComponent(version.name + ".jar").resolvingSymlinksInPath()
        // The ordinary client is about 41 MiB. A large or unrelated selected file must not
        // allocate arbitrary memory merely because an inventory became visible.
        guard let stamp = CacheKey.fileStamp(for: url), (1...134_217_728).contains(stamp.size) else { return nil }
        let key = Identity(url: url, size: stamp.size, modified: stamp.modified)
        live = live.filter { $0.value.value != nil }
        if let cached = live[key]?.value {
            return cached.version.id == version.name && cached.version.dataVersion == version.dataVersion ? cached : nil
        }
        guard let assets = try GameAssets(contentsOf: url), assets.version.id == version.name,
              assets.version.dataVersion == version.dataVersion,
              let after = CacheKey.fileStamp(for: url), after.size == stamp.size, after.modified == stamp.modified else { return nil }
        try Task.checkCancellation()
        let pictures = GameItemPictures(assets: assets)
        live[key] = WeakLibrary(pictures)
        return pictures
    }
}
