import ChunkseeKit
import Foundation

/// One dimension's presentation choices. Names come from saved palettes; this does not infer
/// block occupancy or change the world's data. Rendering, hover and export share this value.
nonisolated struct MapBlockFilter: Equatable, Sendable {
    enum Choice: CaseIterable { case show, hide, highlight }

    let isEnabled: Bool
    let hiddenIDs: Set<String>
    let highlightedIDs: Set<String>
    /// Computed only when choices change, never for every column or region being drawn.
    let cacheKey: String?

    init(isEnabled: Bool = true, hiddenIDs: Set<String> = [], highlightedIDs: Set<String> = []) {
        self.isEnabled = isEnabled
        self.hiddenIDs = Set(hiddenIDs.compactMap { Identifier($0)?.description })
        self.highlightedIDs = Set(highlightedIDs.compactMap { Identifier($0)?.description }).subtracting(self.hiddenIDs)
        // Valid identifiers cannot contain newlines, so the two sorted sections are unambiguous.
        cacheKey = isEnabled && (!self.hiddenIDs.isEmpty || !self.highlightedIDs.isEmpty)
            ? CacheKey.hash(self.hiddenIDs.sorted().joined(separator: "\n") + "\n\n" + self.highlightedIDs.sorted().joined(separator: "\n"))
            : nil
    }

    var effectiveHiddenIDs: Set<String> { isEnabled ? hiddenIDs : [] }

    func choice(for id: String) -> Choice {
        hiddenIDs.contains(id) ? .hide : highlightedIDs.contains(id) ? .highlight : .show
    }

    func choosing(_ choice: Choice, for ids: Set<String>) -> Self {
        let ids = Set(ids.compactMap { Identifier($0)?.description })
        return Self(isEnabled: isEnabled,
             hiddenIDs: choice == .hide ? hiddenIDs.union(ids) : hiddenIDs.subtracting(ids),
             highlightedIDs: choice == .highlight ? highlightedIDs.union(ids) : highlightedIDs.subtracting(ids))
    }

    func enabled(_ enabled: Bool) -> Self {
        Self(isEnabled: enabled, hiddenIDs: hiddenIDs, highlightedIDs: highlightedIDs)
    }

    /// Only offered saved IDs are selected; tag declarations alone do not establish that a
    /// block exists in this dimension. Unavailable membership stays distinct from an empty tag.
    static func leafIDs(in catalog: Set<String>, tag: GameTag?) -> Set<String>? {
        tag.map { Set($0.members.map(\.id)).intersection(catalog) }
    }

    enum Emphasis: UInt8, Hashable, Sendable, Codable {
        case ordinary, dimmed, highlighted

        static let accent = MapColor(0xFFD60A)

        func applying(to color: MapColor) -> MapColor {
            switch self {
            case .ordinary: color
            case .dimmed: color.shaded(0.25)
            case .highlighted: Self.accent
            }
        }
    }

    /// Resolved once per reached palette entry, alongside its ordinary map colour.
    func emphasis(for id: String) -> Emphasis {
        guard isEnabled, !highlightedIDs.isEmpty else { return .ordinary }
        return highlightedIDs.contains(id) ? .highlighted : .dimmed
    }
}
