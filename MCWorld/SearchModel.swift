import Foundation
import MCWorldKit
import Observation

/// The toolbar search: an index of every container, sign and named creature, built in the
/// background when the world opens, and the places matching the current text.
@Observable
final class SearchModel {
    var text = "" {
        didSet { if text != oldValue { update() } }
    }
    private(set) var results: [SearchHit] = []
    /// True until the first index is built; rebuilding after the game saved keeps the old results.
    private(set) var isIndexing = false
    /// The result the map is centered on, highlighted among the result markers.
    var selectedHitID: SearchHit.ID?
    /// Players whose inventories and ender chests are searched too; updated when the game saves them.
    var players: [PlayerInfo] {
        didSet { update() }
    }

    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var index: SearchIndex?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    private let readers: [RegionReader]
    private let names: PlayerNames
    private let singleplayerUUID: UUID?

    init(readers: [RegionReader], players: [PlayerInfo], names: PlayerNames, singleplayerUUID: UUID?) {
        self.readers = readers
        self.players = players
        self.names = names
        self.singleplayerUUID = singleplayerUUID
        rebuild()
    }

    /// Reads every region's searchable contents in the background, at utility priority so drawing
    /// the map comes first. Called when the world opens and again after the game saves.
    func rebuild() {
        indexTask?.cancel()
        isIndexing = index == nil
        let readers = readers
        indexTask = Task(priority: .utility) { [weak self] in
            let index = await WorldSearch.index(readers)
            guard let self, !Task.isCancelled else { return }
            self.index = index
            self.isIndexing = false
            self.update()
        }
    }

    /// Waits for the index being built, if any.
    func waitForIndex() async {
        await indexTask?.value
    }

    func cancel() {
        indexTask?.cancel()
    }

    private func update() {
        selectedHitID = nil
        guard isActive, let index else {
            results = []
            return
        }
        let names = names, singleplayerUUID = singleplayerUUID
        results = WorldSearch.search(text, in: index, players: players) {
            PlayerPresentation.name(of: $0, singleplayerUUID: singleplayerUUID, knownName: names.name(for: $0.uuid))
        }
    }
}
