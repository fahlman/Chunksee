import ChunkseeIndex
import Foundation

/// Presentation groups own the default used when a saved choice is missing.
nonisolated protocol PersistedLayerGroup: RawRepresentable, CaseIterable, Hashable where RawValue == String {
    var isShownByDefault: Bool { get }
}

/// The storage boundary for group choices. Live map consumers continue to use the shown set.
nonisolated struct SavedGroupVisibility<Group: PersistedLayerGroup>: Codable {
    let shown: Set<Group>

    init(shown: Set<Group>) { self.shown = shown }

    init(choices: [String: Bool]) {
        shown = Set(Group.allCases.filter { choices[$0.rawValue] ?? $0.isShownByDefault })
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        self.init(choices: try value.decode([String: Bool].self))
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(Dictionary(uniqueKeysWithValues: Group.allCases.map { ($0.rawValue, shown.contains($0)) }))
    }
}

extension StructureGroup: PersistedLayerGroup {}
extension PlaceGroup: PersistedLayerGroup {}
extension CreatureGroup: PersistedLayerGroup {}
