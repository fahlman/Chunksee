import ChunkseeKit
import Foundation

/// One admitted opening, reread or move. The folder's persistent identity belongs to the app
/// registry; this identity retires work even when a reread keeps exactly the same URL.
nonisolated final class WorldReadSource: Equatable, Sendable {
    let world: World

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

    func regionFiles(in dimension: ChunkseeKit.Dimension, folder: ChunkseeKit.Dimension.Folder)
        throws -> [(x: Int, z: Int, url: URL)] {
        try read { _ in
            let listing = dimension.readRegionFiles(folder)
            guard listing.isComplete else { throw CocoaError(.fileReadUnknown) }
            return listing.files
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
