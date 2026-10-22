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
}

struct MapDepthControl: View {
    @Bindable var map: MapModel
    let heightRange: ClosedRange<Int>?
    @Binding var showsPopover: Bool

    var body: some View {
        Button {
            showsPopover = true
        } label: {
            // A toolbar Label uses its changing visible title as the accessible name.
            // Keep the explicit Map Height name, as the Zoom control does.
            HStack {
                Image(systemName: "square.3.layers.3d")
                if map.depth.isSurface {
                    Text("Surface")
                } else {
                    Text("Y \(map.depth.y.formatted())").monospacedDigit()
                }
            }
        }
        .accessibilityLabel("Map Height")
        .accessibilityValue(Text(map.depth.accessibilityDescription))
        .accessibilityIdentifier("cutaway-control")
        .help("Choose Surface or a cutaway height")
        .popover(isPresented: $showsPopover) {
            MapDepthPopover(map: map, heightRange: heightRange)
        }
    }
}

private struct MapDepthPopover: View {
    @Bindable var map: MapModel
    let heightRange: ClosedRange<Int>?
    @State private var draggedY: Int?
    @FocusState private var isHeightFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var displayedY: Int { draggedY ?? map.depth.y }

    private var height: Binding<Int> {
        Binding { displayedY } set: {
            // TextField writes its formatted value back as the slider draft changes too.
            if draggedY != nil { draggedY = $0 }
            else { map.setDepth(MapDepth(y: $0, isSurface: false)) }
        }
    }

    private func stepHeight(by step: Int) {
        let (next, overflow) = displayedY.addingReportingOverflow(step)
        if !overflow { height.wrappedValue = next }
    }

    var body: some View {
        MapAdjustmentPopover(title: "Map Height") {
            Picker("Mode", selection: Binding {
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

            HStack {
                MapAdjustmentStepButton(title: "Decrease Y", systemImage: "minus") { stepHeight(by: -1) }
                    .disabled(displayedY == Int.min)
                    .accessibilityIdentifier("cutaway-decrease")
                if let heightRange {
                    slider(in: heightRange)
                } else {
                    Text("Height range unavailable")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("cutaway-range-unavailable")
                }
                MapAdjustmentStepButton(title: "Increase Y", systemImage: "plus") { stepHeight(by: 1) }
                    .disabled(displayedY == Int.max)
                    .accessibilityIdentifier("cutaway-increase")
            }
            .disabled(map.depth.isSurface)
            HStack {
                Text("Y")
                TextField("Y", value: height, format: .number.grouping(.never))
                    .focused($isHeightFocused)
                    .onExitCommand { dismiss() }
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .accessibilityLabel("Y coordinate")
                    .accessibilityIdentifier("cutaway-y")
                    .help("Show the terrain at or below this height")
            }
            .disabled(map.depth.isSurface)
            HStack {
                Spacer()
                MapAdjustmentDoneButton { dismiss() }
            }
        }
        .onAppear { isHeightFocused = !map.depth.isSurface }
        .onChange(of: map.depth.isSurface) { _, isSurface in isHeightFocused = !isSurface }
        .onDisappear { draggedY = nil }
    }

    private func sliderY(in range: ClosedRange<Int>) -> Int {
        min(max(displayedY, range.lowerBound), range.upperBound)
    }

    private func slider(in range: ClosedRange<Int>) -> some View {
        // Numeric entry stays unrestricted; it never changes the dimension's verified limits.
        Slider(value: Binding {
            Double(sliderY(in: range))
        } set: {
            guard let y = Int(exactly: $0.rounded()) else { return }
            height.wrappedValue = y
        }, in: Double(range.lowerBound)...Double(range.upperBound)) {
            Text("Y coordinate")
        } minimumValueLabel: {
            Text(range.lowerBound, format: .number.grouping(.never))
        } maximumValueLabel: {
            Text(range.upperBound, format: .number.grouping(.never))
        } onEditingChanged: { editing in
            if editing {
                // The map keeps its committed depth while the native slider edits this draft.
                draggedY = sliderY(in: range)
            } else if let y = draggedY {
                draggedY = nil
                height.wrappedValue = y
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("cutaway-slider")
        .accessibilityValue(Text("Y \(sliderY(in: range).formatted())"))
        .accessibilityAdjustableAction { direction in
            let step: Int
            switch direction {
            case .increment: step = 1
            case .decrement: step = -1
            @unknown default: return
            }
            let (next, overflow) = sliderY(in: range).addingReportingOverflow(step)
            if !overflow { height.wrappedValue = min(max(next, range.lowerBound), range.upperBound) }
        }
        .help("Choose within this dimension’s build height, or type any Y coordinate below")
    }
}
