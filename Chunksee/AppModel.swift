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

    private final class WeakResources {
        weak var value: WorldResources?
        init(_ value: WorldResources) { self.value = value }
    }

    init(defaults: UserDefaults = .standard) {
        // The old window model's bookmarks cannot serve native document restoration.
        for key in ["openWorlds", "recentWorlds", "lastWorldBookmark"] {
            defaults.removeObject(forKey: key)
        }
        names = PlayerNames(defaults: defaults)
        savedSearches = SavedSearches(defaults: defaults)
        worldFolders = WorldFolders(defaults: defaults)
    }

    /// The open resources of a snapshot's world, which its other dimensions share, or new ones.
    func resources(for snapshot: WorldSnapshot) -> WorldResources {
        openWorlds = openWorlds.filter { $0.value.value.map { !$0.isClosed } ?? false }
        let key = snapshot.access.url.resolvingSymlinksInPath().path
        if let open = openWorlds[key]?.value {
            snapshot.access.release()
            return open
        }
        let resources = WorldResources(snapshot: snapshot, names: names, savedSearches: savedSearches)
        openWorlds[key] = WeakResources(resources)
        return resources
    }
}
