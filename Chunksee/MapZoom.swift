import Foundation
import SwiftUI

enum ZoomPercentage {
    static let levels: [CGFloat] = [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 16, 32]

    static func text(_ scale: CGFloat) -> String {
        if scale < 0.01 {
            return Double(scale).formatted(.percent.precision(.significantDigits(1...4)))
        }
        return Double(scale).formatted(.percent.precision(.fractionLength(0...2)))
    }

    static func entry(_ scale: CGFloat, locale: Locale) -> String {
        Double(scale * 100).formatted(.number.locale(locale).grouping(.never).precision(.significantDigits(1...10)))
    }

    /// Manual entry shares the existing zoom limits. Fit World may still choose a smaller scale.
    static func scale(from percentage: String, locale: Locale) -> CGFloat? {
        let input = percentage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Parsing a number alone accepts a valid prefix of malformed text, such as "100abc".
        guard let match = input.wholeMatch(of: FloatingPointFormatStyle<Double>.number.locale(locale).grouping(.never)),
              match.output.isFinite else { return nil }
        let scale = CGFloat(match.output / 100)
        return (MapViewport.minimumManualScale...MapViewport.scaleRange.upperBound).contains(scale) ? scale : nil
    }
}

struct MapZoomControl: View {
    let session: WorldSession
    @Bindable var map: MapModel
    @State private var showsPopover = false

    var body: some View {
        Button { showsPopover = true } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                Text(ZoomPercentage.text(map.viewport.scale))
                    .monospacedDigit()
                    .frame(minWidth: 56)
            }
        }
        .accessibilityLabel("Zoom")
        .accessibilityValue(Text(ZoomPercentage.text(map.viewport.scale)))
        .accessibilityIdentifier("zoom-control")
        .help("Choose a zoom level or fit the world")
        .popover(isPresented: $showsPopover) {
            MapZoomPopover(session: session, map: map)
        }
    }
}

private struct MapZoomPopover: View {
    let session: WorldSession
    @Bindable var map: MapModel
    @State private var percentage = ""
    @FocusState private var isPercentageFocused: Bool
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    private var sliderRange: ClosedRange<Double> {
        log2(Double(MapViewport.minimumManualScale))...log2(Double(MapViewport.scaleRange.upperBound))
    }

    private var sliderScale: CGFloat { max(MapViewport.minimumManualScale, map.viewport.scale) }

    private func choose(_ scale: CGFloat) {
        percentage = ZoomPercentage.entry(scale, locale: locale)
        isPercentageFocused = false
        map.viewport.scale = scale
    }

    private func commitPercentage() {
        // Merely opening or leaving an unusually small fitted view must not round or clamp it.
        if percentage != ZoomPercentage.entry(map.viewport.scale, locale: locale),
           let scale = ZoomPercentage.scale(from: percentage, locale: locale) {
            map.viewport.scale = scale
        }
        percentage = ZoomPercentage.entry(map.viewport.scale, locale: locale)
    }

    private func zoom(by factor: CGFloat) {
        commitPercentage()
        map.zoom(by: factor)
        percentage = ZoomPercentage.entry(map.viewport.scale, locale: locale)
        isPercentageFocused = false
    }

    private func finish() {
        commitPercentage()
        dismiss()
    }

    var body: some View {
        MapAdjustmentPopover(title: "Zoom") {
            HStack {
                MapAdjustmentStepButton(title: "Zoom Out", systemImage: "minus") { zoom(by: 0.5) }
                    .disabled(!map.viewport.canZoomOut)
                    .accessibilityIdentifier("zoom-out")
                // Equal travel doubles/halves zoom, keeping both ends of the range usable.
                Slider(value: Binding {
                    log2(Double(sliderScale))
                } set: { choose(CGFloat(exp2($0))) }, in: sliderRange) {
                    Text("Zoom")
                } minimumValueLabel: {
                    Text(ZoomPercentage.text(MapViewport.minimumManualScale))
                } maximumValueLabel: {
                    Text(ZoomPercentage.text(MapViewport.scaleRange.upperBound))
                }
                .labelsHidden()
                .accessibilityIdentifier("zoom-slider")
                .accessibilityValue(Text(ZoomPercentage.text(sliderScale)))
                MapAdjustmentStepButton(title: "Zoom In", systemImage: "plus") { zoom(by: 2) }
                    .disabled(!map.viewport.canZoomIn)
                    .accessibilityIdentifier("zoom-in")
            }

            HStack {
                Text("Zoom")
                TextField("Zoom percentage", text: $percentage)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .focused($isPercentageFocused)
                    .onSubmit { commitPercentage() }
                    .onExitCommand(perform: finish)
                    .accessibilityLabel("Zoom percentage")
                    .accessibilityIdentifier("zoom-percentage")
                    .help("Enter a percentage from \(ZoomPercentage.text(MapViewport.minimumManualScale)) to \(ZoomPercentage.text(MapViewport.scaleRange.upperBound))")
                Text("%")
            }
            Picker("Presets", selection: Binding { map.viewport.scale } set: { choose($0) }) {
                if !ZoomPercentage.levels.contains(map.viewport.scale) {
                    Text(ZoomPercentage.text(map.viewport.scale)).tag(map.viewport.scale)
                    Divider()
                }
                ForEach(ZoomPercentage.levels, id: \.self) { level in
                    Text(ZoomPercentage.text(level)).tag(level)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Zoom presets")
            .accessibilityIdentifier("zoom-presets")
            HStack {
                Button("Actual Size") { choose(1) }
                    .accessibilityIdentifier("zoom-actual-size")
                Button("Fit World") {
                    session.navigation.fitWorld()
                    percentage = ZoomPercentage.entry(map.viewport.scale, locale: locale)
                    isPercentageFocused = false
                }
                .disabled(!session.navigation.canFitWorld)
                .accessibilityIdentifier("zoom-fit-world")
                Spacer()
                MapAdjustmentDoneButton(action: finish)
            }
        }
        .onAppear { percentage = ZoomPercentage.entry(map.viewport.scale, locale: locale) }
        .onChange(of: map.viewport.scale) { _, scale in percentage = ZoomPercentage.entry(scale, locale: locale) }
        .onChange(of: isPercentageFocused) { _, focused in if !focused { commitPercentage() } }
    }
}
