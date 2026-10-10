import AppKit
import Foundation
import Observation

/// A world the app has opened, remembered with a read-only security-scoped bookmark.
struct RecentWorld: Codable, Identifiable, Equatable {
    /// The world folder's path; also the value of the world's window.
    var id: String
    var name: String
    var bookmark: Data
}

/// What the app keeps across its windows: player names, saved searches, the worlds opened
/// recently and the worlds open now, which reopen at the next launch.
@Observable
final class AppModel {
    let names: PlayerNames
    /// Searches kept in the sidebar, shared by every world.
    let savedSearches: SavedSearches
    /// Most recent first; File ▸ Open Recent.
    private(set) var recentWorlds: [RecentWorld] {
        didSet { save(recentWorlds, Keys.recentWorlds) }
    }
    /// Worlds with a window open, by id, in the order they were opened.
    private(set) var openWorldIDs: [String] {
        didSet { defaults.set(openWorldIDs, forKey: Keys.openWorlds) }
    }

    private let defaults: UserDefaults
    /// Set when the app starts quitting: windows closing then stay on the list to reopen.
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var hasReopenedWorlds = false
    /// Whether launch reopens the worlds open at quit.
    private let reopensWorlds: Bool
    /// Tests run inside the app, which then mustn't open the user's worlds or the Open panel.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let recentLimit = 10

    private enum Keys {
        static let recentWorlds = "recentWorlds"
        static let openWorlds = "openWorlds"
        /// Before windows per world, the one world open at quit.
        static let lastWorldBookmark = "lastWorldBookmark"
    }

    /// `reopensWorlds` is off while hosting tests by default: scanning the user's worlds alongside
    /// the tests would starve them of threads.
    init(defaults: UserDefaults = .standard, reopensWorlds: Bool = !AppModel.isHostingTests) {
        self.defaults = defaults
        self.reopensWorlds = reopensWorlds
        self.names = PlayerNames(defaults: defaults)
        self.savedSearches = SavedSearches(defaults: defaults)
        recentWorlds = defaults.data(forKey: Keys.recentWorlds).flatMap { try? JSONDecoder().decode([RecentWorld].self, from: $0) } ?? []
        openWorldIDs = defaults.stringArray(forKey: Keys.openWorlds) ?? []
        migrateLastWorld()
        // SwiftUI has no notice that the app is quitting, so without AppKit's, windows closing as
        // it quits can't be told apart from the user closing them.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
    }

    isolated deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Remembers a world the user chose in the Open panel and returns its window's id, or `nil` if
    /// the folder can't be bookmarked.
    func add(_ url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = Self.bookmark(for: url) else { return nil }
        let id = Self.id(for: url)
        let name = recentWorlds.first { $0.id == id }?.name ?? url.lastPathComponent
        remember(RecentWorld(id: id, name: name, bookmark: bookmark))
        return id
    }

    /// The world folder for a window, before its security-scoped access is started, or `nil` if
    /// the world is no longer known or can't be found.
    func url(for id: String) -> URL? {
        guard let world = recentWorlds.first(where: { $0.id == id }) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: world.bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            recentWorlds.removeAll { $0.id == id }
            return nil
        }
        return url
    }

    /// Notes a world that opened: it moves to the top of Open Recent under its in-game name, with a
    /// fresh bookmark made while `url`'s access is held.
    func opened(_ id: String, url: URL, name: String) {
        guard var world = recentWorlds.first(where: { $0.id == id }) else { return }
        world.name = name
        if let bookmark = Self.bookmark(for: url) { world.bookmark = bookmark }
        remember(world)
    }

    func windowOpened(_ id: String) {
        if !openWorldIDs.contains(id) { openWorldIDs.append(id) }
    }

    /// The app is quitting: the windows about to close reopen at the next launch.
    func appWillTerminate() {
        isTerminating = true
    }

    /// A world's window closed: unless the app is quitting, it won't reopen at the next launch.
    func windowClosed(_ id: String) {
        guard !isTerminating else { return }
        openWorldIDs.removeAll { $0 == id }
    }

    /// The worlds to reopen at launch, those open when the app last quit; empty after the first ask.
    func worldsToReopenAtLaunch() -> [String] {
        guard !hasReopenedWorlds, reopensWorlds else { return [] }
        hasReopenedWorlds = true
        return openWorldIDs.filter { id in recentWorlds.contains { $0.id == id } }
    }

    /// Empties Open Recent, except for worlds open now, which still need their bookmarks.
    func clearRecentWorlds() {
        recentWorlds.removeAll { !openWorldIDs.contains($0.id) }
    }

    private func remember(_ world: RecentWorld) {
        recentWorlds = Array(([world] + recentWorlds.filter { $0.id != world.id }).prefix(Self.recentLimit))
    }

    /// Carries over the one world open before windows per world, so it reopens after the update.
    private func migrateLastWorld() {
        guard let data = defaults.data(forKey: Keys.lastWorldBookmark) else { return }
        defaults.removeObject(forKey: Keys.lastWorldBookmark)
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        let id = Self.id(for: url)
        remember(RecentWorld(id: id, name: url.lastPathComponent, bookmark: data))
        windowOpened(id)
    }

    private func save(_ worlds: [RecentWorld], _ key: String) {
        if let data = try? JSONEncoder().encode(worlds) { defaults.set(data, forKey: key) }
    }

    private static func id(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
