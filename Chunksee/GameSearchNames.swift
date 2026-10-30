import Foundation

extension GameNames {
    nonisolated func searchTitle(_ hit: SearchHit, locale: Locale = .current) -> String {
        switch hit.content {
        case .container(let kind, let customName, _):
            itemLabel(kind: kind, customName: customName, locale: locale)
        case .sign(let kind, _): ReadableName.from(kind)
        case .structure(let marker): structure(marker.structureID)
        case .place(let marker): place(marker)
        case .creature(let marker), .trades(let marker, _): creature(marker.creature)
        case .biome(_, let group, _): biome(group.id)
        case .block(let deposit): notableBlock(deposit.block)
        case .inventory(_, let name, _):
            switch name {
            case .you: String(localized: "Your inventory", locale: locale)
            case .named(let name): String(localized: "\(name)’s inventory", locale: locale)
            }
        case .enderChest(_, let name, _):
            switch name {
            case .you: String(localized: "Your ender chest", locale: locale)
            case .named(let name): String(localized: "\(name)’s ender chest", locale: locale)
            }
        }
    }

    nonisolated func searchDetail(_ hit: SearchHit, locale: Locale = .current) -> String {
        switch hit.content {
        case .container(_, _, let items), .inventory(_, _, let items), .enderChest(_, _, let items):
            searchItems(items, locale: locale)
        case .sign(_, let lines):
            // Matching keeps saved spacing; display trims and omits blank lines.
            lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
        case .structure(let marker): group(marker.group)
        case .place(let marker): group(marker.group)
        case .creature(let marker): creatureCaption(marker)
        case .trades(_, let matching): matching.map { tradeOffer($0, locale: locale) }.joined(separator: "; ")
        case .biome(_, _, let chunks): biomeArea(chunkCount: chunks, locale: locale)
        case .block(let deposit):
            String(localized: "\(deposit.count) blocks · Y \(deposit.minY) to \(deposit.maxY)", locale: locale)
        }
    }

    nonisolated func searchItem(_ match: SearchHit.ItemMatch, locale: Locale = .current) -> String {
        ItemAppearance.counted(itemLabel(match.name, locale: locale), count: match.count, includingOne: true, locale: locale)
    }

    nonisolated func searchItems(_ matches: [SearchHit.ItemMatch], locale: Locale = .current) -> String {
        matches.map { searchItem($0, locale: locale) }.joined(separator: ", ")
    }
}
