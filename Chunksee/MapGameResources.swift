import Foundation

/// Drawing inputs derived from one world's publications, never a separately edited map copy.
nonisolated struct MapGameResources: Sendable {
    let data: GameDataLibrary?
    let artwork: GameArtworkLibrary?
    let biomeColors: MapBiomeColors?

    init(data: GameDataLibrary?, artwork: GameArtworkLibrary?, biomeColors: MapBiomeColors?) {
        self.data = data
        self.artwork = artwork
        // Independent publications can change in either order. Colors are usable only with
        // the game source that produced them; game data need not wait for a color read.
        let source = GameResourceSource(data: data, artwork: artwork)
        self.biomeColors = biomeColors.flatMap { $0.source == source ? $0 : nil }
    }

    static let unavailable = Self(data: nil, artwork: nil, biomeColors: nil)

    /// Live observation identity only. Persistent cache keys still use complete stable inputs.
    struct Identity: Equatable, Sendable {
        let data: UUID?
        let artwork: UUID?
        let colors: MapBiomeColors.Key?
    }

    var identity: Identity {
        Identity(data: data?.identity, artwork: artwork?.identity, colors: biomeColors?.sourceKey)
    }
}
