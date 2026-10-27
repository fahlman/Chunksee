import Foundation

/// Match the Mac's interface language to the files the selected game actually supplies.
nonisolated enum GameLanguageChoice {
    static var preferredLanguage: String { Locale.preferredLanguages.first ?? "en" }

    static func code(for preference: String, available: [String]) -> String {
        let normalized = preference.replacingOccurrences(of: "-", with: "_").lowercased()
        if available.contains(normalized) { return normalized }

        let locale = Locale(identifier: preference)
        guard let language = locale.language.languageCode?.identifier else { return "en_us" }
        if let region = locale.region?.identifier {
            let exact = "\(language)_\(region.lowercased())"
            if available.contains(exact) { return exact }
        }

        // Let Apple match region/script preferences within the same language. Sorting also
        // makes its no-preference fallback independent of archive or index entry order.
        let candidates = available.filter {
            Locale(identifier: $0).language.languageCode?.identifier == language
        }.sorted()
        guard let fallback = candidates.first else { return "en_us" }
        return Bundle.preferredLocalizations(from: candidates, forPreferences: [preference])
            .first(where: candidates.contains) ?? fallback
    }
}
