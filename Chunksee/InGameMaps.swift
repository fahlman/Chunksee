import CoreGraphics
import ChunkseeKit
import SwiftUI

/// Pictures of maps made in the game, in Minecraft's map colors.
nonisolated enum InGameMapImage {
    /// A 128×128 image with transparent pixels where nothing was drawn.
    static func make(_ map: MapItem) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: MapItem.size * MapItem.size * 4)
        for (index, color) in map.colors.enumerated() {
            guard let rgb = MapItem.rgb(forColor: color) else { continue }
            pixels[index * 4] = rgb.red
            pixels[index * 4 + 1] = rgb.green
            pixels[index * 4 + 2] = rgb.blue
            pixels[index * 4 + 3] = 255
        }
        // Map pixels are fully opaque or fully clear, so they're already premultiplied.
        return CGImage.rgba(pixels, width: MapItem.size, height: MapItem.size)
    }

    /// A zoom that fits the whole map in a typical window, as a power of two so pixels stay crisp.
    static func fittingScale(for map: MapItem) -> CGFloat {
        let fit = 512 / CGFloat(map.sideInBlocks)
        let power = pow(2, floor(log2(fit)))
        return min(max(power, MapViewport.scaleRange.lowerBound), MapViewport.scaleRange.upperBound)
    }
}

/// A map in the sidebar: thumbnail, number, place and scale.
struct InGameMapRow: View {
    let session: WorldSession
    let map: MapItem

    var body: some View {
        HStack {
            if let image = session.selection.image(for: map) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Map #\(map.id)")
                CoordinateText(Text("\(Coordinates.text(x: Double(map.centerX), z: Double(map.centerZ))) · 1:\(map.blocksPerPixel)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(SidebarItem.inGameMap(map.id))
        .id(SidebarItem.inGameMap(map.id))
        .selectionDisabled(!session.presentation.canShow(map))
        .help(session.presentation.canShow(map) ? "Show this map where it belongs on the world map"
                                   : "This map was drawn in a dimension this world no longer has")
        .locationMenu(session: session, position: CGPoint(x: map.centerX, y: map.centerZ),
                      dimension: map.dimension, y: nil)
    }
}

/// Details of the selected in-game map in the inspector, with a slider to compare it with today's terrain.
struct InGameMapDetailView: View {
    let session: WorldSession
    let map: MapItem
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var selection = session.selection
        Form {
            Section {
                LabeledContent("Area") {
                    Text("\(map.sideInBlocks) × \(map.sideInBlocks) blocks")
                }
                LocationRow(title: Text("Center"), session: session,
                            coordinates: Coordinates(CGPoint(x: map.centerX, y: map.centerZ)), dimension: map.dimension)
                LabeledContent("Scale", value: String(localized: "1 pixel for every \(CountedText.blocks.locale(locale).format(Double(map.blocksPerPixel)))", locale: locale))
                if map.isLocked {
                    Label("Locked in a cartography table", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            } header: {
                InspectorHeading(title: Text("Map #\(map.id)"), symbol: ItemAppearance.mapSymbol)
            }
            Section {
                LabeledContent("Opacity") {
                    Slider(value: $selection.inGameMapOpacity, in: 0...1)
                }
            } footer: {
                Text("Lower the opacity to compare the map with today’s terrain.")
            }
        }
        .formStyle(.grouped)
    }
}
