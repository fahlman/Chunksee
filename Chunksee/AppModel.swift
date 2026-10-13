import Foundation
import Observation

/// Preferences shared by all documents. macOS owns open documents and Open Recent.
@Observable
final class AppModel {
    static let shared = AppModel()
    let names: PlayerNames
    let savedSearches: SavedSearches
    let windows = WorldWindowContext()

    init(defaults: UserDefaults = .standard) {
        // The old window model's bookmarks cannot serve native document restoration.
        for key in ["openWorlds", "recentWorlds", "lastWorldBookmark"] {
            defaults.removeObject(forKey: key)
        }
        names = PlayerNames(defaults: defaults)
        savedSearches = SavedSearches(defaults: defaults)
    }
}
