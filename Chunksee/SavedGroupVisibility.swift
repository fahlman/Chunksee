import ChunkseeIndex
import Foundation

/// Presentation groups have defaults; the historical shown-only schema must never grow.
nonisolated protocol PersistedLayerGroup: RawRepresentable, CaseIterable, Hashable where RawValue == String {
    var isShownByDefault: Bool { get }
    static var legacyVisibilityGroups: Set<Self> { get }
}

/// The storage boundary for group choices. Live map consumers continue to use the shown set.
nonisolated struct SavedGroupVisibility<Group: PersistedLayerGroup>: Codable {
    let shown: Set<Group>

    init(shown: Set<Group>) { self.shown = shown }

    init(choices: [String: Bool]) {
        shown = Set(Group.allCases.filter { choices[$0.rawValue] ?? $0.isShownByDefault })
    }

    init(legacyShown names: [String]) {
        var choices = Dictionary(uniqueKeysWithValues: Group.legacyVisibilityGroups.map { ($0.rawValue, false) })
        for name in names { choices[name] = true }
        self.init(choices: choices)
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let choices = try? value.decode([String: Bool].self) {
            self.init(choices: choices)
        } else {
            self.init(legacyShown: try value.decode([String].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(Dictionary(uniqueKeysWithValues: Group.allCases.map { ($0.rawValue, shown.contains($0)) }))
    }
}

// These lists describe old app preferences, not Minecraft content. A group added after the
// shown-only format was retired must stay out of them so its declared default can apply.
extension StructureGroup: PersistedLayerGroup {
    nonisolated static let legacyVisibilityGroups: Set<StructureGroup> = [
        .village, .stronghold, .ancientCity, .trialChambers, .monument, .mansion, .temple, .ruins,
        .ruinedPortal, .shipwreck, .buriedTreasure, .outpost, .mineshaft, .fortress, .bastion,
        .netherFossil, .endCity, .other
    ]
}

extension PlaceGroup: PersistedLayerGroup {
    nonisolated static let legacyVisibilityGroups: Set<PlaceGroup> = [
        .portal, .bell, .lodestone, .bed, .workstation, .beeNest, .lightningRod, .spawner, .unopenedLoot, .other
    ]
}

extension CreatureGroup: PersistedLayerGroup {
    nonisolated static let legacyVisibilityGroups: Set<CreatureGroup> = [.named, .pet, .villager, .mob]
}
