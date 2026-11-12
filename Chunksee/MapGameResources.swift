import Foundation

/// Drawing inputs derived from one world's publications, never a separately edited map copy.
nonisolated struct MapGameResources: Sendable {
    let data: GameDataLibrary?
    let artwork: GameArtworkLibrary?
    let biomeColors: MapBiomeColors?
    /// False while matching colors are being prepared without a retained value, or after closure.
    let colorsReady: Bool

    init(colorsReady: Bool, data: GameDataLibrary?, artwork: GameArtworkLibrary?, biomeColors: MapBiomeColors?) {
        self.data = data
        self.artwork = artwork
        self.colorsReady = colorsReady
        // Independent publications can change in either order. The color value owns whether
        // it remains useful with the current data and artwork capabilities.
        let source = GameResourceSource(data: data, artwork: artwork)
        self.biomeColors = biomeColors?.available(for: source)
    }

    static let unavailable = Self(colorsReady: true, data: nil, artwork: nil, biomeColors: nil)

    /// Live observation identity only. Persistent cache keys still use complete stable inputs.
    struct Identity: Equatable, Sendable {
        let data: UUID?
        let artwork: UUID?
        let colors: MapBiomeColors.Key?
        let colorsReady: Bool
    }

    var identity: Identity {
        Identity(data: data?.identity, artwork: artwork?.identity, colors: biomeColors?.sourceKey, colorsReady: colorsReady)
    }
}
