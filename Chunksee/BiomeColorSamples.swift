import ChunkseeKit

/// One coloring task's requested samples. The small horizontal grid avoids hashing the same
/// overlapping neighborhoods for every column; only the heights actually reached get a plane.
nonisolated struct BiomeColorSamples {
    private static let sources = BiomeColor.allCases
    private static let side = 16 + BiomeBlending.radius * 2
    private let originX: Int
    private let originZ: Int
    private let blendsColors: Bool
    private var planes: [Int: Int] = [:]
    private var slots: [Int] = []
    private var needed: [Bool] = []
    private var colors: [UInt32?] = []
    private(set) var points: [BlockPosition] = []

    init(originX: Int, originZ: Int, blendsColors: Bool) {
        self.originX = originX
        self.originZ = originZ
        self.blendsColors = blendsColors
    }

    mutating func request(_ source: BiomeColor, at point: BlockPosition) {
        guard let center = slot(at: point) else { return }
        let plane: Int
        if let existing = planes[point.y] { plane = existing }
        else {
            plane = slots.count
            planes[point.y] = plane
            slots.append(contentsOf: repeatElement(-1, count: Self.side * Self.side))
        }
        _ = insert(point, slot: plane + center) // The exact center survives an incomplete blend.
        guard blendsColors, let sourceIndex = Self.sources.firstIndex(of: source) else { return }
        BiomeBlending.forEachSample(at: point) { neighbor in
            guard let offset = slot(at: neighbor) else { return }
            let index = insert(neighbor, slot: plane + offset)
            needed[index * Self.sources.count + sourceIndex] = true
        }
    }

    /// Each requested point/source pair is resolved once. Kit still owns cell selection and
    /// biome color rules; this buffer stores only the results supplied by the renderer.
    mutating func resolveColors(_ resolve: (Int, BlockPosition, BiomeColor) -> UInt32?) {
        guard blendsColors else { return }
        colors = Array(repeating: nil, count: needed.count)
        for (index, point) in points.enumerated() {
            for (sourceIndex, source) in Self.sources.enumerated() {
                let offset = index * Self.sources.count + sourceIndex
                if needed[offset] { colors[offset] = resolve(index, point, source) }
            }
        }
    }

    func index(at point: BlockPosition) -> Int? {
        guard let plane = planes[point.y], let offset = slot(at: point) else { return nil }
        let index = slots[plane + offset]
        return index >= 0 ? index : nil
    }

    func color(_ source: BiomeColor, at point: BlockPosition) -> UInt32? {
        guard blendsColors, !colors.isEmpty, let plane = planes[point.y],
              let sourceIndex = Self.sources.firstIndex(of: source) else { return nil }
        return BiomeBlending.color(at: point) { neighbor in
            guard let offset = slot(at: neighbor) else { return nil }
            let index = slots[plane + offset]
            return index >= 0 ? colors[index * Self.sources.count + sourceIndex] : nil
        }
    }

    private mutating func insert(_ point: BlockPosition, slot: Int) -> Int {
        if slots[slot] >= 0 { return slots[slot] }
        let index = points.count
        points.append(point)
        slots[slot] = index
        if blendsColors { needed.append(contentsOf: repeatElement(false, count: Self.sources.count)) }
        return index
    }

    private func slot(at point: BlockPosition) -> Int? {
        let x = point.x.subtractingReportingOverflow(originX)
        let z = point.z.subtractingReportingOverflow(originZ)
        let radius = BiomeBlending.radius
        guard !x.overflow, !z.overflow, (-radius ..< 16 + radius).contains(x.partialValue),
              (-radius ..< 16 + radius).contains(z.partialValue) else { return nil }
        return (z.partialValue + radius) * Self.side + x.partialValue + radius
    }
}
