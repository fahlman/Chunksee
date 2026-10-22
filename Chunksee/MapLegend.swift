import SwiftUI

/// Static overlay context uses one placement and container on screen and in exported images.
struct MapLegendOverlay: ViewModifier {
    let layers: MapContent

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if layers.showsHeatMap || layers.slimeSeed != nil || layers.border != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if layers.showsHeatMap { HeatMapLegend() }
                    if layers.slimeSeed != nil {
                        key("Slime Chunks") {
                            Rectangle().fill(slimeColor)
                        }
                    }
                    if layers.border != nil {
                        key("World Border") {
                            Rectangle().stroke(WorldBorderStyle.color, lineWidth: WorldBorderStyle.lineWidth)
                        }
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .contain)
                .padding(10)
            }
        }
    }

    private func key(_ title: LocalizedStringKey, @ViewBuilder sample: () -> some View) -> some View {
        HStack {
            sample().frame(width: 26, height: 10).accessibilityHidden(true)
            Text(title)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var slimeColor: Color {
        let pixel = SlimeChunks.pixel
        // The mask stores premultiplied bytes; SwiftUI takes unpremultiplied color components.
        return Color(.sRGB, red: Double(pixel.red) / Double(pixel.alpha),
                     green: Double(pixel.green) / Double(pixel.alpha), blue: Double(pixel.blue) / Double(pixel.alpha),
                     opacity: Double(pixel.alpha) / 255)
    }
}

/// The map edge and its legend sample use the same line treatment.
enum WorldBorderStyle {
    static let color = Color.red.opacity(0.85)
    static let lineWidth: CGFloat = 2
}
