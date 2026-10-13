import AppKit
import ChunkseeKit
import Foundation
import Observation

/// The worlds in the Minecraft folder chosen in Settings, most recently played first, for
/// File ▸ Open World. The list is read again when the folder changes and when Chunksee becomes
/// active, since Minecraft may have created or played a world in the meantime.
@Observable
final class SavedWorlds {
    struct Entry: Identifiable, Equatable, Sendable {
        let url: URL
        let name: String
        let lastPlayed: Date?
        /// The game folder holding the world's `saves` folder, relative to the Minecraft folder,
        /// such as `vanilla/release`; empty for the Minecraft folder's own `saves`.
        let installation: String
        /// The world's folder relative to the Minecraft folder, such as `vanilla/release/saves/Survival 2`;
        /// unique, unlike the world's name.
        let path: String
        var id: URL { url }
    }

    private(set) var all: [Entry] = []
    let names: PlayerNames
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var watchTasks: [Task<Void, Never>] = []

    var hasMinecraftFolder: Bool { names.minecraftFolder != nil }

    init(names: PlayerNames) {
        self.names = names
        watchTasks.append(Task { [weak self, names] in
            for await _ in Observations({ names.minecraftFolder }) { self?.reload() }
        })
        watchTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.reload()
            }
        })
    }

    isolated deinit {
        readTask?.cancel()
        watchTasks.forEach { $0.cancel() }
    }

    func reload() {
        readTask?.cancel()
        guard let folder = names.minecraftFolder else { all = []; return }
        readTask = Task { [weak self] in
            let found = await Self.read(folder)
            guard !Task.isCancelled, let self, self.names.minecraftFolder == folder else { return }
            if found != self.all { self.all = found }
        }
    }

    func waitForReload() async { await readTask?.value }

    /// A world's menu title: its name; its installation when another world has the same name; and
    /// its folder when that world is in the same installation, since names needn't be unique.
    func title(for entry: Entry) -> String {
        let sameName = all.filter { $0.name == entry.name && $0.url != entry.url }
        guard !sameName.isEmpty else { return entry.name }
        if sameName.contains(where: { $0.installation == entry.installation }) { return "\(entry.name) (\(entry.path))" }
        let installation = entry.installation.isEmpty ? String(localized: "Minecraft folder") : entry.installation
        return "\(entry.name) (\(installation))"
    }

    @concurrent private nonisolated static func read(_ folder: URL) async -> [Entry] {
        let root = folder.standardizedFileURL.path + "/"
        return World.saved(under: folder).compactMap { url -> Entry? in
            guard !Task.isCancelled, let world = try? World(contentsOf: url) else { return nil }
            var installation = url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path + "/"
            installation = installation.hasPrefix(root) ? String(installation.dropFirst(root.count).dropLast()) : ""
            let full = url.standardizedFileURL.path
            // A saves folder chosen directly isn't under a game folder; its worlds go by folder name.
            let path = full.hasPrefix(root) ? String(full.dropFirst(root.count)) : url.lastPathComponent
            return Entry(url: url, name: world.level.name ?? url.lastPathComponent, lastPlayed: world.level.lastPlayed,
                         installation: installation, path: path)
        }
        .sorted { ($0.lastPlayed ?? .distantPast, $1.name) > ($1.lastPlayed ?? .distantPast, $0.name) }
    }
}
