import SwiftUI
@testable import ChunkseeTestHost

extension MapContent {
    /// Marker-only fixtures have no map model. Tests that draw terrain supply the map's
    /// resolved input, just as the production document scene does.
    init(gameNames: GameNames) {
        self.init(gameNames: gameNames, terrain: MapDrawingInput(presentation: MapPresentation(),
                                                               heightScale: nil, savedLighting: nil))
    }
}

extension MapImage {
    /// Legend tests omit only the modifier, retaining the same drawing input and pixels.
    @MainActor
    static func renderWithoutLegend(_ map: MapModel, content: MapContent, size: CGSize,
                                    colorScheme: ColorScheme, locale: Locale) -> MapImage? {
        let canvas = Canvas { context, size in
            MapView.drawMap(map, content: content, portalStatus: { _ in nil }, in: context, size: size)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, locale)
        return rasterizedImage(canvas, scale: 1).flatMap(png)
    }
}
