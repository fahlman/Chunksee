import SwiftUI

/// Evidence only: retain values from the actual formatter and drawing pass, never a model or context.
/// Both comparison endpoints carry this identical hook; the probe must clear the recorder after capture.
@MainActor
enum NamingComparisonTrace {
    nonisolated struct Formatted: Codable, Sendable {
        let id: String
        let text: String
    }

    nonisolated struct Placement: Codable, Sendable {
        let id: String
        let priority: Int
        let frame: [Double]

        init(_ value: MarkerLabelLayout.Candidate) {
            id = value.id
            priority = value.priority.rawValue
            frame = [Double(value.frame.minX), Double(value.frame.minY),
                     Double(value.frame.width), Double(value.frame.height)]
        }
    }

    nonisolated struct Pass: Codable, Sendable {
        let formatted: [Formatted]
        let candidates: [Placement]
        let drawnIDs: [String]
    }

    final class Recorder {
        private var pending: [Formatted] = []
        private(set) var passes: [Pass] = []
        var hasUnfinishedPass: Bool { !pending.isEmpty }

        func didFormat(id: String, text: String) {
            pending.append(Formatted(id: id, text: text))
        }

        func didDraw(_ labels: [MarkerLabel], indices: [Int]) {
            passes.append(Pass(formatted: pending, candidates: labels.map { Placement($0.placement) },
                               drawnIDs: indices.map { labels[$0].placement.id }))
            pending.removeAll(keepingCapacity: true)
        }
    }

    static var recorder: Recorder?
}
