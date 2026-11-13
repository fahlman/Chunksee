import ChunkseeKit
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@MainActor
enum TerrainComparisonRender {
    struct NativeResult {
        let image: MapImage
        let drawCalls: Int
        let contrast: ColorSchemeContrast?
        let displayScale: CGFloat?
    }

    /// The screen's drawing entry and legend, completed offscreen. This does not measure
    /// a native window frame, interaction latency or GPU latency.
    static func native(_ session: WorldSession, environment: TerrainComparisonWorkload.Environment) throws -> NativeResult {
        let map = try #require(session.map), content = MapContent(session: session)
        var drawCalls = 0
        var contrast: ColorSchemeContrast?
        var scale: CGFloat?
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            drawCalls += 1
            contrast = context.environment.colorSchemeContrast
            scale = context.environment.displayScale
            TerrainComparisonAdapter.draw(session, map: map, content: content, context: context, size: size)
        }
        .modifier(MapLegendOverlay(layers: content))
        .environment(\.displayScale, environment.displayScale)
        .environment(\.colorScheme, .light)
        .environment(\.locale, environment.renderLocale)
        .frame(width: environment.size.width, height: environment.size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = environment.displayScale
        renderer.colorMode = .nonLinear
        let image = try #require(renderer.cgImage)
        return NativeResult(image: try #require(MapImage.png(image)), drawCalls: drawCalls,
                            contrast: contrast, displayScale: scale)
    }

    /// Clocks end before decoding, hashing, comparison or writes. Even a failed image
    /// check retains the completed interval and PNG rather than discarding the attempt.
    static func view(_ session: WorldSession, environment: TerrainComparisonWorkload.Environment,
                     to folder: URL) throws -> [String: Data] {
        var artifacts: [String: Data] = [:]
        var intervals: [String: TerrainComparisonMeasures.Interval] = [:]
        do {
            let nativeStart = TerrainComparisonMeasures.Stamp()
            let native = try native(session, environment: environment)
            intervals["completedNativeImage"] = nativeStart.until(.init())
            artifacts["native.png"] = native.image.data
            try #require(native.drawCalls > 0 && native.contrast == .standard)
            try #require(native.displayScale == environment.displayScale)
            artifacts["native-receipt.json"] = try TerrainComparisonFiles.json([
                "canvasDrawCalls": native.drawCalls, "contrast": environment.contrast, "displayScale": environment.displayScale,
            ])
            let copyStart = TerrainComparisonMeasures.Stamp()
            let rendered = MapImage.render(session: session, colorScheme: .light,
                locale: environment.renderLocale, contrast: .standard)
            intervals["copyImage"] = copyStart.until(.init())
            let copy = try #require(rendered)
            artifacts["copy.png"] = copy.data
            let width = Int(environment.size.width * environment.displayScale)
            let height = Int(environment.size.height * environment.displayScale)
            artifacts["native.rgba"] = try pixels(native.image, width: width, height: height)
            artifacts["copy.rgba"] = try pixels(copy, width: width, height: height)
            artifacts["intervals.json"] = try TerrainComparisonFiles.encoded(intervals)
            try TerrainComparisonFiles.write(artifacts, to: folder)
            return artifacts
        } catch {
            artifacts["intervals.json"] = try? TerrainComparisonFiles.encoded(intervals)
            try? TerrainComparisonFiles.write(artifacts, to: folder)
            throw error
        }
    }

    /// No tile callback or payload recorder is installed in the timed streaming operation.
    static func export(_ session: WorldSession, plan: MapExportPlan,
                       environment: TerrainComparisonWorkload.Environment, to folder: URL) async throws -> [String: Data] {
        let map = try #require(session.map)
        let renderer = try requiredRenderer(map)
        let content = MapContent(session: session), regions = map.availableRegions
        var progress: [[Int]] = []
        var artifacts: [String: Data] = [:]
        let start = TerrainComparisonMeasures.Stamp()
        do {
            let image = try await MapImage.export(plan: plan, regions: regions, renderer: renderer, content: content,
                portalStatus: { session.presentation.linkStatus(for: $0) }, colorScheme: .light,
                locale: environment.renderLocale, contrast: .standard,
                progress: { progress.append([$0, $1]) })
            let interval = start.until(.init())
            artifacts["intervals.json"] = try TerrainComparisonFiles.encoded(["export": interval])
            artifacts["export.png"] = image.data
            artifacts["progress.json"] = try TerrainComparisonFiles.json(progress)
            artifacts["export.rgba"] = try pixels(image, width: plan.width, height: plan.height)
            let count = plan.viewport.visibleRegions(in: plan.size, among: regions).count
            try #require(count > 0 && progress == (0...count).map { [$0, count] })
            try TerrainComparisonFiles.write(artifacts, to: folder)
            return artifacts
        } catch {
            artifacts["progress.json"] = try? TerrainComparisonFiles.json(progress)
            try? TerrainComparisonFiles.write(artifacts, to: folder)
            throw error
        }
    }

    static func pixels(_ image: MapImage, width: Int, height: Int) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(decoded.width == width && decoded.height == height)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = Data(count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
