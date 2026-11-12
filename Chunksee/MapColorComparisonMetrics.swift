#if CHUNKSEE_TEST_HOST
import ChunkseeKit
import Foundation
import Synchronization
import Darwin

/// Evidence only. These stamps measure accepted drawable tiles, not physical screen frames.
nonisolated struct MapColorComparisonStamp {
    let wall = DispatchTime.now().uptimeNanoseconds
    let cpu = Self.cpuSeconds()
    static func cpuSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    var values: [String: Double] {
        ["wallSeconds": Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e9,
         "cpuSeconds": Self.cpuSeconds() - cpu]
    }
}

@MainActor enum MapColorComparisonMetrics {
    nonisolated struct Snapshot: Codable, Sendable {
        var tileStarted = 0
        var tileFinished = 0
        var tilePublished = 0
        var firstAcceptedTile: [String: Double]?
        var firstAcceptedTileSeen: Bool { firstAcceptedTile != nil }
    }
    private(set) static var snapshot = Snapshot()
    private static var firstRegion: RegionPosition?
    private static var phaseStart: MapColorComparisonStamp?
    private struct Publication {
        let key: RegionTileRenderer.ImageKey
        let stamp: [String: Double]
    }
    private static var publications: [Publication] = []
    private static var publicationOverflow = false

    nonisolated struct KeyRecord: Encodable, Sendable {
        let surface: TileCache.Key
        let heightScale: MapHeightScale?
        let usesSavedLighting: Bool
        let chunkX: Int?
        let chunkZ: Int?

        init(_ key: RegionTileRenderer.ImageKey) {
            surface = key.surface
            heightScale = key.preparation.heightScale
            usesSavedLighting = key.preparation.usesSavedLighting
            chunkX = key.chunk?.x
            chunkZ = key.chunk?.z
        }
    }

    nonisolated struct SettledPublications: Encodable, Sendable {
        let firstTile: [String: Double]
        let firstFinalTile: [String: Double]
        let firstMatchesFinal: Bool
        let firstKey: KeyRecord
        let settledKey: KeyRecord
        let publicationKeys: [KeyRecord]
        let publicationStamps: [[String: Double]]
    }

    static var tracing: Bool {
#if CHUNKSEE_COLOR_TRACE
        true
#else
        false
#endif
    }

    static func beginRow(_ name: String) {
        snapshot = Snapshot()
        firstRegion = nil
        phaseStart = nil
        publications = []
        publicationOverflow = false
#if CHUNKSEE_COLOR_TRACE
        RechooseDiagnosticTrace.beginRow(name)
#endif
    }

    static func phase(_ name: String, region: RegionPosition? = nil, since start: MapColorComparisonStamp? = nil) {
        firstRegion = region
        phaseStart = start
        snapshot.firstAcceptedTile = nil
        publications = []
        publicationOverflow = false
#if CHUNKSEE_COLOR_TRACE
        RechooseDiagnosticTrace.phase(name)
#endif
    }

    static func tileStarted() { snapshot.tileStarted += 1 }
    static func tileFinished() { snapshot.tileFinished += 1 }
    static func tilePublished(in region: RegionPosition, key: RegionTileRenderer.ImageKey) {
        snapshot.tilePublished += 1
        guard region == firstRegion, let phaseStart else { return }
        guard publications.count < 64 else { publicationOverflow = true; return }
        let stamp = phaseStart.values
        publications.append(Publication(key: key, stamp: stamp))
        if snapshot.firstAcceptedTile == nil { snapshot.firstAcceptedTile = stamp }
    }

    /// Resolve identity after the ordinary settle, without guessing that an early tile is final.
    /// Encoding/hashing keys belongs outside the measured publication path.
    static func settled(key: RegionTileRenderer.ImageKey) -> SettledPublications? {
        guard !publicationOverflow, let first = publications.first,
              let final = publications.first(where: { $0.key == key }) else { return nil }
        return SettledPublications(firstTile: first.stamp, firstFinalTile: final.stamp,
            firstMatchesFinal: first.key == key, firstKey: KeyRecord(first.key), settledKey: KeyRecord(key),
            publicationKeys: publications.map { KeyRecord($0.key) }, publicationStamps: publications.map(\.stamp))
    }
}

#if CHUNKSEE_COLOR_TRACE
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

#endif
