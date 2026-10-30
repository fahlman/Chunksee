import ChunkseeKit
import SwiftUI

struct PetDetailRows: View {
    let creature: Creature
    @Environment(\.gameNames) private var gameNames
    @Environment(\.locale) private var locale

    var body: some View {
        if let sitting = creature.sittingOrder {
            LabeledContent("Sitting Order", value: sitting ? String(localized: "Sit") : String(localized: "Not ordered to sit"))
        }
        if let appearance = creature.appearance {
            LabeledContent("Appearance", value: gameNames.creatureAppearance(appearance, locale: locale))
        }
        if let color = creature.collarColor {
            LabeledContent("Collar Color", value: gameNames.dyeColor(color))
        }
    }
}
