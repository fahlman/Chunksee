import Foundation
import Synchronization

/// The user's world bookmarks own persistent identity as well as read-only access. Resolving a
/// bookmark follows a folder move; a separately opened copy receives a different identity.
nonisolated final class WorldFolders: Sendable {
    struct Folder: Sendable {
        let id: UUID
        let url: URL
    }

    private struct Record {
        let id: UUID
        var bookmark: Data

        var stored: [String: Any] {
            ["id": id.uuidString, "bookmark": bookmark]
        }
    }

    // UserDefaults is thread-safe; this app-owned registry serializes whole read-modify-writes.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let lock = Mutex(())
    private static let key = "worldFolderBookmarks"

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// Call on the opening reader, while the folder chosen in the Open panel is accessible.
    @discardableResult
    func remember(_ world: URL) throws -> Folder {
        let bookmark = try world.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        let path = world.resolvingSymlinksInPath().path
        return lock.withLock { _ in
            var records = resolved()
            let index: Int
            if let existing = records.firstIndex(where: { $0.url?.resolvingSymlinksInPath().path == path }) {
                index = existing
                records[index].record.bookmark = bookmark
            } else {
                index = records.count
                records.append((Record(id: UUID(), bookmark: bookmark), world))
            }
            defaults.set(records.map { $0.record.stored }, forKey: Self.key)
            let record = records[index].record
            return Folder(id: record.id, url: world)
        }
    }

    /// The longest containing world wins when folders are nested. Keep temporarily unavailable
    /// bookmarks in storage so disconnecting a disk cannot erase its world's identity/settings.
    func world(containing url: URL) -> Folder? {
        lock.withLock { _ in
            let records = resolved()
            defaults.set(records.map { $0.record.stored }, forKey: Self.key)
            let path = url.resolvingSymlinksInPath().path
            var found: Folder?
            var parentLength = 0
            for (record, url) in records {
                guard let url else { continue }
                let parent = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(parent + "/"), parent.count > parentLength else { continue }
                found = Folder(id: record.id, url: url)
                parentLength = parent.count
            }
            return found
        }
    }

    private func records() -> [Record] {
        (defaults.array(forKey: Self.key) ?? []).compactMap { value in
            guard let value = value as? [String: Any], let id = value["id"] as? String,
                  let id = UUID(uuidString: id), let bookmark = value["bookmark"] as? Data else { return nil }
            return Record(id: id, bookmark: bookmark)
        }
    }

    private func resolved() -> [(record: Record, url: URL?)] {
        records().map { original in
            var record = original, isStale = false
            guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI],
                                    bookmarkDataIsStale: &isStale) else { return (record, nil) }
            let access = WorldReadAccess(url)
            defer { access.release() }
            guard (try? url.checkResourceIsReachable()) == true else { return (record, nil) }
            if isStale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) {
                record.bookmark = refreshed
            }
            // Canonical paths identify folders; the original bookmark URL carries read access.
            // Replacing it with a path-derived URL loses that scope after this access ends.
            return (record, url)
        }
    }
}
