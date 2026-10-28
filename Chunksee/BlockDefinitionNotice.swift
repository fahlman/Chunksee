import Foundation

/// Wording approved for the selected game files in #459, independently of artwork availability.
nonisolated struct BlockDefinitionNotice: Equatable, Sendable {
    let gameName: String?

    init(gameName: String?) {
        let name = gameName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gameName = name?.isEmpty == false ? name : nil
    }

    func label(locale: Locale = .current) -> String {
        if let gameName {
            return String(localized: "Minecraft \(gameName) doesn't recognize this block", locale: locale,
                          comment: "Block notice. The placeholder is the selected game files' version name; do not translate it.")
        }
        return String(localized: "Minecraft doesn't recognize this block", locale: locale,
                      comment: "Block notice when the selected game files have no readable version name.")
    }

    func help(locale: Locale = .current) -> String {
        if let gameName {
            return String(localized: "Minecraft \(gameName) would remove it when this area loads.", locale: locale,
                          comment: "Help for the block notice. The placeholder is the selected game's version name; do not translate it.")
        }
        return String(localized: "Minecraft would remove it when this area loads.", locale: locale,
                      comment: "Help for the block notice when the selected game files have no readable version name.")
    }

    func accessibilityLabel(locale: Locale = .current) -> String {
        if let gameName {
            return String(localized: "Minecraft \(gameName) doesn't recognize this block. It would remove it when this area loads.", locale: locale,
                          comment: "Spoken block notice. The placeholder is the selected game files' version name; do not translate it.")
        }
        return String(localized: "Minecraft doesn't recognize this block. It would remove it when this area loads.", locale: locale,
                      comment: "Spoken block notice when the selected game files have no readable version name.")
    }
}
