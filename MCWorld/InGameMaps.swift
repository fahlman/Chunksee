import CoreGraphics
import MCWorldKit
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
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: MapItem.size, height: MapItem.size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: MapItem.size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
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
        Button {
            session.show(map)
        } label: {
            HStack {
                if let image = session.image(for: map) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Map #\(map.id)")
                    Text("X \(map.centerX)  Z \(map.centerZ) · 1:\(map.blocksPerPixel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(session.selectedInGameMapID == map.id ? Color.accentColor.opacity(0.2) : nil)
        .help("Show this map where it belongs on the world map")
    }
}

/// Details of the selected in-game map, with a slider to compare it with today's terrain.
struct InGameMapCard: View {
    @Bindable var session: WorldSession
    let map: MapItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Map #\(map.id)", systemImage: "map").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { session.selectedInGameMapID = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text("\(map.sideInBlocks) × \(map.sideInBlocks) blocks around X \(map.centerX), Z \(map.centerZ), 1 pixel for every \(map.blocksPerPixel) blocks.")
                .foregroundStyle(.secondary)
            if map.isLocked {
                Label("Locked in a cartography table", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            LabeledContent("Opacity") {
                Slider(value: $session.inGameMapOpacity, in: 0...1)
            }
            Text("Lower the opacity to compare the map with today’s terrain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
