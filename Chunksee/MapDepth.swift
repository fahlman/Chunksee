import Foundation
import SwiftUI

/// One document's terrain presentation, including the last chosen height while on Surface.
nonisolated struct MapDepth: Equatable, Sendable {
    var y = 64
    var isSurface = true
    var cutawayY: Int? { isSurface ? nil : y }
    var accessibilityDescription: String {
        isSurface ? String(localized: "Surface") : String(localized: "Cutaway at Y \(y.formatted())")
    }

    /// Slider travel, not a dimension's world-generation bounds. Numeric entry extends it.
    var sliderRange: ClosedRange<Double> { Double(min(-64, y))...Double(max(319, y)) }
}

struct MapDepthControl: View {
    @Bindable var map: MapModel
    @State private var draggedY: Int?

    private var displayedY: Int { draggedY ?? map.depth.y }

    private var height: Binding<Int> {
        Binding { displayedY } set: {
            draggedY = nil
            map.setDepth(MapDepth(y: $0, isSurface: false))
        }
    }

    var body: some View {
        HStack {
            Slider(value: Binding {
                Double(displayedY)
            } set: {
                guard let y = Int(exactly: $0.rounded()) else { return }
                if draggedY != nil {
                    draggedY = y
                } else {
                    height.wrappedValue = y
                }
            }, in: map.depth.sliderRange, step: 1) {
                Text("Cutaway Height")
            } onEditingChanged: { editing in
                if editing {
                    // The map keeps its committed depth while the native slider edits this draft.
                    draggedY = map.depth.y
                } else if let y = draggedY {
                    height.wrappedValue = y
                }
            }
            .frame(width: 130)
            .accessibilityIdentifier("cutaway-slider")
            .accessibilityValue(Text("Y \(displayedY.formatted()); \(map.depth.accessibilityDescription)"))
            Text("Y").foregroundStyle(.secondary)
            TextField("Y", value: height, format: .number.grouping(.never))
                .frame(width: 65)
                .monospacedDigit()
                .accessibilityLabel("Cutaway Y coordinate")
                .accessibilityIdentifier("cutaway-y")
                .help("Show the terrain at or below this height")
            Button("Surface") {
                map.setDepth(MapDepth(y: map.depth.y, isSurface: true))
            }
            .disabled(map.depth.isSurface)
            .accessibilityIdentifier("cutaway-surface")
            .help("Return to the normal surface map")
        }
        .onDisappear { draggedY = nil }
    }
}
