import SwiftUI

/// Label eligibility stays with MarkerStyle. This owns which eligible names fit together.
nonisolated enum MarkerLabelLayout {
    enum Priority: Int { case selected, player, namedPet, other }

    struct Candidate {
        let id: String
        let priority: Priority
        let frame: CGRect
    }

    /// Keep a little clear space around each pill. Stable identities prevent scan order from
    /// changing the winner when two labels have the same priority.
    static func visibleIndices(_ labels: [Candidate]) -> [Int] {
        let order = labels.indices.sorted {
            let a = labels[$0], b = labels[$1]
            return a.priority == b.priority ? a.id < b.id : a.priority.rawValue < b.priority.rawValue
        }
        var visible: [Int] = []
        var accepted: [CGRect] = []
        var buckets: [Cell: [CGRect]] = [:]
        var unbucketed: [CGRect] = []
        for index in order {
            let frame = labels[index].frame.insetBy(dx: -2, dy: -2)
            guard !frame.isEmpty, !frame.isInfinite, !frame.isNull,
                  [frame.minX, frame.maxX, frame.minY, frame.maxY].allSatisfy(\.isFinite) else { continue }
            let cells = cells(for: frame)
            let overlaps: Bool
            if let cells {
                overlaps = unbucketed.contains(where: frame.intersects)
                    || cells.contains { buckets[$0, default: []].contains(where: frame.intersects) }
            } else {
                overlaps = accepted.contains(where: frame.intersects)
            }
            guard !overlaps else { continue }
            visible.append(index)
            accepted.append(frame)
            if let cells {
                for cell in cells { buckets[cell, default: []].append(frame) }
            } else {
                unbucketed.append(frame)
            }
        }
        return visible
    }

    private struct Cell: Hashable { let x: Int; let y: Int }

    /// Normal labels cover at most a few cells, so crowded maps compare nearby names only.
    /// Unusually large or unrepresentable rectangles use the same rule without integer traps.
    private static func cells(for frame: CGRect) -> [Cell]? {
        guard let x0 = Int(exactly: floor(frame.minX / 256)), let x1 = Int(exactly: floor(frame.maxX / 256)),
              let y0 = Int(exactly: floor(frame.minY / 256)), let y1 = Int(exactly: floor(frame.maxY / 256)) else { return nil }
        let dx = x1.subtractingReportingOverflow(x0), dy = y1.subtractingReportingOverflow(y0)
        guard !dx.overflow, !dy.overflow, (0...2).contains(dx.partialValue), (0...2).contains(dy.partialValue) else { return nil }
        return (x0...x1).flatMap { x in (y0...y1).map { Cell(x: x, y: $0) } }
    }
}

/// Text is measured once, after the zoom gate, then used by both layout and drawing.
struct MarkerLabel {
    let placement: MarkerLabelLayout.Candidate
    let text: GraphicsContext.ResolvedText
    let background: Color
    let opacity: Double

    func draw(in context: GraphicsContext) {
        var context = context
        context.opacity = opacity
        let frame = placement.frame
        context.fill(Path(roundedRect: frame, cornerRadius: frame.height / 2), with: .color(background))
        context.draw(text, at: CGPoint(x: frame.midX, y: frame.midY))
    }

    static func draw(_ labels: [MarkerLabel], in context: GraphicsContext) {
        let visible = MarkerLabelLayout.visibleIndices(labels.map(\.placement))
        for index in visible {
            labels[index].draw(in: context)
        }
        NamingComparisonTrace.recorder?.didDraw(labels, indices: visible)
    }
}
