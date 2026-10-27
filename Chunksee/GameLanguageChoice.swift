import ChunkseeKit
import Foundation

/// Match the Mac's interface language to the files the selected game actually supplies.
nonisolated enum GameLanguageChoice {
    static var preferredLanguage: String { Locale.preferredLanguages.first ?? "en" }

    static func language(for preference: String, available: [String],
                         read: (String) -> GameLanguage?) -> GameLanguage? {
        let preference = Locale.canonicalLanguageIdentifier(from: preference)
        let requested = Locale.Language(identifier: preference)
        let codes = available.sorted()
        let preferred = Bundle.preferredLocalizations(from: codes, forPreferences: [preference]).first
        var readNames: [String: GameLanguage] = [:]
        func readOnce(_ code: String) -> GameLanguage? {
            if let names = readNames[code] { return names }
            guard let names = read(code) else { return nil }
            readNames[code] = names
            return names
        }
        func matches(_ language: Locale.Language) -> Bool {
            language.languageCode == requested.languageCode && language.script == requested.script
        }
        // Verify Apple's regional choice first, avoiding a read of every same-language file.
        // Keep these reads only for this request; the caller still owns source retirement.
        if let preferred {
            guard let names = readOnce(preferred) else { return nil }
            if let declaration = names.declaredLanguageCode,
               matches(Locale.Language(identifier: declaration)) { return names }
        }
        // Filenames shortlist reads, including aliases such as no_no for nb-NO.
        var possible = Set(codes.filter {
            Locale.Language(identifier: $0).languageCode == requested.languageCode
        })
        if let preferred { possible.insert(preferred) }
        let ordered = possible.sorted { lhs, rhs in
            let left = Locale.Language(identifier: lhs).isEquivalent(to: requested)
            let right = Locale.Language(identifier: rhs).isEquivalent(to: requested)
            return left == right ? lhs < rhs : left
        }

        var candidates: [(locale: String, names: GameLanguage)] = []
        for code in ordered {
            guard let names = readOnce(code) else { return nil }
            guard let declaration = names.declaredLanguageCode else { continue }
            let language = Locale.Language(identifier: declaration)
            guard matches(language) else { continue }
            if language.isEquivalent(to: requested) { return names }
            candidates.append((Locale.canonicalLanguageIdentifier(from: declaration), names))
        }
        // Match regions only among verified identities. A filename such as en_pt may
        // actually declare Pirate Speak, and sr_cs declares Latin rather than Cyrillic.
        // Inferred script subtags prevent Bundle's regional fallback (for example es-US
        // to es-MX). Canonical identifiers retain the declared region without adding them.
        if let selected = Bundle.preferredLocalizations(from: candidates.map(\.locale),
                                                        forPreferences: [preference]).first,
           let match = candidates.first(where: { $0.locale == selected }) {
            return match.names
        }
        if let candidate = candidates.first { return candidate.names }
        // Some game declarations use individual-language codes Foundation cannot relate
        // to the Mac's language. After verified choices, retain Apple's same-language file
        // only for an unknown declaration in the requested script. Known other languages
        // and BCP 47's private-use qaa–qtz codes cannot qualify through their filename.
        if let preferred, Locale.Language(identifier: preferred).languageCode == requested.languageCode,
           let names = readNames[preferred], let declaration = names.declaredLanguageCode {
            let language = Locale.Language(identifier: declaration)
            if language.script == requested.script, let code = language.languageCode,
               !code.isISOLanguage, !("qaa"..."qtz").contains(code.identifier) { return names }
        }
        return readOnce("en_us")
    }
}
