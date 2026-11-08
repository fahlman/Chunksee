#if CHUNKSEE_TEST_HOST
import ChunkseeKit
import Foundation
import Synchronization
import Darwin

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

/// Diagnostic-only instrumentation. The lock owns all trace state; task-local IDs follow
/// render child tasks without changing cancellation, priorities, or publication decisions.
/// Process CPU stamps include overlapping work and are not per-job CPU measurements.
nonisolated enum RechooseDiagnosticTrace {
    @TaskLocal static var renderJob: Int?

    nonisolated struct Event: Codable, Sendable {
        let sequence: Int
        let uptimeNS: UInt64
        let processCPUSeconds: Double
        let phase: String
        let name: String
        let job: Int?
        let span: Int?
        let cancelled: Bool
        let detail: String
    }
    nonisolated struct Report: Codable, Sendable {
        let diagnosticOnly: Bool
        let row: String
        let events: [Event]
        let counts: [String: Int]
        let overflow: Bool
    }
    private nonisolated struct State: Sendable {
        var row = "unstarted"
        var phase = "opening"
        var events: [Event] = []
        var counts: [String: Int] = [:]
        var overflow = false
    }
    private static let state = Mutex(State())

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func beginRow(_ row: String) {
        state.withLock { $0 = State(row: row) }
        mark("row.begin")
    }
    static func phase(_ name: String) {
        state.withLock { $0.phase = name }
        mark("phase")
    }
    @discardableResult
    private static func record(_ name: String, job: Int?, span: Int?, detail: String,
                               beginsSpan: Bool = false) -> Int {
        state.withLock { value in
            guard value.events.count < 50_000 else { value.overflow = true; return -1 }
            let sequence = value.events.count
            value.events.append(Event(sequence: sequence, uptimeNS: DispatchTime.now().uptimeNanoseconds,
                processCPUSeconds: cpuSeconds(), phase: value.phase, name: name,
                job: job ?? renderJob, span: beginsSpan ? sequence : span,
                cancelled: Task.isCancelled, detail: detail))
            return sequence
        }
    }
    static func mark(_ name: String, job: Int? = nil, detail: String = "") {
        record(name, job: job, span: nil, detail: detail)
    }
    static func start(_ name: String, detail: String = "") -> Int {
        record(name + ".begin", job: nil, span: nil, detail: detail, beginsSpan: true)
    }
    static func end(_ name: String, _ span: Int, detail: String = "") {
        record(name + ".end", job: nil, span: span, detail: detail)
    }
    static func count(_ name: String) {
        let key = (renderJob.map(String.init) ?? "unowned") + ":" + name
        state.withLock {
            $0.counts[key, default: 0] += 1
            if Task.isCancelled { $0.counts[key + ":cancelled", default: 0] += 1 }
        }
    }
    static var report: Report {
        state.withLock { Report(diagnosticOnly: true, row: $0.row, events: $0.events,
                                counts: $0.counts, overflow: $0.overflow) }
    }
}

#endif
