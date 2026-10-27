import ChunkseeKit
import Foundation
import SwiftUI

nonisolated struct SavedMinecraftVersion: Equatable, Sendable {
    let dataVersion: Int?
    let name: String?

    init(_ level: LevelInfo) {
        dataVersion = level.dataVersion
        name = level.versionName
    }
}

/// Compare the save with the selected files, without keeping a catalog of known releases.
nonisolated struct WorldVersionNotice: Equatable, Sendable {
    let id: String
    let worldName: String?
    let gameName: String

    init?(saved: SavedMinecraftVersion, game: GameAssets.Version) {
        guard let savedVersion = saved.dataVersion, savedVersion > Int(game.dataVersion) else { return nil }
        id = "\(savedVersion):\(game.dataVersion)"
        worldName = saved.name
        gameName = game.id
    }

    func message(locale: Locale = .current) -> String {
        if let worldName, !worldName.isEmpty {
            return String(localized: "This world was saved with Minecraft \(worldName), which is newer than the selected Minecraft \(gameName). Chunksee will show what it can read.", locale: locale,
                          comment: "Non-blocking notice. The first name comes from the save; the second comes from the selected game files. Do not translate version names.")
        }
        return String(localized: "This world was saved with a newer Minecraft version than the selected Minecraft \(gameName). Chunksee will show what it can read.", locale: locale,
                      comment: "Non-blocking notice when the save records a newer data version but no version name. The name comes from the selected game files.")
    }
}

struct WorldVersionNoticeText: View {
    let notice: WorldVersionNotice
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Newer Minecraft World", systemImage: "info.circle").fontWeight(.medium)
            Text(notice.message(locale: locale)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorldVersionBanner: View {
    let resources: WorldResources

    var body: some View {
        if let notice = resources.newerWorldBanner {
            HStack(alignment: .top) {
                WorldVersionNoticeText(notice: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss Notice", systemImage: "xmark") { resources.dismissNewerWorldNotice(notice) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("The version notice remains in World Info")
            }
            .padding()
            .background(.bar)
            .id(notice.id)
            .onAppear { resources.presentNewerWorldNotice(notice) }
        }
    }
}
