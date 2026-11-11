import ChunkseeIndex
import ChunkseeKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Evidence-only: the same file is added to both product commits, never to the shipping PR.
@Suite(.isolatedStores, .serialized) struct CreatureRouteComparison {
    struct Configuration: Decodable {
        let world: String
        let game: String
        let output: String
        let expected: String?
        let timing: Bool
    }

    struct Case {
        let key: String
        let content: MapContent
        let viewport: MapViewport
        let markerID: String
        let markerCount: Int
        let expectedRow: SidebarItem
    }

    struct Frame {
        let locations: [AccessibleMapLocation]
        let hit: MapHit?
        let image: CGImage
    }

    private let size = CGSize(width: 1024, height: 768)
    enum Failure: Error { case configuration, image, mismatch(String) }

    @Test(.timeLimit(.minutes(5))) func compare() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHUNKSEE_CREATURE_ROUTE_COMPARISON"] else {
            throw Failure.configuration
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        if config.timing && config.expected == nil { throw Failure.configuration }
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases = try await prepare(config)
        try #require(cases.count == 6)
        var rows: [[String: Any]] = []
        for repetition in 0..<(config.timing ? 4 : 1) {
            for testCase in cases {
                let directory = output.appendingPathComponent(testCase.key, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let expected = config.expected.map { URL(filePath: $0).appendingPathComponent(testCase.key, isDirectory: true) }
                let expectedStructure = try expected.map { try Data(contentsOf: $0.appendingPathComponent("structure.json")) }
                let expectedPixels = try expected.map { try Data(contentsOf: $0.appendingPathComponent("pixels.rgba")) }
                var wall = 0.0, cpu = 0.0
                var maximumChannelDifferences = Array(repeating: 0, count: 4)
                var differingChannelBytes = Array(repeating: 0, count: 4)
                var pixelHashes: [String] = [], structureHashes: [String] = []
                for frameIndex in 0..<(config.timing ? 8 : 1) {
                    try autoreleasepool {
                        let beforeCPU = Self.cpu(), before = DispatchTime.now().uptimeNanoseconds
                        let frame = try render(testCase)
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - before) / 1e9
                        let usedCPU = Self.cpu() - beforeCPU
                        wall += elapsed; cpu += usedCPU
                        // Complete output is consumed after the clock; neither serialization nor
                        // pixel comparisons are charged to the production drawing path.
                        let structure = try describe(frame, for: testCase)
                        let pixels = try rgba(frame.image)
                        let structureHash = Self.hash(structure), pixelHash = Self.hash(pixels)
                        structureHashes.append(structureHash); pixelHashes.append(pixelHash)
                        let dimensionsMatch = frame.image.width == Int(size.width) && frame.image.height == Int(size.height)
                        var maxDifference = 0
                        var matches = dimensionsMatch && stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 }
                        if let expectedPixels {
                            matches = matches && pixels.count == expectedPixels.count
                            if matches {
                                for (offset, bytes) in zip(pixels, expectedPixels).enumerated() {
                                    let difference = abs(Int(bytes.0) - Int(bytes.1))
                                    let channel = offset % 4
                                    maximumChannelDifferences[channel] = max(maximumChannelDifferences[channel], difference)
                                    if difference != 0 { differingChannelBytes[channel] += 1 }
                                    maxDifference = max(maxDifference, difference)
                                }
                                // PointMarkersTests and MobColorTests document one-unit native
                                // premultiplied edge rounding in every channel, including alpha.
                                matches = matches && maxDifference <= 1
                            }
                        }
                        if let expectedStructure { matches = matches && structure == expectedStructure }
                        if !config.timing || !matches {
                            let destination = !matches
                                ? directory.appendingPathComponent("mismatch-\(repetition)-\(frameIndex)", isDirectory: true)
                                : directory
                            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                            try structure.write(to: destination.appendingPathComponent("structure.json"))
                            try pixels.write(to: destination.appendingPathComponent("pixels.rgba"))
                        }
                        if !matches { throw Failure.mismatch(testCase.key) }
                    }
                }
                var row: [String: Any] = ["key": testCase.key, "repetition": repetition,
                    "phase": config.timing ? (repetition == 0 ? "warmup" : "measured") : "proof",
                    "structureHashes": structureHashes, "pixelHashes": pixelHashes,
                    "maximumRGBDifference": maximumChannelDifferences.prefix(3).max() ?? 0,
                    "differingRGBBytes": differingChannelBytes.prefix(3).reduce(0, +),
                    "maximumChannelDifferences": maximumChannelDifferences,
                    "differingChannelBytes": differingChannelBytes,
                    "peakRSSBytes": Self.rss()]
                if config.timing {
                    row["wallSecondsPerFrame"] = wall / 8
                    row["cpuSecondsPerFrame"] = cpu / 8
                }
                rows.append(row)
                try Self.json(rows).write(to: output.appendingPathComponent("records.json"))
            }
        }
        try #require(rows.count == (config.timing ? 24 : 6))
        print("CREATURE_ROUTE_COMPARISON completed \(rows.count) rows")
    }

    private func prepare(_ config: Configuration) async throws -> [Case] {
        let defaults = TestDefaults.make()
        try #require(Locale.preferredLanguages.first == "en-US")
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in
            throw Failure.configuration
        }))
        names.looksUpOnline = false
        names.minecraft.usesGameArtwork = true
        names.minecraft.choose(URL(filePath: config.game, directoryHint: .isDirectory))
        let snapshot = try await WorldSnapshot.read(URL(filePath: config.world, directoryHint: .isDirectory))
        let resources = try await WorldResources(snapshot: snapshot, names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults,
            cacheRoot: nil, watchWorld: { _, _ in nil })
        let session = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        do {
            let map = try #require(session.map)
            map.setStyle(.normal)
            map.setDepth(MapDepth())
            map.setLightingMode(.daylight)
            await resources.waitForRefresh()
            await session.search.waitForIndex()
            await resources.backgroundWork.waitUntilFinished()
            try #require(resources.mapGameResources.data != nil && resources.mapGameResources.artwork != nil)
            try #require(resources.biomeColors != nil)
            try #require(session.selectedDimensionID == "minecraft:overworld")
            try #require(map.style == .normal && map.depth.isSurface && map.lightingMode == .daylight)
            let catalog = session.presentation.selectedIndex.mobTypes
            let marker = try #require(catalog.specialCreatures.sorted { $0.id < $1.id }.first,
                "The copied world must supply a saved special creature; do not synthesize one")
            let initialVisibility = session.visibility
            let routes: [(String, SidebarItem?)] = [
                ("none", nil), ("creatures", .creature(marker.id)), ("mobs", .mobCreature(marker.id)),
            ]
            var result: [Case] = []
            for (name, row) in routes {
                session.visibility = initialVisibility
                session.visibility.creatures.insert(marker.group)
                session.visibility.mobTypes = Set(catalog.kinds.map(\.id))
                session.selection.choose(row)
                session.selection.isInspectorShown = false
                await resources.backgroundWork.waitUntilFinished()
                let content = MapContent(session: session)
                for scale in [CGFloat(1), 8] {
                    let viewport = MapViewport(center: marker.position, scale: scale)
                    let expectedRow = row ?? .creature(marker.id)
                    let scene = content.scene(viewport: viewport, size: size)
                    let selected = try #require(scene.items.first { $0.target == .row(expectedRow) })
                    try #require(selected.labelPriority == (row == nil
                        ? (marker.group == .pet && marker.creature.customName != nil ? .namedPet : .other)
                        : .selected))
                    result.append(Case(key: "\(name)-\(Int(scale))", content: content, viewport: viewport,
                        markerID: marker.id, markerCount: catalog.points.all.count, expectedRow: expectedRow))
                }
            }
            // MapContent is the same immutable presentation value drawing/export consume.
            // Drain the source so indexing and refresh work cannot contaminate component timing.
            session.close(); resources.close()
            await session.waitUntilClosed(); await resources.waitUntilClosed()
            names.minecraft.forget()
            await names.minecraft.waitUntilIdle()
            try #require(session.isClosed && resources.isClosed && resources.backgroundWork.isClosed)
            let preparation: [String: Any] = [
                "processID": ProcessInfo.processInfo.processIdentifier,
                "language": Locale.preferredLanguages, "locale": Locale.current.identifier,
                "dimension": "minecraft:overworld", "style": "normal", "surface": true,
                "lighting": "daylight", "artwork": true, "watcher": false, "onlineLookup": false,
                "world": config.world, "game": config.game, "diskTileCache": false,
                "marker": marker.id, "markerCount": catalog.points.all.count,
                "caseKeys": result.map(\.key), "closedBeforeClock": true,
            ]
            try Self.json(preparation).write(to: URL(filePath: config.output, directoryHint: .isDirectory)
                .appendingPathComponent("preparation.json"))
            return result
        } catch {
            session.close(); resources.close()
            await session.waitUntilClosed(); await resources.waitUntilClosed()
            names.minecraft.forget()
            await names.minecraft.waitUntilIdle()
            throw error
        }
    }

    private func render(_ testCase: Case) throws -> Frame {
        let content = testCase.content, viewport = testCase.viewport
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, actualSize in
            MapView.drawOverlays(viewport: viewport, regions: [], content: content,
                portalStatus: { _ in nil }, in: context, size: actualSize)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "en_US"))
        let renderer = ImageRenderer(content: canvas); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure.image }
        return Frame(locations: content.accessibleLocations(viewport: viewport, size: size),
            hit: content.hit(at: CGPoint(x: size.width / 2, y: size.height / 2), viewport: viewport, size: size), image: image)
    }

    private func describe(_ frame: Frame, for testCase: Case) throws -> Data {
        let scene = testCase.content.scene(viewport: testCase.viewport, size: size)
        func point(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
        func rect(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        func item(_ i: MapScene.Item) -> [String: Any] {
            ["id": i.id, "target": String(reflecting: i.target), "layer": i.layer.rawValue,
             "position": point(i.position), "y": i.y.map { $0 as Any } ?? NSNull(),
             "anchor": point(i.anchor), "point": point(i.point), "frame": rect(i.frame),
             "priority": String(reflecting: i.labelPriority), "dimmed": i.isDimmed]
        }
        let locations: [[String: Any]] = frame.locations.map {
            ["id": $0.id, "name": $0.name, "position": point($0.position),
             "y": $0.y.map { $0 as Any } ?? NSNull(),
             "target": $0.target.map { String(reflecting: $0) as Any } ?? NSNull(),
             "anchor": $0.anchor.map { point($0) as Any } ?? NSNull(), "frame": rect($0.frame)]
        }
        let hit: Any
        if let value = frame.hit {
            hit = ["target": String(reflecting: value.target), "position": point(value.position),
                   "y": value.y.map { $0 as Any } ?? NSNull()] as [String: Any]
        } else { hit = NSNull() }
        return try Self.json(["key": testCase.key, "marker": testCase.markerID, "markerCount": testCase.markerCount,
            "expectedRow": String(reflecting: testCase.expectedRow),
            "imageSize": [frame.image.width, frame.image.height],
            "items": scene.items.map(item),
            "structures": scene.structures.map { ["item": item($0.item), "outline": rect($0.outline),
                "portalRoom": $0.portalRoom.map { point($0) as Any } ?? NSNull()] },
            "biomes": scene.biomeAreas.map { ["id": $0.area.id, "point": point($0.point), "frame": rect($0.frame)] },
            "locations": locations, "hit": hit])
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.image }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { throw Failure.image }
        return Data(bytes: bytes, count: width * height * 4)
    }

    nonisolated private static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    nonisolated private static func rss() -> Int {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return usage.ru_maxrss
    }
    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
