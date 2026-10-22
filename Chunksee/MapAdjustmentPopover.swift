import SwiftUI

/// Map adjustments share their presentation; each control keeps its own value and editing rules.
struct MapAdjustmentPopover<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .padding()
        .frame(width: 340)
    }
}

struct MapAdjustmentStepButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 16, height: 16)
        }
        .accessibilityLabel(title)
    }
}

struct MapAdjustmentDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button("Done", action: action).keyboardShortcut(.cancelAction)
    }
}
