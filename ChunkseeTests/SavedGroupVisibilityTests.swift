import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SavedGroupVisibilityTests {
    /// Model an app update without adding a fake group to the production sidebar.
    nonisolated private enum EvolvingGroup: String, CaseIterable, PersistedLayerGroup {
        case oldShown, oldHidden, newShown, newHidden
        var isShownByDefault: Bool { self == .oldShown || self == .newShown }
        static let legacyVisibilityGroups: Set<Self> = [.oldShown, .oldHidden]
    }

    @Test func newGroupsUseTheirDefaultsWithoutOverridingOldChoices() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self,
            from: Data(#"["oldHidden","unfamiliar"]"#.utf8))
        let explicit = try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self,
            from: Data(#"{"oldShown":false,"oldHidden":true,"unfamiliar":true}"#.utf8))
        #expect(legacy.shown == [.oldHidden, .newShown])
        #expect(explicit.shown == legacy.shown)
        let emptyLegacy = try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self, from: Data("[]".utf8))
        let emptyRecord = try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self, from: Data("{}".utf8))
        #expect(emptyLegacy.shown == [.newShown])
        #expect(emptyRecord.shown == [.oldShown, .newShown])

        // Once the user hides the new default-shown group, reopening must honor that choice.
        let saved = try JSONEncoder().encode(SavedGroupVisibility<EvolvingGroup>(shown: [.oldHidden]))
        #expect(try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self, from: saved).shown == [.oldHidden])
    }
}
