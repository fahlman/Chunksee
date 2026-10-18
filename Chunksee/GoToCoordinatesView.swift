import SwiftUI

/// Whole block coordinates entered by the user, including a pasted typographic minus sign.
nonisolated struct MapCoordinates: Equatable, Sendable {
    let x: Int32
    let z: Int32

    init?(x: String, z: String) {
        func number(_ text: String) -> Int32? {
            Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "−", with: "-"))
        }
        guard let x = number(x), let z = number(z) else { return nil }
        self.x = x
        self.z = z
    }

    init?(point: CGPoint) {
        guard let x = Int32(exactly: point.x.rounded(.down)),
              let z = Int32(exactly: point.y.rounded(.down)) else { return nil }
        self.x = x
        self.z = z
    }

    var position: CGPoint { CGPoint(x: Int(x), y: Int(z)) }
}

/// A sheet belongs to its world window; editing or cancelling never moves the map.
struct GoToCoordinatesView: View {
    let session: WorldSession
    @Environment(\.dismiss) private var dismiss
    @State private var x: String
    @State private var z: String
    @FocusState private var focusedField: Field?

    private enum Field { case x, z }

    init(session: WorldSession) {
        self.session = session
        let center = session.map?.viewport.center ?? .zero
        _x = State(initialValue: String(Int(center.x.rounded(.down))))
        _z = State(initialValue: String(Int(center.y.rounded(.down))))
    }

    private var destination: MapCoordinates? { MapCoordinates(x: x, z: z) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Go to Coordinates").font(.headline)
            Text("Enter whole block coordinates in \(session.selectedDimensionID.map(session.dimensionName) ?? "").")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading) {
                GridRow {
                    Text("X")
                    TextField("X coordinate", text: $x)
                        .labelsHidden()
                        .accessibilityLabel("X coordinate")
                        .focused($focusedField, equals: .x)
                }
                GridRow {
                    Text("Z")
                    TextField("Z coordinate", text: $z)
                        .labelsHidden()
                        .accessibilityLabel("Z coordinate")
                        .focused($focusedField, equals: .z)
                }
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
        .onAppear { focusedField = .x }
    }

    private func go() {
        guard let destination else { return }
        session.goToCoordinates(destination.position)
        dismiss()
    }
}
