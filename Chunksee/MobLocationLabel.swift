import ChunkseeKit
import SwiftUI

/// Only a saved appearance with a game-provided color source tints its symbol. Text always
/// follows native selection/appearance colors, and absent artwork leaves an ordinary symbol.
struct MobLocationLabel: View {
    let marker: CreatureMarker

    var body: some View {
        switch marker.creature.appearance?.colorSource(for: marker.creature.id) {
        case .tint(let color):
            MobLabel(marker: marker, color: MapColor(color))
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
        MobLabel(marker: marker, color: color)
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
        // The saved variant identifies the tint without guessing a name from its pixels.
        // Keep that identity audible even when its artwork is unavailable.
        if let appearance = marker.creature.appearance, let variant = appearance.variant,
           appearance.colorSource(for: marker.creature.id) != nil {
            Text("\(PetDetailText.name(variant)) \(marker.name)")
        } else {
            Text(marker.name)
        }
    }
}
