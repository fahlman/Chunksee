import SwiftUI

/// Item rows and compact inventory slots use the same symbol, color and enchantment styling.
struct ItemIcon: View {
    let id: String
    var isEnchanted = false

    var body: some View {
        Image(systemName: ItemAppearance.symbol(for: id))
            .font(.body)
            .foregroundStyle(ItemAppearance.tint(for: id))
            .shadow(color: isEnchanted ? .purple : .clear, radius: 3)
            .accessibilityHidden(true)
    }
}

/// Native labels keep their caller's wording and layout; item appearance has one renderer.
struct ItemLabel: View {
    let id: String
    let title: Text
    var isEnchanted = false

    var body: some View {
        Label {
            title
        } icon: {
            ItemIcon(id: id, isEnchanted: isEnchanted)
        }
    }
}
