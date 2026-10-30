import Foundation

/// Resolved terrain facts shared by the screen, Copy/Share and streamed area export.
/// It keeps neither a document nor a reader, and cannot change the saved presentation.
nonisolated struct MapDrawingInput: Sendable {
    let style: MapStyle
    let heightScale: MapHeightScale?
    let depth: MapDepth
    let blockFilter: MapBlockFilter
    let blendsBiomeColors: Bool
    let showsDarkSpots: Bool
    let lighting: MapLighting?
    let shadowLight: MapShadow.Light?

    init(presentation: MapPresentation, heightScale: MapHeightScale?, savedLighting: MapLighting?) {
        style = presentation.style.resolved(heightScale: heightScale)
        self.heightScale = heightScale
        depth = presentation.depth
        blockFilter = presentation.blockFilter
        blendsBiomeColors = presentation.blendsBiomeColors
        showsDarkSpots = presentation.overlays.showsDarkSpots
        lighting = style.inputs.lighting && presentation.lightingMode == .savedTime ? savedLighting : nil
        if style.inputs.shadows && presentation.castsShadows {
            if let lighting { shadowLight = MapShadow.Light.saved(lighting.direction) }
            else { shadowLight = .daylight }
        } else {
            shadowLight = nil
        }
    }

    var protectsWater: Bool { style == .waterDepth }
    var includesDetail: Bool { style.inputs.detail }
}
