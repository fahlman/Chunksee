#if CHUNKSEE_TEST_HOST
import ChunkseeKit
import Foundation

/// Evidence-only counters for one isolated parity map. Never part of a product PR.
@MainActor enum PlayerObservationComparisonMetrics {
    nonisolated struct Snapshot: Codable, Sendable {
        var assetReads = 0
        var tileStarted = 0
        var tileFinished = 0
        var tilePublished = 0
        var tileRetired = 0
        var readoutStarted = 0
        var readoutFinished = 0
        var readoutPublished = 0
        var firstAcceptedTileSeen = false
    }

    private(set) static var snapshot = Snapshot()
    private static var firstRegion: RegionPosition?

    static func begin(firstRegion: RegionPosition) {
        snapshot = Snapshot()
        self.firstRegion = firstRegion
    }

    private static var holdsAssets = false
    private static var heldAssets: [CheckedContinuation<Void, Never>] = []
    private static var assetWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    static func holdAssetReads() { holdsAssets = true }
    static func releaseAssetReads() {
        holdsAssets = false
        let pending = heldAssets
        heldAssets = []
        pending.forEach { $0.resume() }
    }
    static func completedAssetRead() async {
        snapshot.assetReads += 1
        if holdsAssets {
            await withCheckedContinuation { continuation in
                heldAssets.append(continuation)
                notifyAssetWaiters()
            }
        } else { notifyAssetWaiters() }
    }
    private static func notifyAssetWaiters() {
        let ready = assetWaiters.filter { $0.0 <= snapshot.assetReads }
        assetWaiters.removeAll { $0.0 <= snapshot.assetReads }
        ready.forEach { $0.1.resume() }
    }
    static func waitForAssetRead(_ count: Int) async {
        guard snapshot.assetReads < count else { return }
        await withCheckedContinuation { assetWaiters.append((count, $0)) }
    }

    static func tileStarted() { snapshot.tileStarted += 1 }
    static func tileFinished() { snapshot.tileFinished += 1 }
    static func tileRetired() { snapshot.tileRetired += 1 }
    static func tilePublished(in region: RegionPosition) {
        snapshot.tilePublished += 1
        if region == firstRegion, !snapshot.firstAcceptedTileSeen {
            snapshot.firstAcceptedTileSeen = true
        }
    }
    static func readoutStarted() { snapshot.readoutStarted += 1 }
    static func readoutFinished() { snapshot.readoutFinished += 1 }
    static func readoutPublished() { snapshot.readoutPublished += 1 }
}
#endif
