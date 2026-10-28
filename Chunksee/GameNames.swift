import ChunkseeKit
import Foundation
import SwiftUI

/// One immutable language snapshot. Kit supplies the requested language and English fallback;
/// this presentation layer supplies a readable ID only when neither contains the key.
nonisolated struct GameNames: Sendable {
    let identity: UUID?
    private let language: GameLanguage?

    /// The deliberate state before a language is readable or after its source is retired.
    /// Callers must supply this state explicitly rather than silently defaulting to it.
    static let unavailable = GameNames(nil)

    init(_ language: GameLanguage?) {
        self.language = language
        identity = language == nil ? nil : UUID()
    }

    func name(key: String, fallback: String) -> String { language?[key] ?? fallback }

    func hasSameContents(as language: GameLanguage?) -> Bool { self.language == language }

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

    func advancement(_ id: String, title: TextComponent.Content? = nil) -> String {
        if let title, let text = GameText.string(title, translation: { language?[$0] }) { return text }
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
    @Entry var gameNames = GameNames.unavailable
}
