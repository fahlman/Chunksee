import ChunkseeKit
import Foundation

/// Compact materials from the terrain's existing scan. Chunk-local palettes avoid retaining
/// a full saved block state and tint array separately for every visible column.
nonisolated struct MapSurfaceDetail: Sendable, Equatable {
    static let noMaterial = UInt16.max
    static let maximumEncodedBytes = 16 * 1024 * 1024
    static let maximumRetainedBytes = 8 * 1024 * 1024

    struct Material: Hashable, Sendable, Codable {
        let request: MapBlockColorRequest
        let colorShade: Double
        let emphasis: MapBlockFilter.Emphasis

        var estimatedBytes: Int {
            256 + request.state.description.utf8.count * 4 + request.state.properties.count * 64 + request.tints.count * 64
        }
    }

    struct Chunk: Sendable, Equatable {
        let materials: [Material]
        let indices: [UInt16]

        init?(columns: [RegionTileRenderer.Column?], requests: [MapBlockColorRequest], indices source: [Int?]) {
            guard columns.count == 256, source.count == 256 else { return nil }
            struct Key: Hashable {
                let request: Int
                let shade: Double
                let emphasis: MapBlockFilter.Emphasis
            }
            var palette: [Material] = [], indices = [UInt16](repeating: noMaterial, count: 256)
            var known: [Key: UInt16] = [:]
            for (i, column) in columns.enumerated() {
                // Water keeps its depth/floor presentation. Highlighted blocks keep the solid
                // accent; unsupported material images keep the ordinary terrain pixel too.
                guard let column, column.waterDepth == 0, column.emphasis != .highlighted,
                      let source = source[i], requests.indices.contains(source) else { continue }
                let key = Key(request: source, shade: column.colorShade, emphasis: column.emphasis)
                if let index = known[key] { indices[i] = index }
                else {
                    let index = UInt16(palette.count)
                    palette.append(Material(request: requests[source], colorShade: column.colorShade, emphasis: column.emphasis))
                    known[key] = index
                    indices[i] = index
                }
            }
            guard !palette.isEmpty, palette.reduce(512, { $0 + $1.estimatedBytes }) <= 256 * 1024 else { return nil }
            materials = palette
            self.indices = indices
        }

        fileprivate init(materials: [Material], indices: [UInt16]) {
            self.materials = materials
            self.indices = indices
        }

        var estimatedBytes: Int { indices.count * 2 + materials.reduce(0) { $0 + $1.estimatedBytes } }
    }

    private(set) var chunks: [Int: Chunk] = [:]
    private(set) var estimatedBytes = 0
    var isEmpty: Bool { chunks.isEmpty }

    /// A deterministic prefix remains detailed if an unusually varied region exceeds the
    /// budget. Completion order cannot change what is kept; all other columns stay flat.
    mutating func insert(_ chunk: Chunk, at index: Int) {
        guard (0..<1024).contains(index) else { return }
        if let old = chunks[index] { estimatedBytes -= 64 + old.estimatedBytes }
        chunks[index] = chunk
        estimatedBytes += 64 + chunk.estimatedBytes
        while estimatedBytes > Self.maximumRetainedBytes, let last = chunks.keys.max(),
              let removed = chunks.removeValue(forKey: last) {
            estimatedBytes -= 64 + removed.estimatedBytes
        }
    }

    /// The cache supplies the height array already stored alongside these materials. No second
    /// height/state read is needed when the view crosses the detail threshold.
    struct Surface: Sendable {
        let detail: MapSurfaceDetail
        let heights: [Int32]
        var estimatedBytes: Int { detail.estimatedBytes + heights.count * 4 }
    }

    private struct StoredChunk: Codable {
        let index: Int
        let materials: [Material]
        let indices: Data
    }

    func encoded() -> Data? {
        guard !isEmpty else { return Data() }
        let stored = chunks.keys.sorted().map { index in
            let chunk = chunks[index]!
            let bytes = chunk.indices.map(\.littleEndian).withUnsafeBytes { Data($0) }
            return StoredChunk(index: index, materials: chunk.materials, indices: bytes)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(stored), data.count <= Self.maximumEncodedBytes else { return nil }
        return data
    }

    static func decoded(_ data: Data) -> Self? {
        guard !data.isEmpty else { return Self() }
        guard data.count <= maximumEncodedBytes,
              let stored = try? PropertyListDecoder().decode([StoredChunk].self, from: data),
              stored.count <= 1024 else { return nil }
        var result = Self()
        for chunk in stored {
            guard (0..<1024).contains(chunk.index), result.chunks[chunk.index] == nil,
                  !chunk.materials.isEmpty, chunk.materials.count <= 256, chunk.indices.count == 512,
                  chunk.materials.allSatisfy({ $0.colorShade.isFinite && (0...1).contains($0.colorShade)
                      && $0.request.tints.count <= 4096 }) else { return nil }
            let indices = chunk.indices.withUnsafeBytes { bytes in
                (0..<256).map { UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
            }
            guard indices.allSatisfy({ $0 == noMaterial || Int($0) < chunk.materials.count }) else { return nil }
            let restored = Chunk(materials: chunk.materials, indices: indices)
            guard restored.estimatedBytes <= 256 * 1024,
                  result.estimatedBytes + 64 + restored.estimatedBytes <= maximumRetainedBytes else { return nil }
            result.insert(restored, at: chunk.index)
        }
        return result
    }
}
