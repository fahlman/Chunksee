import SwiftUI

/// The selected item's title and concept icon, shared by every information panel.
struct InspectorHeading: View {
    let title: Text
    let symbol: String

    var body: some View {
        Label { title } icon: { Image(systemName: symbol) }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}
