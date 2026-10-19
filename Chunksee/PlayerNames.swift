import Foundation
import ChunkseeKit
import Observation

/// Looks up a player's current name from Mojang's public profile service.
nonisolated struct MojangProfiles: Sendable {
    /// Fetches a URL; injectable so tests never touch the network.
    var fetch: @Sendable (URL) async throws -> (Data, Int) = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    enum LookupError: Error, Equatable {
        case unexpectedStatus(Int)
    }

    static func profileURL(for uuid: UUID) -> URL {
        let hex = uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return URL(string: "https://sessionserver.mojang.com/session/minecraft/profile/\(hex)")!
    }

    /// The player's current name, or `nil` when Mojang has no such profile (204/404).
    func name(for uuid: UUID) async throws -> String? {
        let (data, status) = try await fetch(Self.profileURL(for: uuid))
        switch status {
        case 200:
            struct Profile: Decodable { var name: String }
            return try JSONDecoder().decode(Profile.self, from: data).name
        case 204, 404:
            return nil
        default:
            throw LookupError.unexpectedStatus(status)
        }
    }
}

/// Inputs that require another name-source request; movement and inspector values do not.
struct PlayerNameRequest: Equatable {
    let folder: URL?
    let online: Bool
    let players: Set<UUID>
}

/// Player names shared by documents, with an app-wide work owner and independent source scopes.
/// Permissions and source identity still decide which results may be published.
@Observable
final class PlayerNames {
    private(set) var local: [UUID: String] = [:]
    private(set) var online: [UUID: String] = [:]
    private(set) var minecraftFolder: URL?

    /// Looking up a name sends that player's UUID to Mojang, only while this remains on.
    var looksUpOnline: Bool {
        didSet {
            defaults.set(looksUpOnline, forKey: Keys.looksUpOnline)
            if looksUpOnline != oldValue { cancelOnline() }
        }
    }

    private let defaults: UserDefaults
    private let mojang: MojangProfiles
    private let readCaches: @Sendable (URL) async -> [UUID: String]
    private let work: BackgroundWork
    private let localWork: BackgroundWork.Scope
    private let onlineWork: BackgroundWork.Scope
    @ObservationIgnored private var folderAccess: WorldReadAccess?
    @ObservationIgnored private var localGeneration = UUID()
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var onlineGeneration = UUID()
    @ObservationIgnored private var attempted: Set<UUID> = []

    private enum Keys {
        static let looksUpOnline = "looksUpPlayerNamesOnline"
        static let online = "onlinePlayerNames"
        static let folder = "minecraftFolderBookmark"
    }

    init(defaults: UserDefaults, mojang: MojangProfiles = MojangProfiles(),
         readCaches: @escaping @Sendable (URL) async -> [UUID: String] = PlayerNames.readLocalCaches) {
        let work = BackgroundWork()
        self.work = work
        localWork = work.makeScope()
        onlineWork = work.makeScope()
        self.defaults = defaults
        self.mojang = mojang
        self.readCaches = readCaches
        looksUpOnline = defaults.bool(forKey: Keys.looksUpOnline)
        if let saved = defaults.dictionary(forKey: Keys.online) as? [String: String] {
            online = Dictionary(uniqueKeysWithValues: saved.compactMap { key, name in UUID(uuidString: key).map { ($0, name) } })
        }
        restoreFolder()
    }

    isolated deinit {
        work.close()
    }

    func name(for uuid: UUID) -> String? { local[uuid] ?? online[uuid] }

    func request(for players: [PlayerInfo]) -> PlayerNameRequest {
        PlayerNameRequest(folder: minecraftFolder, online: looksUpOnline, players: Set(players.map(\.uuid)))
    }

    func load(_ request: PlayerNameRequest) async {
        guard request.folder == minecraftFolder, request.online == looksUpOnline, !Task.isCancelled else { return }
        await reloadLocal()
        guard request.folder == minecraftFolder, request.online == looksUpOnline, !Task.isCancelled else { return }
        await lookUp(request.players.sorted { $0.uuidString < $1.uuidString })
    }

    func chooseMinecraftFolder(_ url: URL) async {
        forgetMinecraftFolder()
        folderAccess = WorldReadAccess(url)
        minecraftFolder = url
        let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Keys.folder)
        await reloadLocal()
    }

    func forgetMinecraftFolder() {
        localGeneration = UUID()
        localWork.cancel()
        localTask = nil
        // A read already running retains its own access until it returns.
        folderAccess = nil
        minecraftFolder = nil
        local = [:]
        defaults.removeObject(forKey: Keys.folder)
    }

    private func restoreFolder() {
        guard let data = defaults.data(forKey: Keys.folder) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            defaults.removeObject(forKey: Keys.folder)
            return
        }
        folderAccess = WorldReadAccess(url)
        minecraftFolder = url
    }

    /// Pending reads belong to the shared source, including when a requesting view disappears.
    /// Only overlapping requests coalesce; a subsequent reload still rereads the local caches.
    func reloadLocal() async {
        guard let folder = minecraftFolder, let access = folderAccess, !Task.isCancelled else { return }
        if let pending = localTask {
            await pending.value
            return
        }
        localGeneration = UUID()
        let id = localGeneration, read = readCaches
        guard let task = localWork.start(priority: nil, operation: { [weak self] in
            defer { if self?.localGeneration == id { self?.localTask = nil } }
            let names = await read(folder)
            withExtendedLifetime(access) {}
            guard !Task.isCancelled, let self, self.localGeneration == id, self.minecraftFolder == folder else { return }
            self.local = names
        }) else { return }
        localTask = task
        await task.value
    }

    @concurrent
    private nonisolated static func readLocalCaches(_ folder: URL) async -> [UUID: String] {
        guard !Task.isCancelled else { return [:] }
        return UserCache.names(under: folder).mapValues(\.name)
    }

    /// Tries unknown UUIDs once per permission session. Each batch checks permission before
    /// sending the next request and before saving its answer, including after Clear Names.
    func lookUp(_ uuids: [UUID]) async {
        guard looksUpOnline, !Task.isCancelled else { return }
        let generation = onlineGeneration, mojang = mojang
        guard let task = onlineWork.start(priority: nil, operation: { [weak self] in
            for uuid in uuids {
                guard !Task.isCancelled, let self, self.looksUpOnline, self.onlineGeneration == generation else { return }
                guard self.name(for: uuid) == nil, self.attempted.insert(uuid).inserted else { continue }
                let found = try? await mojang.name(for: uuid)
                guard self.onlineGeneration == generation else { return }
                guard !Task.isCancelled, self.looksUpOnline else {
                    self.attempted.remove(uuid)
                    return
                }
                if let found {
                    self.online[uuid] = found
                    self.defaults.set(Dictionary(uniqueKeysWithValues: self.online.map { ($0.key.uuidString, $0.value) }),
                                      forKey: Keys.online)
                }
            }
        }) else { return }
        // Another document may already have skipped this UUID as attempted. Its name must still
        // arrive if this caller closes; permission/source changes cancel through the owner.
        await task.value
    }

    private func cancelOnline() {
        onlineGeneration = UUID()
        onlineWork.cancel()
        attempted = []
    }

    func clearOnlineNames() {
        cancelOnline()
        online = [:]
        defaults.removeObject(forKey: Keys.online)
    }
}
