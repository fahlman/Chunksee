import AppKit
import ChunkseeKit
import SwiftUI

/// Only a saved appearance with a game-provided color source tints its symbol. Text always
/// follows native selection/appearance colors, and absent artwork leaves an ordinary symbol.
struct MobLocationLabel: View {
    let marker: CreatureMarker

    var body: some View {
        switch marker.creature.appearance?.colorSource(for: marker.creature.id) {
        case .tint(let color):
            MobLabel(marker: marker, color: MapColor(color),
                     colorName: marker.creature.appearance?.variant.map(PetDetailText.name))
        case .texture(let id): MobTextureLabel(marker: marker, texture: id)
        case nil: MobLabel(marker: marker)
        }
    }
}

private struct MobTextureLabel: View {
    let marker: CreatureMarker
    let texture: String
    @Environment(\.gameAssetLibrary) private var pictures
    @State private var loaded: (request: Request, color: MapColor?)?

    private struct Request: Equatable {
        let library: UUID?
        let texture: String
    }

    var body: some View {
        let request = Request(library: pictures?.identity, texture: texture)
        let color = loaded?.request == request ? loaded?.color : pictures?.cachedTextureColor(texture)
        MobLabel(marker: marker, color: color, colorName: color.map { color in
            // SwiftUI has no localized color-name API; AppKit supplies the native spoken name.
            NSColor(srgbRed: Double(color.red) / 255, green: Double(color.green) / 255,
                    blue: Double(color.blue) / 255, alpha: 1).accessibilityName
        }, appearanceName: marker.creature.appearance.map {
            PetDetailText.appearance($0, species: marker.creature.id)
        })
        .task(id: request) {
            guard loaded?.request != request, let pictures else { return }
            let resolved = try? await pictures.textureColor(request.texture)
            if !Task.isCancelled { loaded = (request, resolved) }
        }
    }
}

private struct MobLabel: View {
    let marker: CreatureMarker
    var color: MapColor?
    var colorName: String?
    var appearanceName: String?

    var body: some View {
        LocationLabel(title: Text(marker.name)) {
            Image(systemName: marker.group.symbol)
                .foregroundStyle(color.map(Color.init) ?? .primary)
                .shadow(color: color == nil ? .clear : .primary.opacity(0.45), radius: 0.5)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: Text {
        let title = colorName.map { Text("\($0) \(marker.name)") } ?? Text(marker.name)
        // A sampled color name is approximate: macOS calls the cyan skin "blue".
        // Keep the independent saved variant audible, including when art is unavailable.
        return appearanceName.map { Text("\(title), \($0)") } ?? title
    }
}
