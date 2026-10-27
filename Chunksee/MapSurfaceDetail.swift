import ChunkseeKit
import Foundation

/// Compact materials from the terrain's existing scan. Chunk-local palettes avoid retaining
/// a full saved block state and tint array separately for every visible column.
nonisolated struct MapSurfaceDetail: Sendable, Equatable {
    static let noMaterial = UInt16.max
    static let maximumEncodedBytes = 16 * 1024 * 1024
    static let maximumRetainedBytes = 8 * 1024 * 1024
    static let maximumChunkBytes = 256 * 1024

    struct Material: Hashable, Sendable, Codable {
        let request: MapBlockColorRequest
        let colorShade: Double
        let emphasis: MapBlockFilter.Emphasis

        var estimatedBytes: Int {
            256 + request.state.description.utf8.count * 4 + request.state.properties.count * 64 + request.tints.count * 64
        }
    }

    struct Chunk: Sendable, Equatable {
        struct Layer: Sendable, Equatable, Codable {
            let material: UInt16
            let y: Int32
        }

        struct Overlay: Sendable, Equatable, Codable {
            let column: UInt8
            let baseColor: UInt32
            let isWater: Bool
            /// Top to bottom, matching the one terrain traversal.
            let layers: [Layer]

            var estimatedBytes: Int { 64 + layers.count * 16 }
        }

        let materials: [Material]
        let indices: [UInt16]
        let overlays: [Overlay]
        let estimatedBytes: Int

        init?(columns: [RegionTileRenderer.Column?], requests: [MapBlockColorRequest], indices source: [Int?],
              layerIndices: [[Int]] = Array(repeating: [], count: 256), style: MapStyle = .normal) {
            guard columns.count == 256, source.count == 256, layerIndices.count == 256 else { return nil }
            struct Key: Hashable {
                let request: Int
                let shade: Double
                let emphasis: MapBlockFilter.Emphasis
            }
            var palette: [Material] = [], indices = [UInt16](repeating: noMaterial, count: 256)
            var overlays: [Overlay] = [], bytes = 512
            var known: [Key: UInt16] = [:]
            func material(_ source: Int, shade: Double, emphasis: MapBlockFilter.Emphasis) -> UInt16? {
                guard requests.indices.contains(source) else { return nil }
                let key = Key(request: source, shade: shade, emphasis: emphasis)
                if let index = known[key] { return index }
                guard let index = UInt16(exactly: palette.count), index != noMaterial else { return nil }
                let material = Material(request: requests[source], colorShade: shade, emphasis: emphasis)
                bytes += material.estimatedBytes
                guard bytes <= maximumChunkBytes else { return nil }
                palette.append(material)
                known[key] = index
                return index
            }
            for (i, column) in columns.enumerated() {
                // Water keeps its depth/floor presentation. Highlighted blocks keep the solid
                // accent; unsupported material images keep the ordinary terrain pixel too.
                guard let column, column.surfaceEmphasis != .highlighted else { continue }
                if column.waterDepth == 0, let source = source[i] {
                    guard let index = material(source, shade: column.colorShade, emphasis: column.surfaceEmphasis) else { return nil }
                    indices[i] = index
                }
                guard !column.layers.isEmpty else { continue }
                guard column.layers.count == layerIndices[i].count else { return nil }
                var layers: [Layer] = []
                for (layer, source) in zip(column.layers, layerIndices[i]) {
                    guard let index = material(source, shade: 1, emphasis: column.surfaceEmphasis),
                          let y = Int32(exactly: layer.y), y != RegionTileRenderer.Canvas.noHeight else { return nil }
                    layers.append(Layer(material: index, y: y))
                }
                let color = style == .waterDepth && column.waterDepth > 0
                    ? MapStylePalette.waterColor(depth: column.waterDepth) : RegionTileRenderer.baseColor(for: column)
                let overlay = Overlay(column: UInt8(i), baseColor: UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue),
                                      isWater: column.waterDepth > 0, layers: layers)
                bytes += overlay.estimatedBytes
                guard bytes <= maximumChunkBytes else { return nil }
                overlays.append(overlay)
            }
            guard !palette.isEmpty else { return nil }
            materials = palette
            self.indices = indices
            self.overlays = overlays
            estimatedBytes = bytes
        }

        fileprivate init(materials: [Material], indices: [UInt16], overlays: [Overlay], materialBytes: Int) {
            self.materials = materials
            self.indices = indices
            self.overlays = overlays
            estimatedBytes = indices.count * 2 + materialBytes + overlays.reduce(0) { $0 + $1.estimatedBytes }
        }
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
        let nightLight: [UInt8]?

        init(detail: MapSurfaceDetail, heights: [Int32], nightLight: [UInt8]? = nil) {
            self.detail = detail
            self.heights = heights
            self.nightLight = nightLight
        }

        var estimatedBytes: Int { detail.estimatedBytes + heights.count * 4 + (nightLight?.count ?? 0) }
    }

    private struct StoredChunk: Codable {
        let index: Int
        let materials: Data
        let indices: Data
        let overlays: [Chunk.Overlay]
    }

    /// Neighboring chunks usually repeat the same few states and tints. Serialize and decode
    /// those values once per region, while preserving each chunk's local palette addresses.
    private struct Stored: Codable {
        let materials: [Material]
        let chunks: [StoredChunk]
    }

    private static func encodeIndices(_ values: [UInt16]) -> Data {
        values.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }

    private static func decodeIndices(_ data: Data) -> [UInt16] {
        data.withUnsafeBytes { bytes in
            (0..<(data.count / 2)).map { UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
    }

    func encoded() -> Data? {
        guard !isEmpty else { return Data() }
        var materials: [Material] = [], known: [Material: UInt16] = [:], stored: [StoredChunk] = []
        for index in chunks.keys.sorted() {
            let chunk = chunks[index]!
            var references: [UInt16] = []
            for material in chunk.materials {
                if let reference = known[material] { references.append(reference) }
                else {
                    guard materials.count < Int(Self.noMaterial) else { return nil }
                    let reference = UInt16(materials.count)
                    materials.append(material)
                    known[material] = reference
                    references.append(reference)
                }
            }
            stored.append(StoredChunk(index: index, materials: Self.encodeIndices(references),
                                      indices: Self.encodeIndices(chunk.indices), overlays: chunk.overlays))
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Stored(materials: materials, chunks: stored)),
              data.count <= Self.maximumEncodedBytes else { return nil }
        return data
    }

    static func decoded(_ data: Data) -> Self? {
        guard !data.isEmpty else { return Self() }
        guard data.count <= maximumEncodedBytes,
              let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
              stored.chunks.count <= 1024, stored.materials.count < Int(noMaterial),
              stored.materials.allSatisfy({ $0.colorShade.isFinite && (0...1).contains($0.colorShade)
                  && $0.request.tints.count <= 4096 }) else { return nil }
        let costs = stored.materials.map(\.estimatedBytes)
        guard costs.reduce(0, +) <= maximumRetainedBytes else { return nil }
        var result = Self()
        for chunk in stored.chunks {
            guard (0..<1024).contains(chunk.index), result.chunks[chunk.index] == nil,
                  !chunk.materials.isEmpty, chunk.materials.count <= maximumChunkBytes,
                  chunk.materials.count.isMultiple(of: 2), chunk.indices.count == 512,
                  chunk.overlays.count <= 256, Set(chunk.overlays.map(\.column)).count == chunk.overlays.count,
                  chunk.overlays.allSatisfy({ !$0.layers.isEmpty && $0.layers.count <= maximumChunkBytes / 16
                      && $0.baseColor <= 0xffffff }) else { return nil }
            let references = decodeIndices(chunk.materials), indices = decodeIndices(chunk.indices)
            guard references.allSatisfy({ Int($0) < stored.materials.count }),
                  indices.allSatisfy({ $0 == noMaterial || Int($0) < references.count }),
                  chunk.overlays.allSatisfy({ $0.layers.allSatisfy { Int($0.material) < references.count && $0.y != RegionTileRenderer.Canvas.noHeight } }) else { return nil }
            let restored = Chunk(materials: references.map { stored.materials[Int($0)] }, indices: indices, overlays: chunk.overlays,
                                 materialBytes: references.reduce(0) { $0 + costs[Int($1)] })
            guard restored.estimatedBytes <= maximumChunkBytes,
                  result.estimatedBytes + 64 + restored.estimatedBytes <= maximumRetainedBytes else { return nil }
            result.insert(restored, at: chunk.index)
        }
        return result
    }
}
