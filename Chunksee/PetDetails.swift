import ChunkseeKit
import SwiftUI

struct CreatureHealthRows: View {
    let creature: Creature

    var body: some View {
        if let health = creature.health, health.isFinite, health >= 0 {
            LabeledContent("Health") {
                if let maximum = creature.maxHealth, maximum.isFinite, maximum > 0 {
                    Text("\(health / 2, format: .number.precision(.fractionLength(0...2))) of \(maximum / 2, format: .number.precision(.fractionLength(0...2))) hearts")
                        .monospacedDigit()
                } else {
                    Text("\(health / 2, format: .number.precision(.fractionLength(0...2))) hearts")
                        .monospacedDigit()
                }
            }
            .help("Health recorded when Minecraft last saved this creature")
        } else if let maximum = creature.maxHealth, maximum.isFinite, maximum > 0 {
            LabeledContent("Maximum Health") {
                Text("\(maximum / 2, format: .number.precision(.fractionLength(0...2))) hearts")
                    .monospacedDigit()
            }
        }
    }
}

struct PetDetailRows: View {
    let creature: Creature

    var body: some View {
        if let sitting = creature.sittingOrder {
            LabeledContent("Sitting Order", value: sitting ? String(localized: "Sit") : String(localized: "Not ordered to sit"))
        }
        if let appearance = creature.appearance {
            LabeledContent("Appearance", value: PetDetailText.appearance(appearance, species: creature.id))
        }
        if let color = creature.collarColor {
            LabeledContent("Collar Color", value: PetDetailText.name(color))
        }
        if let equipment = creature.equipment, equipment.isEmpty {
            LabeledContent("Equipment", value: String(localized: "None"))
        }
    }
}

nonisolated enum PetDetailText {
    static func appearance(_ appearance: CreatureAppearance, species: String) -> String {
        let variant: String
        switch (species, appearance.variant) {
        case ("minecraft:cat", "minecraft:black"): variant = String(localized: "Tuxedo")
        case ("minecraft:cat", "minecraft:red"): variant = String(localized: "Ginger")
        case ("minecraft:cat", "minecraft:all_black"): variant = String(localized: "Black")
        default: variant = name(appearance.variant)
        }
        guard let markings = appearance.markings else { return variant }
        return "\(variant), \(name(markings))"
    }

    static func slot(_ slot: String) -> String {
        switch slot {
        case "body": String(localized: "Body")
        case "saddle": String(localized: "Saddle")
        case "storage": String(localized: "Storage")
        case "head": String(localized: "Head")
        case "chest": String(localized: "Chest")
        case "legs": String(localized: "Legs")
        case "feet": String(localized: "Feet")
        case "mainhand": String(localized: "Main Hand")
        case "offhand": String(localized: "Off Hand")
        default: ReadableName.from(slot)
        }
    }

    static func name(_ id: String) -> String {
        let key = id.replacingOccurrences(of: "minecraft:", with: "")
        return names[key] ?? ReadableName.from(id)
    }

    private static let names: [String: String] = [
        "white": String(localized: "White"), "orange": String(localized: "Orange"),
        "magenta": String(localized: "Magenta"), "light_blue": String(localized: "Light Blue"),
        "yellow": String(localized: "Yellow"), "lime": String(localized: "Lime"),
        "pink": String(localized: "Pink"), "gray": String(localized: "Gray"),
        "light_gray": String(localized: "Light Gray"), "cyan": String(localized: "Cyan"),
        "purple": String(localized: "Purple"), "blue": String(localized: "Blue"),
        "brown": String(localized: "Brown"), "green": String(localized: "Green"),
        "red": String(localized: "Red"), "black": String(localized: "Black"),
        "pale": String(localized: "Pale"), "woods": String(localized: "Woods"),
        "ashen": String(localized: "Ashen"), "chestnut": String(localized: "Chestnut"),
        "rusty": String(localized: "Rusty"), "spotted": String(localized: "Spotted"),
        "striped": String(localized: "Striped"), "snowy": String(localized: "Snowy"),
        "tabby": String(localized: "Tabby"), "siamese": String(localized: "Siamese"),
        "british_shorthair": String(localized: "British Shorthair"), "calico": String(localized: "Calico"),
        "persian": String(localized: "Persian"), "ragdoll": String(localized: "Ragdoll"),
        "jellie": String(localized: "Jellie"), "red_blue": String(localized: "Red and Blue"),
        "yellow_blue": String(localized: "Yellow and Blue"), "creamy": String(localized: "Creamy"),
        "dark_brown": String(localized: "Dark Brown"), "white_field": String(localized: "White Patches"),
        "white_dots": String(localized: "White Spots"), "black_dots": String(localized: "Black Spots"),
    ]
}
