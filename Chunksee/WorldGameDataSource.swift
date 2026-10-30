import ChunkseeKit
import Foundation

/// Every consumer uses the same equality for the world's selected game data. Loading and a
/// completed read with no library differ, even within one selected Minecraft folder.
nonisolated struct WorldGameDataSource: Equatable, Sendable {
    enum Selection: Equatable, Sendable {
        case loading
        case loaded(GameDataLibrary?)

        var isLoaded: Bool {
            if case .loaded = self { true } else { false }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): true
            case (.loaded(let first), .loaded(let second)): first === second
            default: false
            }
        }
    }

    /// Completed facts retain compact provenance without keeping a retired asset library alive.
    struct Identity: Equatable, Sendable {
        let generation: UUID
        let libraryID: UUID?
        fileprivate init(generation: UUID, libraryID: UUID?) {
            self.generation = generation
            self.libraryID = libraryID
        }
    }

    let generation: UUID
    let selection: Selection

    var identity: Identity {
        let libraryID: UUID?
        if case .loaded(let library) = selection { libraryID = library?.identity }
        else { libraryID = nil }
        return Identity(generation: generation, libraryID: libraryID)
    }
}
