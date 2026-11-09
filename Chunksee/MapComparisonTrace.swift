import ChunkseeKit
import Synchronization

/// Evidence-only counters at the actual cache and reconstruction branches. The mutex permits
/// concurrent region jobs; records contain values only and never extend a model's lifetime.
nonisolated enum MapComparisonTrace {
    enum Kind: String, Codable, Sendable { case surface, tileHit, tileMiss, detailHit, detailMiss }

    struct Event: Encodable, Sendable {
        let kind: Kind
        let x: Int
        let z: Int
        let key: TileCache.Key?
    }

    private static let events = Mutex<[Event]?>(nil)

    static func begin() {
        events.withLock { value in
            precondition(value == nil, "A comparison trace is already active")
            value = []
        }
    }

    static func record(_ kind: Kind, region: RegionPosition, key: TileCache.Key? = nil) {
        events.withLock { $0?.append(Event(kind: kind, x: region.x, z: region.z, key: key)) }
    }

    static func snapshot() -> [Event] { events.withLock { $0 ?? [] } }

    static func end() -> [Event] {
        events.withLock { value in
            let result = value ?? []
            value = nil
            return result
        }
    }
}

