import ChunkseeKit
import Foundation

/// One admitted opening, reread or move. The folder's persistent identity belongs to the app
/// registry; this identity retires work even when a reread keeps exactly the same URL.
nonisolated final class WorldReadSource: Equatable, Sendable {
    private let world: World
    var url: URL { world.url }

    init(_ world: World) { self.world = world }

    static func == (lhs: WorldReadSource, rhs: WorldReadSource) -> Bool { lhs === rhs }

    /// Folder absence means deletion only while the enclosing open world remains accessible.
    /// Check both ends so losing the root during a read cannot publish an empty replacement.
    func read<Value>(_ operation: (World) throws -> Value) throws -> Value {
        try requireAvailable()
        let value = try operation(world)
        try requireAvailable()
        return value
    }

    @concurrent
    func read<Value: Sendable>(_ operation: @Sendable (World) async throws -> Value) async throws -> Value {
        try requireAvailable()
        let value = try await operation(world)
        try requireAvailable()
        return value
    }

    /// Keep the dimension admitted by the opening. Rediscovery during a read could redirect an
    /// old-layout path, or mistake deletion of its region folder for loss of the whole source.
    func read<Value>(in dimension: ChunkseeKit.Dimension,
                     _ operation: (ChunkseeKit.Dimension) throws -> Value) throws -> Value {
        try read { _ in try operation(dimension) }
    }

    @concurrent
    func read<Value: Sendable>(in dimension: ChunkseeKit.Dimension,
                              _ operation: @Sendable (ChunkseeKit.Dimension) async throws -> Value) async throws -> Value {
        try await read { _ in try await operation(dimension) }
    }

    /// Composite consumers retain their prior publication if the root is lost between their
    /// individually guarded reads. They do not receive a second unguarded file-access handle.
    @concurrent
    func whileAvailable<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try await read { _ in try await operation() }
    }

    @concurrent
    func checkAvailability() async throws { try requireAvailable() }

    func regions(in dimension: ChunkseeKit.Dimension, folders: [ChunkseeKit.Dimension.Folder]) throws -> Set<RegionPosition> {
        try read(in: dimension) { dimension in
            var result = Set<RegionPosition>()
            for folder in folders {
                let listing = dimension.readRegionFiles(folder)
                guard listing.isComplete else { throw CocoaError(.fileReadUnknown) }
                result.formUnion(listing.files.map { RegionPosition(x: $0.x, z: $0.z) })
            }
            return result
        }
    }

    private func requireAvailable() throws {
        try Task.checkCancellation()
        let files = FileManager.default, path = world.url.path
        var directory: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              files.isReadableFile(atPath: path), files.isExecutableFile(atPath: path) else {
            throw CocoaError(.fileReadUnknown)
        }
    }
}
