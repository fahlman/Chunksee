import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SavedGroupVisibilityTests {
    /// Model an app update without adding a fake group to the production sidebar.
    nonisolated private enum EvolvingGroup: String, CaseIterable, PersistedLayerGroup {
        case oldShown, oldHidden, newShown, newHidden
        var isShownByDefault: Bool { self == .oldShown || self == .newShown }
    }

    @Test func newGroupsUseTheirDefaultsWithoutOverridingOldChoices() throws {
        let decoder = JSONDecoder()
        let explicit = try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self,
            from: Data(#"{"oldShown":false,"oldHidden":true,"unfamiliar":true}"#.utf8))
        #expect(explicit.shown == [.oldHidden, .newShown])
        let emptyRecord = try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self, from: Data("{}".utf8))
        #expect(emptyRecord.shown == [.oldShown, .newShown])
        for oldList in [#"["oldHidden","unfamiliar"]"#, "[]"] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self, from: Data(oldList.utf8))
            }
        }

        // Once the user hides the new default-shown group, reopening must honor that choice.
        let saved = try JSONEncoder().encode(SavedGroupVisibility<EvolvingGroup>(shown: [.oldHidden]))
        #expect(try decoder.decode(SavedGroupVisibility<EvolvingGroup>.self, from: saved).shown == [.oldHidden])
    }
}
