import Foundation
import Observation

/// Preferences shared by all documents. macOS owns open documents and Open Recent.
@Observable
final class AppModel {
    let names: PlayerNames
    let savedSearches: SavedSearches

    init(defaults: UserDefaults = .standard) {
        names = PlayerNames(defaults: defaults)
        savedSearches = SavedSearches(defaults: defaults)
    }
}
