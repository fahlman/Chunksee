import Foundation
import Observation

/// Owns the open world and remembers it between launches with a read-only security-scoped bookmark.
@Observable
final class AppModel {
    private(set) var session: WorldSession?
    private(set) var isOpening = false
    var errorMessage: String?
    var isShowingOpenPanel = false
    let names: PlayerNames
    /// Searches kept in the sidebar, shared by every world.
    let savedSearches: SavedSearches

    private let defaults: UserDefaults
    private static let bookmarkKey = "lastWorldBookmark"
    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.names = PlayerNames(defaults: defaults)
        self.savedSearches = SavedSearches(defaults: defaults)
    }

    /// Reopens the world from the last launch, if its bookmark still resolves.
    func restoreLastWorld() async {
        // Tests run inside the app; reopening the user's world there would scan it alongside the
        // tests and starve them of threads.
        guard !Self.isHostingTests else { return }
        guard session == nil, let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        await open(url, remember: isStale)
    }

    /// Opens a world folder the user chose. Replaces the current world only if the new one opens.
    func open(_ url: URL, remember: Bool = true) async {
        isOpening = true
        defer { isOpening = false }
        do {
            let newSession = try await WorldSession.open(url, names: names, savedSearches: savedSearches, defaults: defaults)
            session?.close()
            session = newSession
            errorMessage = nil
            if remember { saveBookmark(for: url) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveBookmark(for url: URL) {
        let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
    }
}
