import AppKit
import ChunkseeKit
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@MainActor
enum MapComparisonEvidence {
    static let locale = Locale(identifier: "en_US")
    static let size = CGSize(width: 512, height: 384)
    static let water = CGPoint(x: -256, y: -256)

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(value)
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoded(value), options: [.fragmentsAllowed])
    }

    static func write(_ artifacts: [String: Data], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in artifacts {
            try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }

    static func imageKey(_ key: RegionTileRenderer.ImageKey) throws -> [String: Any] {
        ["surface": try object(key.surface),
         "heightScale": try key.preparation.heightScale.map(object) ?? NSNull(),
         "usesSavedLighting": key.preparation.usesSavedLighting,
         "chunk": key.chunk.map { [$0.x, $0.z] } as Any? ?? NSNull()]
    }

    /// Preserve source image bytes and format, excluding only row padding.
    static func rawImage(_ value: CGImage) throws -> (Data, [String: Any]) {
        try #require(value.bitsPerPixel == 32 && value.bitsPerComponent == 8)
        let source = try #require(value.dataProvider?.data) as Data
        try #require(source.count >= value.bytesPerRow * value.height)
        var bytes = Data(capacity: value.width * value.height * 4)
        for row in 0..<value.height {
            bytes.append(source[(row * value.bytesPerRow)..<(row * value.bytesPerRow + value.width * 4)])
        }
        return (bytes, ["width": value.width, "height": value.height,
                        "bitsPerComponent": value.bitsPerComponent, "bitmapInfo": value.bitmapInfo.rawValue,
                        "colorSpace": value.colorSpace?.name as Any? ?? NSNull()])
    }

    /// Compare all PNG pixels in one declared format while retaining the original PNG too.
    static func pixels(_ image: MapImage) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = Data(count: decoded.width * decoded.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: decoded.width,
                height: decoded.height, bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        }
        return bytes
    }

    /// This is the screen's real drawing entry and legend, without opening a native window.
    /// Native input, layout and accessibility checks remain separate.
    static func live(_ session: WorldSession, appearance: ColorScheme) throws -> MapImage {
        let map = try #require(session.map), content = MapContent(session: session)
        var renderedContrast: ColorSchemeContrast?
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            renderedContrast = context.environment.colorSchemeContrast
            MapView.drawMap(map, content: content, portalStatus: { session.presentation.linkStatus(for: $0) },
                            displayScale: 1, in: context, size: size)
        }
        .modifier(MapLegendOverlay(layers: content))
        .environment(\.colorScheme, appearance)
        .environment(\.locale, locale)
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        let image: CGImage = try #require(renderer.cgImage)
        // Contrast is read-only. Require the actual synchronous render to match Copy/export
        // without changing the Mac's accessibility preferences.
        try #require(renderedContrast == .standard)
        return try #require(MapImage.png(image))
    }

    static func pictures(_ session: WorldSession, export: Bool, to folder: URL) async throws -> Int {
        let map = try #require(session.map)
        var count = 0
        for (name, appearance) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let output = folder.appendingPathComponent(name)
            var artifacts: [String: Data] = [:]
            do {
                let live = try live(session, appearance: appearance)
                artifacts["live.png"] = live.data
                let livePixels = try pixels(live)
                artifacts["live.rgba"] = livePixels
                let copy: MapImage = try #require(MapImage.render(session: session, colorScheme: appearance,
                    locale: locale, contrast: .standard))
                artifacts["copy.png"] = copy.data
                let copyPixels = try pixels(copy)
                artifacts["copy.rgba"] = copyPixels
                try #require(livePixels.count == 512 * 384 * 4 && copyPixels.count == livePixels.count)
                let board = NSPasteboard(name: .init("Chunksee-MapComparison-" + UUID().uuidString))
                defer { board.releaseGlobally() }
                copy.copy(to: board)
                let clipboard = try #require(board.data(forType: .png))
                artifacts["clipboard.png"] = clipboard
                try #require(clipboard == copy.data)
                artifacts["paths.json"] = try json([
                    "liveEqualsCopy": livePixels == copyPixels,
                    "differentPixels": stride(from: 0, to: copyPixels.count, by: 4).filter {
                        livePixels[$0..<$0 + 4] != copyPixels[$0..<$0 + 4]
                    }.count,
                    "privateClipboardMatches": true, "width": 512, "height": 384,
                    "pixelFormat": "8-bit premultiplied RGBA, sRGB, packed rows",
                ])
                count += 2
                if export {
                    let plan = try MapExportPlan(bounds: CGRect(x: -257, y: -448, width: 512, height: 384), blocksPerPixel: 1)
                    try #require(plan.viewport == map.viewport && plan.size == size)
                    var progress: [[Int]] = []
                    let exported = try await MapImage.export(plan: plan, regions: map.availableRegions,
                        renderer: requiredRenderer(map), content: MapContent(session: session),
                        portalStatus: { session.presentation.linkStatus(for: $0) },
                        colorScheme: appearance, locale: locale, contrast: .standard,
                        progress: { progress.append([$0, $1]) })
                    artifacts["export.png"] = exported.data
                    artifacts["export.rgba"] = try pixels(exported)
                    artifacts["export-progress.json"] = try json(progress)
                    try #require(artifacts["export.rgba"] == copyPixels)
                    let expected = map.viewport.visibleRegions(in: size, among: map.availableRegions).count
                    try #require(progress == (0...expected).map { [$0, expected] })
                    count += 1
                }
            } catch {
                try? write(artifacts, to: output)
                throw error
            }
            try write(artifacts, to: output)
        }
        return count
    }
}

