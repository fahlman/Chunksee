import ChunkseeKit
import SwiftUI

struct PetDetailRows: View {
    let creature: Creature

    var body: some View {
        if let sitting = creature.sittingOrder {
            LabeledContent("Sitting Order", value: sitting ? String(localized: "Sit") : String(localized: "Not ordered to sit"))
        }
        if let appearance = creature.appearance {
            LabeledContent("Appearance", value: PetDetailText.appearance(appearance))
        }
        if let color = creature.collarColor {
            LabeledContent("Collar Color", value: PetDetailText.name(color))
        }
    }
}

nonisolated enum PetDetailText {
    static func appearance(_ appearance: CreatureAppearance) -> String {
        var parts: [String] = []
        if let variant = appearance.variant { parts.append(name(variant)) }
        if let markings = appearance.markings { parts.append(name(markings)) }
        for (key, value) in (appearance.traits ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append(String(localized: "\(ReadableName.from(key)): \(name(value))"))
        }
        return parts.isEmpty ? String(localized: "Not recorded") : parts.formatted(.list(type: .and))
    }

    static func name(_ id: String) -> String { ReadableName.from(id) }
}
