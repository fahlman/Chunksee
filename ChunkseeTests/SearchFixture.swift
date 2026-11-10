import ChunkseeKit
import Foundation
@testable import ChunkseeTestHost

/// Standalone query tests assemble the same world-owned index/results as WorldResources.
/// Multi-window tests construct one WorldQueryStore explicitly and attach several models.
func makeSearch(readers: [RegionReader], work: BackgroundWork, playerRoster: any PlayerSnapshotSource,
                names: PlayerNames, singleplayerUUID: @escaping @MainActor () -> UUID?,
                firstDimension: String?, savedSearches: SavedSearches,
                execute: @escaping WorldQueryStore.Read = WorldSearch.execute,
                gameNames: @escaping @MainActor () -> GameNames) -> SearchModel {
    let index = WorldIndexStore(readers: readers, work: work, firstDimension: firstDimension, playerRoster: playerRoster)
    return SearchModel(queryStore: WorldQueryStore(index: index, work: work, names: names,
        savedSearches: savedSearches, singleplayerUUID: singleplayerUUID, gameNames: gameNames, execute: execute))
}

extension SearchModel {
    func closeTestWorld() async {
        cancel()
        queryStore.close()
        indexStore.cancel()
        await waitForTasks()
        await queryStore.waitForTasks()
        await indexStore.waitForTasks()
    }
}
