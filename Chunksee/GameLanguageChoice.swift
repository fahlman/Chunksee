import ChunkseeKit
import Foundation

/// Match the Mac's interface language to the files the selected game actually supplies.
nonisolated enum GameLanguageChoice {
    static var preferredLanguage: String { Locale.preferredLanguages.first ?? "en" }

    static func language(for preference: String, available: [String],
                         read: (String) -> GameLanguage?) -> GameLanguage? {
        let requested = Locale.Language(identifier: preference)
        let codes = available.sorted()
        // Filenames only shortlist reads. Apple's match also finds aliases such as no_no
        // for nb-NO; the file's own declaration must still establish the language and script.
        var possible = Set(codes.filter {
            Locale.Language(identifier: $0).languageCode == requested.languageCode
        })
        possible.formUnion(Bundle.preferredLocalizations(from: codes, forPreferences: [preference]))
        let ordered = possible.sorted { lhs, rhs in
            let left = Locale.Language(identifier: lhs).isEquivalent(to: requested)
            let right = Locale.Language(identifier: rhs).isEquivalent(to: requested)
            return left == right ? lhs < rhs : left
        }

        var candidates: [(locale: String, names: GameLanguage)] = []
        for code in ordered {
            guard let names = read(code) else { return nil }
            guard let declaration = names.declaredLanguageCode else { continue }
            let language = Locale.Language(identifier: declaration)
            guard language.languageCode == requested.languageCode,
                  language.script == requested.script else { continue }
            if language.isEquivalent(to: requested) { return names }
            candidates.append((Locale.canonicalLanguageIdentifier(from: declaration), names))
        }
        // Match regions only among verified identities. A filename such as en_pt may
        // actually declare Pirate Speak, and sr_cs declares Latin rather than Cyrillic.
        // Inferred script subtags prevent Bundle's regional fallback (for example es-US
        // to es-MX). Canonical identifiers retain the declared region without adding them.
        if let selected = Bundle.preferredLocalizations(from: candidates.map(\.locale),
                                                        forPreferences: [Locale.canonicalLanguageIdentifier(from: preference)]).first,
           let match = candidates.first(where: { $0.locale == selected }) {
            return match.names
        }
        return candidates.first?.names ?? read("en_us")
    }
}
