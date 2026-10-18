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

    private var height: Binding<Int> {
        Binding { map.depth.y } set: { map.setDepth(MapDepth(y: $0, isSurface: false)) }
    }

    var body: some View {
        HStack {
            Slider(value: Binding {
                Double(map.depth.y)
            } set: {
                if let y = Int(exactly: $0.rounded()) { height.wrappedValue = y }
            }, in: map.depth.sliderRange, step: 1) {
                Text("Cutaway Height")
            }
            .frame(width: 130)
            .accessibilityIdentifier("cutaway-slider")
            .accessibilityValue(Text("Y \(map.depth.y.formatted()); \(map.depth.accessibilityDescription)"))
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
    }
}
