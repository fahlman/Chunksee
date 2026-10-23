import ChunkseeKit
import CryptoKit
import Foundation

/// Unlit region colours, heights and water masks kept on disk, so reopening a world draws from the cache instead of
/// decoding every chunk again. An entry is valid only for the exact region file it was rendered
/// from (size and modification date) and the current renderer version, so regions changed in
/// game re-render automatically.
nonisolated struct TileCache: Sendable {
    /// Bump whenever rendering output changes (colors, shading, layout), invalidating old entries.
    /// 2: relief shading on each region's top row. 3: the Nether drawn under its roof.
    /// 4: solid Nether columns drawn darkened instead of left empty. 5: that block taken from below
    /// the roof's bedrock band. 6: independent Surface/cutaway height keys.
    /// 7: Kit 0.29 rejects ambiguous heightmaps, so surface rendering scans the blocks instead.
    /// 8: Kit's identifier parser recognizes omitted/empty default namespaces in block palettes.
    /// 9: Shared WORLD_SURFACE/actual-block starts replace the MOTION_BLOCKING fallback.
    /// 10: saved dimension height/ceiling context replaces the Nether-ID view rule.
    /// 11: independent Normal, Height and Water Depth styles, including the saved height scale.
    /// Bump on every change, even between unreleased builds: a stale version serves old tiles.
    /// 12: unlit colours, signed surface heights and water masks; bounded slope/elevation lighting.
    static let rendererVersion = 12

    let directory: URL

    struct Key: Hashable, Sendable {
        var region: RegionPosition
        var fileSize: Int
        var modified: Int64
        var cutawayY: Int? = nil
        var buildHeight: Int? = nil
        var ceilingY: Int? = nil
        var style = MapStyle.normal
        var heightScale: MapHeightScale? = nil

        var fileName: String {
            let view = cutawayY.map { "y\($0)" }
                ?? "h\(buildHeight.map(String.init) ?? "unknown").c\(ceilingY.map(String.init) ?? "none")"
            let scale = heightScale.map { ".scale\($0.cacheKey)" } ?? ""
            return "\(prefix)\(view)\(scale).\(fileSize).\(modified).v\(TileCache.rendererVersion).lzfse"
        }

        var regionPrefix: String { "r.\(region.x).\(region.z)." }
        var prefix: String { "\(regionPrefix)\(style.rawValue).\(cutawayY == nil ? "surface" : "cutaway")." }
    }

    /// The folder for one world's tiles: `Tiles/<hash of the world's path>`, under `root`.
    static func worldFolder(forWorldAt world: URL, root: URL?) -> URL? {
        root?.appendingPathComponent(CacheKey.hash(world.standardizedFileURL.path), isDirectory: true)
    }

    /// The cache directory for one dimension of one world, by default inside the app's Caches folder.
    static func directory(forWorldAt world: URL, dimensionID: String, root: URL?) -> URL? {
        // Replacing punctuation with underscores aliases valid IDs such as ice-caves/ice_caves.
        // Old folders may contain another dimension's data, so don't migrate their contents.
        let dimension = SHA256.hash(data: Data(dimensionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return worldFolder(forWorldAt: world, root: root)?.appendingPathComponent("dimension-" + dimension, isDirectory: true)
    }

    /// The folder holding every world's tiles.
    static var root: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Tiles", isDirectory: true)
    }

    /// Removes whole worlds' tiles, least recently used first, until the cache is under `limit`
    /// bytes. A world's folder is marked used whenever it's opened (see `markUsed`).
    static func prune(root: URL, limit: Int, keeping keep: URL? = nil) {
        let fileManager = FileManager.default
        let worlds = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func size(of folder: URL) -> Int {
            let files = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        var entries = worlds.map { folder in
            (folder: folder, size: size(of: folder),
             used: (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > limit && entry.folder.standardizedFileURL != keep?.standardizedFileURL {
            try? fileManager.removeItem(at: entry.folder)
            total -= entry.size
        }
    }

    /// Records that a world's tiles were just used, for least-recently-used pruning.
    static func markUsed(worldFolder: URL) {
        try? FileManager.default.createDirectory(at: worldFolder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: worldFolder.path)
    }

    /// The key for a region file as it is on disk now, or `nil` if it can't be read.
    static func key(for region: RegionPosition, regionFile: URL, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil,
                    style: MapStyle = .normal, heightScale: MapHeightScale? = nil) -> Key? {
        guard let stamp = CacheKey.fileStamp(for: regionFile) else { return nil }
        // Explicit slices never use heightmaps or the normal view below a roof.
        return Key(region: region, fileSize: stamp.size, modified: stamp.modified, cutawayY: cutawayY,
                   buildHeight: cutawayY == nil ? context.buildHeight : nil,
                   ceilingY: cutawayY == nil ? context.ceilingY : nil,
                   style: style, heightScale: style == .height ? heightScale : nil)
    }

    func load(_ key: Key) -> RegionTileRenderer.Canvas? {
        let count = RegionTileRenderer.side * RegionTileRenderer.side
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key.fileName)),
              let bytes = try? (data as NSData).decompressed(using: .lzfse) as Data,
              bytes.count == count * 9 else { return nil }
        let water = bytes[(count * 8)...]
        guard water.allSatisfy({ $0 <= 1 }) else { return nil }
        let heights = bytes.withUnsafeBytes { buffer in
            (0..<count).map { Int32(littleEndian: buffer.loadUnaligned(fromByteOffset: count * 4 + $0 * 4, as: Int32.self)) }
        }
        return RegionTileRenderer.Canvas(pixels: Array(bytes[..<(count * 4)]), heights: heights,
                                         isWater: water.map { $0 == 1 })
    }

    /// Keeps Surface and the latest cutaway per region and style, so dragging across many heights does not
    /// retain every intermediate slice. Failures only cost a re-render.
    func store(_ surface: RegionTileRenderer.Canvas, for key: Key) {
        let count = RegionTileRenderer.side * RegionTileRenderer.side
        guard surface.pixels.count == count * 4, surface.heights.count == count,
              surface.isWater.count == count else { return }
        var bytes = Data(capacity: count * 9)
        bytes.append(contentsOf: surface.pixels)
        surface.heights.map(\.littleEndian).withUnsafeBytes { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: surface.isWater.map { $0 ? UInt8(1) : 0 })
        guard let compressed = try? (bytes as NSData).compressed(using: .lzfse) as Data else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where (name.hasPrefix(key.prefix) && name != key.fileName)
            || (name.hasPrefix(key.regionPrefix) && !name.hasSuffix(".v\(Self.rendererVersion).lzfse")) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        try? compressed.write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
    }
}
