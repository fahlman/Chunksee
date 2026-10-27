import ChunkseeKit
import Foundation
import SwiftUI

/// One immutable language snapshot. Kit supplies the requested language and English fallback;
/// this presentation layer supplies a readable ID only when neither contains the key.
nonisolated struct GameNames: Sendable {
    let identity: UUID?
    private let language: GameLanguage?

    init(_ language: GameLanguage? = nil) {
        self.language = language
        identity = language == nil ? nil : UUID()
    }

    func name(key: String, fallback: String) -> String { language?[key] ?? fallback }

    func name(_ id: String, in registry: String) -> String {
        translation(id, in: registry) ?? ReadableName.from(id)
    }

    func translation(_ id: String, in registry: String) -> String? {
        guard let id = Identifier(id) else { return nil }
        return language?["\(registry).\(id.namespace).\(id.path.replacingOccurrences(of: "/", with: "."))"]
    }

    func item(_ id: String) -> String {
        translation(id, in: "item") ?? translation(id, in: "block") ?? ReadableName.from(id)
    }

    func advancement(_ id: String) -> String {
        // Vanilla's titles use this language-key convention. An unrelated namespace must not
        // borrow a vanilla title just because its saved path happens to match.
        if let path = ReadableName.vanillaPath(id),
           let title = language?["advancements.\(path.replacingOccurrences(of: "/", with: ".")).title"] {
            return title
        }
        return ReadableName.from(id)
    }

    func gameMode(_ mode: GameMode?) -> String {
        guard let mode else { return String(localized: "Unknown") }
        let id: String
        switch mode {
        case .survival: id = "survival"
        case .creative: id = "creative"
        case .adventure: id = "adventure"
        case .spectator: id = "spectator"
        }
        return name(key: "gameMode.\(id)", fallback: ReadableName.from(id))
    }
}

extension EnvironmentValues {
    @Entry var gameNames = GameNames()
}
