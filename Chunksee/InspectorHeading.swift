import ChunkseeKit
import SwiftUI

/// The selected item's title and concept icon, shared by every information panel.
struct InspectorHeading: View {
    let title: Text
    let symbol: String
    var picture: Picture?
    @Environment(\.gameArtworkLibrary) private var pictures
    @State private var loaded: (request: Request, item: ItemStack?)?

    enum Picture: Equatable {
        case item(ItemStack)
        case mob(String)
    }

    private struct Request: Equatable {
        let library: UUID?
        let picture: Picture?
    }

    var body: some View {
        let request = Request(library: pictures?.identity, picture: picture)
        let item: ItemStack? = switch picture {
        case .item(let stack): stack
        case .mob: loaded?.request == request ? loaded?.item : nil
        case nil: nil
        }
        Label { title } icon: {
            if let item { ItemIcon(item: item, fallbackSymbol: symbol) }
            else { Image(systemName: symbol).frame(width: 20, height: 20).accessibilityHidden(true) }
        }
        .font(.headline)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .task(id: request) {
            guard case .mob(let species) = picture, let pictures,
                  loaded?.request != request else { return }
            let item = try? await pictures.data.spawnEgg(for: species)
            if !Task.isCancelled { loaded = (request, item) }
        }
    }
}
