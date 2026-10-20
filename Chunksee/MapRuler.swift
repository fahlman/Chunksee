import CoreGraphics
import Foundation
import SwiftUI

/// Endpoints are whole world blocks, so panning and zooming never change the measurement.
nonisolated struct MapRuler: Equatable {
    var isEnabled = false {
        didSet { if !isEnabled { clear() } }
    }
    private(set) var start: MapCoordinates?
    private(set) var end: MapCoordinates?

    var distance: Double? {
        guard let start, let end else { return nil }
        return hypot(Double(end.x) - Double(start.x), Double(end.z) - Double(start.z))
    }

    mutating func mark(_ point: CGPoint) {
        guard isEnabled, let coordinates = MapCoordinates(point: point) else { return }
        if start == nil || end != nil {
            start = coordinates
            end = nil
        } else {
            end = coordinates
        }
    }

    mutating func clear() { start = nil; end = nil }

    mutating func escape() {
        if start != nil { clear() } else { isEnabled = false }
    }

    @MainActor
    func draw(in context: GraphicsContext, viewport: MapViewport, size: CGSize) {
        guard isEnabled, let start else { return }
        func point(_ coordinates: MapCoordinates) -> CGPoint {
            viewport.viewPoint(for: coordinates.center, in: size)
        }
        func endpoint(_ position: CGPoint) {
            let circle = Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10))
            context.fill(circle, with: .color(.accentColor))
            context.stroke(circle, with: .color(.white), lineWidth: 2)
        }
        let first = point(start)
        if let end, let distance {
            let last = point(end)
            let line = Path { $0.move(to: first); $0.addLine(to: last) }
            context.stroke(line, with: .color(.black.opacity(0.6)), lineWidth: 5)
            context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, dash: [6, 3]))
            endpoint(last)
            let text = context.resolve(Text(distance, format: CountedText.blocks.locale(context.environment.locale))
                .font(.callout.monospacedDigit()).foregroundStyle(.white))
            let textSize = text.measure(in: CGSize(width: 200, height: 30))
            // Keep short measurements' endpoint dots clear of the distance text.
            let midX = (first.x + last.x) / 2
            let label = CGRect(x: midX - textSize.width / 2 - 6, y: min(first.y, last.y) - textSize.height - 20,
                               width: textSize.width + 12, height: textSize.height + 8)
            context.fill(Path(roundedRect: label, cornerRadius: 5), with: .color(.black.opacity(0.75)))
            context.draw(text, at: CGPoint(x: label.midX, y: label.midY))
        }
        endpoint(first)
    }
}
