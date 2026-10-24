import SwiftUI

/// Static overlay context uses one placement and container on screen and in exported images.
struct MapLegendOverlay: ViewModifier {
    let layers: MapContent

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if layers.lighting != nil || layers.mapStyle != .normal || layers.showsDarkSpots || layers.showsHeatMap || layers.slimeSeed != nil || layers.border != nil || layers.blockFilter.cacheKey != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if layers.blockFilter.isEnabled, !layers.blockFilter.highlightedIDs.isEmpty {
                        key("Highlighted Blocks") {
                            let accent = MapBlockFilter.Emphasis.accent
                            Rectangle().fill(Color(.sRGB, red: Double(accent.red) / 255,
                                                   green: Double(accent.green) / 255, blue: Double(accent.blue) / 255))
                        }
                    } else {
                        MapStyleLegend(style: layers.mapStyle, heightScale: layers.heightScale)
                    }
                    if !layers.blockFilter.effectiveHiddenIDs.isEmpty {
                        Label("Some Blocks Hidden", systemImage: "line.3.horizontal.decrease")
                            .font(.caption)
                    }
                    if layers.showsDarkSpots {
                        key("Dark Spots at Night") { sample(.dark) }
                        key("Light Unknown") { sample(.unknown) }
                        Text(DarkSpots.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: 240, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if let lighting = layers.lighting {
                        Label("Saved Time", systemImage: "sun.horizon")
                            .font(.caption)
                            .help("Lighting follows the world's last save. Choose Daylight in the View menu for constant lighting.")
                        Text(lighting.moonPhase).font(.caption).foregroundStyle(.secondary)
                    }
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

    @ViewBuilder private func sample(_ status: DarkSpots.Status) -> some View {
        if let image = DarkSpots.sample(status) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none)
        }
    }

    private var slimeColor: Color {
        let pixel = SlimeChunks.pixel
        // The mask stores premultiplied bytes; SwiftUI takes unpremultiplied color components.
        return Color(.sRGB, red: Double(pixel.red) / Double(pixel.alpha),
                     green: Double(pixel.green) / Double(pixel.alpha), blue: Double(pixel.blue) / Double(pixel.alpha),
                     opacity: Double(pixel.alpha) / 255)
    }
}

/// Every continuous map legend uses the same bar, tick placement and accessible text.
struct MapLegendScale: View {
    struct Label {
        var text: Text
        var position: Double
        var anchor: CGFloat
    }

    var colors: [Color]
    var labels: [Label]
    var marker: Double? = nil

    var body: some View {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            .frame(width: 200, height: 10)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if let marker {
                    Rectangle().fill(.primary).frame(width: 1, height: 14).offset(x: marker * 200)
                }
            }
            .accessibilityHidden(true)
        ZStack {
            ForEach(labels.indices, id: \.self) { index in
                let label = labels[index]
                label.text.fixedSize()
                    .alignmentGuide(HorizontalAlignment.center) { $0.width * label.anchor }
                    .frame(width: 200, alignment: .center)
                    .offset(x: label.position * 200 - 100)
            }
        }
        .font(.caption)
        .frame(width: 200, height: 14)
    }
}

/// The map edge and its legend sample use the same line treatment.
enum WorldBorderStyle {
    static let color = Color.red.opacity(0.85)
    static let lineWidth: CGFloat = 2
}
