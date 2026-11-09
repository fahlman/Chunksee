import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

/// API adapter only; the endpoint's shipping formatter still supplies the displayed text.
@MainActor
enum NamingComparisonAdapter {
    static func requireNameContext(_ session: WorldSession, expected: GameNames.Identity?) throws {
        try #require(session.resources.gameNames.identity == expected)
        try #require(MapContent(session: session).gameNames.identity == expected)
    }

    static func emptyContent(gameNames: GameNames) -> MapContent {
        MapContent(gameNames: gameNames)
    }

    static func storage(_ session: WorldSession) -> [StoredItem] {
        session.resources.gameNames.storedItems(session.presentation.selectedIndex.storage)
    }

    static func readout(at point: CGPoint, block: RegionTileRenderer.TopBlock?, content: MapContent) -> String {
        MapView.readout(at: point, block: block, biomes: content.biomeDescription(at: point),
                        gameNames: content.gameNames, locale: NamingComparisonCapture.locale)
    }

    static func hitText(_ hit: SearchHit, names: GameNames) -> [String: Any] {
        ["title": hit.title(in: names), "detail": hit.detail(in: names),
         "items": hit.items.map { ["id": $0.id, "count": $0.count, "text": $0.text(in: names)] as [String: Any] }]
    }
}
