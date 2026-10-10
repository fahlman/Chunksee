import Foundation
import MCWorldKit
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

/// Player names for the whole app: from Minecraft's local name caches in a folder the user chose,
/// and, only when the user turns it on, from Mojang. Online results are remembered between launches.
@Observable
final class PlayerNames {
    private(set) var local: [UUID: String] = [:]
    private(set) var online: [UUID: String] = [:]
    /// The Minecraft folder whose `usercache.json` files are read, kept as a read-only bookmark.
    private(set) var minecraftFolder: URL?

    /// Off until the user turns it on: looking a name up sends that player's UUID to Mojang.
    var looksUpOnline: Bool {
        didSet { defaults.set(looksUpOnline, forKey: Keys.looksUpOnline) }
    }

    private let defaults: UserDefaults
    private let mojang: MojangProfiles
    /// Lookups that found nothing or failed, so they aren't retried every time the list redraws.
    private var attempted: Set<UUID> = []

    private enum Keys {
        static let looksUpOnline = "looksUpPlayerNamesOnline"
        static let online = "onlinePlayerNames"
        static let folder = "minecraftFolderBookmark"
    }

    init(defaults: UserDefaults = .standard, mojang: MojangProfiles = MojangProfiles()) {
        self.defaults = defaults
        self.mojang = mojang
        looksUpOnline = defaults.bool(forKey: Keys.looksUpOnline)
        if let saved = defaults.dictionary(forKey: Keys.online) as? [String: String] {
            online = Dictionary(uniqueKeysWithValues: saved.compactMap { key, name in UUID(uuidString: key).map { ($0, name) } })
        }
        restoreFolder()
    }

    func name(for uuid: UUID) -> String? {
        local[uuid] ?? online[uuid]
    }

    // MARK: Local caches

    /// Uses `url` (from the Open panel) as the Minecraft folder and reads its name caches.
    func chooseMinecraftFolder(_ url: URL) async {
        minecraftFolder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        minecraftFolder = url
        let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Keys.folder)
        await reloadLocal()
    }

    func forgetMinecraftFolder() {
        minecraftFolder?.stopAccessingSecurityScopedResource()
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
        _ = url.startAccessingSecurityScopedResource()
        minecraftFolder = url
    }

    /// Rereads the local caches, which change whenever someone plays.
    func reloadLocal() async {
        guard let folder = minecraftFolder else { return }
        local = await Self.readCaches(under: folder)
    }

    @concurrent
    private nonisolated static func readCaches(under folder: URL) async -> [UUID: String] {
        UserCache.names(under: folder).mapValues(\.name)
    }

    // MARK: Online

    /// Looks up, one at a time, the names of `uuids` not known locally or online, when the user
    /// has turned online lookup on. Each UUID is tried at most once per launch.
    func lookUp(_ uuids: [UUID]) async {
        guard looksUpOnline else { return }
        for uuid in uuids where name(for: uuid) == nil && !attempted.contains(uuid) {
            attempted.insert(uuid)
            guard let found = try? await mojang.name(for: uuid) else { continue }
            online[uuid] = found
            defaults.set(Dictionary(uniqueKeysWithValues: online.map { ($0.key.uuidString, $0.value) }), forKey: Keys.online)
        }
    }

    /// Forgets names fetched from Mojang.
    func clearOnlineNames() {
        online = [:]
        attempted = []
        defaults.removeObject(forKey: Keys.online)
    }
}
