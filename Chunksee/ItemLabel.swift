import ChunkseeKit
import SwiftUI

/// Item rows and compact inventory slots use one picture and fallback path.
struct ItemIcon: View {
    let item: ItemStack
    var fallbackSymbol: String?
    @Environment(\.gameArtworkLibrary) private var pictures
    @State private var loaded: (request: Request, image: CGImage)?

    private struct Request: Equatable {
        let library: UUID?
        let item: ItemStack
    }

    var body: some View {
        let request = Request(library: pictures?.identity, item: item)
        let image = loaded?.request == request ? loaded?.image : pictures?.cachedPicture(for: item)
        ItemGraphic(id: item.id, isEnchanted: ItemAppearance.isEnchanted(item),
                    image: image, fallbackSymbol: fallbackSymbol)
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
    var fallbackSymbol: String?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else if let fallbackSymbol {
                Image(systemName: fallbackSymbol)
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

private struct GameArtworkLibraryKey: EnvironmentKey {
    nonisolated static let defaultValue: GameArtworkLibrary? = nil
}

extension EnvironmentValues {
    var gameArtworkLibrary: GameArtworkLibrary? {
        get { self[GameArtworkLibraryKey.self] }
        set { self[GameArtworkLibraryKey.self] = newValue }
    }
}

/// A document retains its shared library. Changing the chosen folder makes
/// old pictures ineligible immediately; returning to the app also notices a replaced jar.
struct WorldGameAssets: ViewModifier {
    let world: WorldResources
    @Environment(\.scenePhase) private var scenePhase
    private struct Request: Equatable {
        let source: WorldGameAssetSource
        let phase: ScenePhase
        let world: ObjectIdentifier
        let preferredLanguage: String
    }

    func body(content: Content) -> some View {
        let resources = world.names.minecraft
        let source = WorldGameAssetSource(generation: resources.generation)
        let preferredLanguage = GameLanguageChoice.preferredLanguage
        content
            .environment(\.gameArtworkLibrary, world.gameArtworkLibrary(for: source))
            .environment(\.gameNames, world.gameNames)
            .task(id: Request(source: source, phase: scenePhase, world: ObjectIdentifier(world), preferredLanguage: preferredLanguage)) {
                guard scenePhase == .active else { return }
                world.refreshGameLanguage(preferredLanguage: preferredLanguage)
                world.refreshGameAssets()
            }
    }
}
