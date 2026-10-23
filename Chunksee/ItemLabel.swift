import ChunkseeKit
import SwiftUI

/// Item rows and compact inventory slots use one picture and fallback path.
struct ItemIcon: View {
    let item: ItemStack
    @Environment(\.gameAssetLibrary) private var pictures
    @State private var loaded: (request: Request, image: CGImage)?

    private struct Request: Equatable {
        let library: UUID?
        let item: ItemStack
    }

    var body: some View {
        let request = Request(library: pictures?.identity, item: item)
        let image = loaded?.request == request ? loaded?.image : pictures?.cachedPicture(for: item)
        ItemGraphic(id: item.id, isEnchanted: ItemAppearance.isEnchanted(item),
                    image: image)
            .task(id: request) {
                guard loaded?.request != request, let pictures else { return }
                let resolved: CGImage?
                if let image { resolved = image }
                else { resolved = try? await pictures.picture(for: request.item) }
                // Retain warm hits too, so cache eviction cannot replace a visible picture.
                if let resolved, !Task.isCancelled { loaded = (request, resolved) }
            }
    }
}

/// The same drawing component serves both asynchronously loaded pictures and immediate fallbacks.
struct ItemGraphic: View {
    let id: String
    let isEnchanted: Bool
    let image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: ItemAppearance.symbol(for: id))
                    .font(.body)
                    .foregroundStyle(ItemAppearance.tint(for: id))
            }
        }
        .frame(width: 20, height: 20)
        .shadow(color: isEnchanted ? .purple : .clear, radius: 3)
        .accessibilityHidden(true)
    }
}

/// Native labels keep their caller's wording and layout; item appearance has one renderer.
struct ItemLabel: View {
    let item: ItemStack
    let title: Text

    init(item: ItemStack, title: Text) {
        self.item = item
        self.title = title
    }

    init(id: String, title: Text) {
        self.init(item: ItemStack(id: id), title: title)
    }

    var body: some View {
        Label {
            title
        } icon: {
            ItemIcon(item: item)
        }
    }
}

private struct GameAssetLibraryKey: EnvironmentKey {
    nonisolated static let defaultValue: GameAssetLibrary? = nil
}

extension EnvironmentValues {
    var gameAssetLibrary: GameAssetLibrary? {
        get { self[GameAssetLibraryKey.self] }
        set { self[GameAssetLibraryKey.self] = newValue }
    }
}

/// A document retains its shared library. Changing the chosen folder or saved version makes
/// old pictures ineligible immediately; returning to the app also notices a replaced jar.
struct WorldGameAssets: ViewModifier {
    let resources: MinecraftResources
    let version: GameAssetVersion?
    let map: MapModel?
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded: (source: Source, pictures: GameAssetLibrary)?

    private struct Source: Equatable {
        let generation: UUID
        let version: GameAssetVersion?
    }
    private struct Request: Equatable {
        let source: Source
        let phase: ScenePhase
        let map: ObjectIdentifier?
    }

    func body(content: Content) -> some View {
        let source = Source(generation: resources.generation, version: version)
        content
            .environment(\.gameAssetLibrary, loaded?.source == source ? loaded?.pictures : nil)
            .task(id: Request(source: source, phase: scenePhase, map: map.map(ObjectIdentifier.init))) {
                if loaded?.source != source {
                    loaded = nil
                    map?.setGameAssets(nil)
                }
                guard scenePhase == .active else { return }
                guard let version, let pictures = await resources.library(for: version), !Task.isCancelled else {
                    if !Task.isCancelled { loaded = nil; map?.setGameAssets(nil) }
                    return
                }
                loaded = (source, pictures)
                map?.setGameAssets(pictures)
            }
    }
}
