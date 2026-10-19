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
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover = true
        } label: {
            Label {
                if map.depth.isSurface {
                    Text("Surface")
                } else {
                    Text("Y \(map.depth.y.formatted())").monospacedDigit()
                }
            } icon: {
                Image(systemName: "square.3.layers.3d")
            }
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Map Height")
        .accessibilityValue(Text(map.depth.accessibilityDescription))
        .accessibilityIdentifier("cutaway-control")
        .help("Choose Surface or a cutaway height")
        .popover(isPresented: $showsPopover) {
            MapDepthPopover(map: map)
        }
    }
}

private struct MapDepthPopover: View {
    @Bindable var map: MapModel
    @State private var draggedY: Int?

    private var displayedY: Int { draggedY ?? map.depth.y }

    private var height: Binding<Int> {
        Binding { displayedY } set: {
            draggedY = nil
            map.setDepth(MapDepth(y: $0, isSurface: false))
        }
    }

    private func stepHeight(by step: Int) {
        let (next, overflow) = displayedY.addingReportingOverflow(step)
        if !overflow { height.wrappedValue = next }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Map View", selection: Binding {
                map.depth.isSurface
            } set: { isSurface in
                draggedY = nil
                map.setDepth(MapDepth(y: map.depth.y, isSurface: isSurface))
            }) {
                Text("Surface").tag(true).accessibilityIdentifier("cutaway-surface")
                Text("Cutaway").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cutaway-mode")

            // Exact entry and the stepper provide one-block changes without dense slider ticks.
            Slider(value: Binding {
                Double(displayedY)
            } set: {
                guard let y = Int(exactly: $0.rounded()) else { return }
                if draggedY != nil {
                    draggedY = y
                } else {
                    height.wrappedValue = y
                }
            }, in: map.depth.sliderRange) {
                Text("Cutaway Height")
            } minimumValueLabel: {
                Text(map.depth.sliderRange.lowerBound, format: .number.grouping(.never))
            } maximumValueLabel: {
                Text(map.depth.sliderRange.upperBound, format: .number.grouping(.never))
            } onEditingChanged: { editing in
                if editing {
                    // The map keeps its committed depth while the native slider edits this draft.
                    draggedY = map.depth.y
                } else if let y = draggedY {
                    height.wrappedValue = y
                }
            }
            .labelsHidden()
            .disabled(map.depth.isSurface)
            .accessibilityIdentifier("cutaway-slider")
            .accessibilityValue(Text("Y \(displayedY.formatted()); \(map.depth.accessibilityDescription)"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: stepHeight(by: 1)
                case .decrement: stepHeight(by: -1)
                @unknown default: break
                }
            }
            HStack {
                Text("Y")
                TextField("Y", value: height, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .accessibilityLabel("Cutaway Y coordinate")
                    .accessibilityIdentifier("cutaway-y")
                    .help("Show the terrain at or below this height")
                // A full Int range cannot form the distance required by Stepper's ranged binding.
                Stepper("Cutaway Height",
                        onIncrement: displayedY < Int.max ? { stepHeight(by: 1) } : nil,
                        onDecrement: displayedY > Int.min ? { stepHeight(by: -1) } : nil)
                    .labelsHidden()
                    .accessibilityValue(Text("Y \(displayedY.formatted())"))
                    .accessibilityIdentifier("cutaway-stepper")
            }
            .disabled(map.depth.isSurface)
        }
        .padding()
        .onDisappear { draggedY = nil }
    }
}
