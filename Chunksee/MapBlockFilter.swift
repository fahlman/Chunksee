import ChunkseeKit
import Foundation

/// One dimension's presentation choices. IDs come from saved palettes; this does not infer
/// block occupancy or change the world's data. Rendering, hover and export share this value.
nonisolated struct MapBlockFilter: Equatable, Sendable, Codable {
    enum Choice: CaseIterable { case show, hide, highlight }

    let isEnabled: Bool
    let hiddenIDs: Set<String>
    let highlightedIDs: Set<String>
    /// Computed only when choices change, never for every column or region being drawn.
    let cacheKey: Key?

    struct Key: Hashable, Sendable, Encodable {
        let hidden: [String]
        let highlighted: [String]
    }

    init(isEnabled: Bool = true, hiddenIDs: Set<String> = [], highlightedIDs: Set<String> = []) {
        self.isEnabled = isEnabled
        self.hiddenIDs = Set(hiddenIDs.compactMap { Identifier($0)?.description })
        self.highlightedIDs = Set(highlightedIDs.compactMap { Identifier($0)?.description }).subtracting(self.hiddenIDs)
        cacheKey = isEnabled && (!self.hiddenIDs.isEmpty || !self.highlightedIDs.isEmpty)
            ? Key(hidden: self.hiddenIDs.sorted(), highlighted: self.highlightedIDs.sorted())
            : nil
    }

    var effectiveHiddenIDs: Set<String> { isEnabled ? hiddenIDs : [] }

    private enum CodingKeys: String, CodingKey { case isEnabled, hiddenIDs, highlightedIDs }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self), defaults = Self()
        self.init(isEnabled: (try? values.decode(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled,
                  hiddenIDs: Set((try? values.decode([String].self, forKey: .hiddenIDs)) ?? []),
                  highlightedIDs: Set((try? values.decode([String].self, forKey: .highlightedIDs)) ?? []))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(hiddenIDs.sorted(), forKey: .hiddenIDs)
        try values.encode(highlightedIDs.sorted(), forKey: .highlightedIDs)
    }

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
