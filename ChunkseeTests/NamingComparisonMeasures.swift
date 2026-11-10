import ChunkseeKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Evidence clocks only. File capture and serialization happen after each product interval.
@MainActor
enum NamingComparisonMeasures {
    /// The process high-water mark includes startup and evidence capture. Read it after
    /// the whole workload; it cannot be reset or attributed to an individual cell.
    static func processResources() throws -> [String: Any] {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        try #require(usage.ru_maxrss > 0)
        return ["processID": ProcessInfo.processInfo.processIdentifier,
                "peakRSSBytes": Int64(usage.ru_maxrss),
                "source": "getrusage(RUSAGE_SELF).ru_maxrss",
                "scope": "Process launch through four completed cells, input checks and evidence capture; final resource-record writing and test-framework teardown excluded"]
    }

    nonisolated struct Stamp {
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = Self.cpuSeconds()

        static func cpuSeconds() -> Double {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }

        func until(_ end: Stamp) -> [String: Double] {
            ["wallSeconds": Double(end.wall - wall) / 1e9, "cpuSeconds": end.cpu - cpu]
        }
    }

    /// These are the approved workload's four intended membership changes, not product rules.
    static let intendedFrenchQueries: Set<String> = [
        "charbon", "trade:solidité", "creature:mouton", "biome:plaines",
    ]

    static func isScored(query: String, language: String) -> Bool {
        language != "fr_FR" || !intendedFrenchQueries.contains(query)
    }

    final class Draws {
        var intervals: [[String: Double]] = []
    }

    /// The Canvas invokes the shipping overlay function. Its clocks cover that function only;
    /// creating/rasterizing the Canvas and the separate Copy call are not folded into its sum.
    static func overlays(_ session: WorldSession, content: MapContent) throws -> [[String: Double]] {
        let map = try #require(session.map)
        let size = NamingComparisonCapture.size
        let viewport = map.viewport
        let visible = viewport.visibleRegions(in: size, among: map.availableRegions)
        let draws = Draws()
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let start = Stamp()
            MapView.drawOverlays(viewport: viewport, regions: visible, content: content,
                portalStatus: { session.presentation.linkStatus(for: $0) }, in: context, size: size)
            let end = Stamp()
            draws.intervals.append(start.until(end))
        }
        .environment(\.colorScheme, .light)
        .environment(\.locale, NamingComparisonCapture.locale)
        let destination = try #require(MapImage.imageContext(width: Int(size.width), height: Int(size.height)))
        try #require(MapImage.drawImageLayer(canvas, size: size, scale: 1, into: destination))
        try #require(!draws.intervals.isEmpty && destination.makeImage() != nil)
        return draws.intervals
    }

    /// Table context is read from the actual frozen Kit value outside product intervals. These
    /// are content sizes, not heap allocations or evidence of which phase caused a memory peak.
    static func languageTables(_ names: GameNames) throws -> [String: Any] {
        let optional = try #require(Mirror(reflecting: names).children.first { $0.label == "language" }?.value)
        let language = try #require(Mirror(reflecting: optional).children.first?.value as? GameLanguage)
        let fields = Mirror(reflecting: language)
        let values = try #require(fields.children.first { $0.label == "values" }?.value as? [String: String])
        let renamed = try #require(fields.children.first { $0.label == "renamedKeys" }?.value as? [String: String])
        func size(_ table: [String: String]) -> [String: Int] {
            ["entries": table.count,
             "keyUTF8Bytes": table.keys.reduce(0) { $0 + $1.utf8.count },
             "valueUTF8Bytes": table.values.reduce(0) { $0 + $1.utf8.count }]
        }
        return ["translations": size(values), "renamedKeys": size(renamed),
                "declaredLanguageCode": language.declaredLanguageCode as Any? ?? NSNull(),
                "scope": "Retained table content only; not an allocated-memory estimate"]
    }

    nonisolated struct CacheFile: Codable, Equatable, Sendable {
        let sha256: String
        let size: Int
        let modified: Date
        let permissions: Int
    }

    @concurrent static func cacheFiles(_ root: URL) async throws -> [String: CacheFile] {
        try readCacheFiles(root)
    }

    nonisolated private static func readCacheFiles(_ root: URL) throws -> [String: CacheFile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [:] }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try #require(rootValues.isDirectory == true && rootValues.isSymbolicLink == false)
        let fields: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .fileSizeKey]
        let iterator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: Array(fields)))
        var result: [String: CacheFile] = [:]
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: fields)
            try #require(values.isSymbolicLink == false)
            if values.isDirectory == true { continue }
            try #require(values.isRegularFile == true && url.path.hasPrefix(root.path + "/"))
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let permissions = try #require(attributes[.posixPermissions] as? Int)
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            result[String(url.path.dropFirst(root.path.count + 1))] = CacheFile(
                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                size: try #require(values.fileSize), modified: try #require(values.contentModificationDate),
                permissions: permissions)
        }
        return result
    }
}
