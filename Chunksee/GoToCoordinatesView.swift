import ChunkseeKit
import SwiftUI

/// Whole block coordinates entered by the user, including a pasted typographic minus sign.
nonisolated struct MapCoordinates: Equatable, Sendable {
    let x: Int32
    let y: Int?
    let z: Int32

    init?(text: String) {
        let fields = text.replacingOccurrences(of: "−", with: "-").split(whereSeparator: \.isWhitespace)
        guard fields.count == 2 || fields.count == 3,
              let x = Int32(fields[0]), let z = Int32(fields[fields.count - 1]) else { return nil }
        if fields.count == 3 {
            guard let y = Int(fields[1]) else { return nil }
            self.y = y
        } else { self.y = nil }
        self.x = x
        self.z = z
    }

    init?(point: CGPoint) {
        guard let value = BlockPosition.mapCoordinates(x: point.x, y: nil, z: point.y) else { return nil }
        x = value.x
        y = value.y
        z = value.z
    }

    var position: CGPoint { CGPoint(x: Int(x), y: Int(z)) }

    var center: CGPoint { Self.center(of: position) }

    /// Coordinate editors use Minecraft's axis order, with an unknown height omitted.
    func entryText(height: Int?) -> String {
        [Int(x), height, Int(z)].compactMap { $0.map(String.init) }.joined(separator: " ")
    }

    /// Whole-block locations use their centers; exact entity positions never pass through here.
    static func center(of point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded(.down) + 0.5, y: point.y.rounded(.down) + 0.5)
    }
}

/// A sheet belongs to its world window; editing or cancelling never moves the map.
struct GoToCoordinatesView: View {
    let session: WorldSession
    @Environment(\.dismiss) private var dismiss
    @State private var coordinates: String
    @FocusState private var isFocused: Bool

    init(session: WorldSession) {
        self.session = session
        let center = session.map?.viewport.center ?? .zero
        if let point = MapCoordinates(point: center) {
            _coordinates = State(initialValue: point.entryText(height: session.map?.depth.cutawayY))
        } else {
            _coordinates = State(initialValue: "")
        }
    }

    private var destination: MapCoordinates? { MapCoordinates(text: coordinates) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Go to Coordinates").font(.headline)
            Text("Enter X Z or X Y Z in \(session.selectedDimensionID.map(session.presentation.dimensionName) ?? "").")
                .foregroundStyle(.secondary)
            LabeledContent("Coordinates") {
                TextField("X Z or X Y Z", text: $coordinates)
                    .labelsHidden()
                    .accessibilityLabel("Coordinates")
                    .accessibilityIdentifier("coordinate-entry")
                    .focused($isFocused)
                    .help("Enter whole block coordinates separated by spaces; Y is optional")
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onSubmit(go)
        .onAppear { isFocused = true }
    }

    private func go() {
        guard let destination else { return }
        session.navigation.goToCoordinates(destination.position, height: destination.y)
        dismiss()
    }
}
