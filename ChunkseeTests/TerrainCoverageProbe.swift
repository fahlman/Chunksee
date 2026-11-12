import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Evidence-only comparison of CGContext coverage controls; ordinary tests do not run it.
@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(2))) @MainActor
struct TerrainCoverageProbe {
    private let size = CGSize(width: 32, height: 32)

    private enum Control: String, CaseIterable {
        case unchanged, shouldOff, allowsOff, bothOff

        func apply(to context: CGContext) {
            if self == .shouldOff || self == .bothOff { context.setShouldAntialias(false) }
            if self == .allowsOff || self == .bothOff { context.setAllowsAntialiasing(false) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_TERRAIN_COVERAGE_PROBE"] == "1"))
    func compareExportCoverageControls() throws {
        let background = try tile(alpha: 1, background: true)
        var cases = 0
        var failures = Dictionary(uniqueKeysWithValues: Control.allCases.map { ($0, 0) })
        var screenFailures = 0
        for (columns, rows) in [(2, 1), (1, 2), (2, 2)] {
            for scale: CGFloat in [1, 2] {
                for shift: CGFloat in [0, 0.25, 0.5] {
                    for usesImageAlpha in [true, false] {
                        cases += 1
                        let image = try tile(alpha: usesImageAlpha ? 0.5 : 1)
                        let opacity = usesImageAlpha ? 1.0 : 0.5
                        let identifier = "coverage-\(cases)"
                        let bounds = CGRect(origin: .zero, size: size)
                        let reference = Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                            context.draw(Image(decorative: background.image, scale: 1).interpolation(.none), in: bounds)
                            var layer = context
                            layer.opacity = opacity
                            layer.draw(Image(decorative: image.image, scale: 1).interpolation(.none), in: bounds)
                        }
                        let seam = size.width / 2 + shift
                        let origin = CGPoint(x: columns == 2 ? seam - size.width : 0,
                                             y: rows == 2 ? seam - size.height : 0)
                        let rectangles = (0..<rows).flatMap { row in
                            (0..<columns).map { column in
                                CGRect(x: origin.x + CGFloat(column) * size.width,
                                       y: origin.y + CGFloat(row) * size.height,
                                       width: size.width, height: size.height)
                            }
                        }
                        let drawing = Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                            context.draw(Image(decorative: background.image, scale: 1).interpolation(.none), in: bounds)
                            var layer = context
                            layer.opacity = opacity
                            for rect in rectangles {
                                MapView.drawTerrainImage(image, rect: rect, interpolation: .none, lighting: nil,
                                    protectsWater: false, increasedContrast: false, in: layer)
                            }
                        }
                        let expected = try pixels(render(reference, scale: scale))
                        let screen = try pixels(render(drawing, scale: scale))
                        Attachment.record(expected, named: identifier + "-reference.rgba")
                        Attachment.record(screen, named: identifier + "-screen.rgba")
                        let screenDifference = zip(screen, expected).filter { $0 != $1 }.count
                        if screenDifference != 0 { screenFailures += 1 }
                        let side = Int(size.width * scale)
                        for control in Control.allCases {
                            // Allows-antialiasing is outside the graphics state. Each control gets
                            // a fresh destination so its effect cannot escape to another case.
                            let destination = try #require(MapImage.imageContext(width: side, height: side))
                            control.apply(to: destination)
                            try #require(MapImage.drawImageLayer(drawing, size: size, scale: scale, into: destination))
                            let actual = try pixels(#require(destination.makeImage()))
                            try #require(actual.count == expected.count && screen.count == expected.count)
                            let differentBytes = zip(actual, expected).filter { $0 != $1 }.count
                            if differentBytes != 0 { failures[control, default: 0] += 1 }
                            let differing = stride(from: 0, to: actual.count, by: 4).filter {
                                actual[$0..<($0 + 4)] != expected[$0..<($0 + 4)]
                            }
                            let samples: [[String: Any]] = differing.prefix(8).map { offset in
                                ["x": (offset / 4) % side, "y": (offset / 4) / side,
                                 "actual": Array(actual[offset..<(offset + 4)]),
                                 "expected": Array(expected[offset..<(offset + 4)])]
                            }
                            let record: [String: Any] = [
                                "case": cases, "columns": columns, "rows": rows, "scale": Double(scale),
                                "shift": Double(shift), "alphaSource": usesImageAlpha ? "image" : "context",
                                "control": control.rawValue, "width": side, "height": side,
                                "screenDifferentBytes": screenDifference, "differentBytes": differentBytes,
                                "differentPixels": differing.count, "samples": samples,
                            ]
                            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                            print("Terrain coverage probe: \(String(decoding: data, as: UTF8.self))")
                            Attachment.record(Array(data), named: identifier + "-" + control.rawValue + ".json")
                            Attachment.record(actual, named: identifier + "-" + control.rawValue + ".rgba")
                        }
                    }
                }
            }
        }
        let summary: [String: Any] = [
            "cases": cases, "records": cases * Control.allCases.count, "screenFailures": screenFailures,
            "exportFailures": Dictionary(uniqueKeysWithValues: Control.allCases.map { ($0.rawValue, failures[$0, default: 0]) }),
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("Terrain coverage probe summary: \(String(decoding: data, as: UTF8.self))")
        Attachment.record(Array(data), named: "coverage-summary.json")
        try #require(cases == 36 && screenFailures == 0,
                     "The synthetic screen cases must match their unbroken references")
        try #require(failures[.unchanged, default: 0] > 0,
                     "The unchanged export route must reproduce the seam before comparing controls")
    }

    private func tile(alpha: CGFloat, background: Bool = false) throws -> MapTileImage {
        let context = try #require(MapImage.imageContext(width: 4, height: 4))
        context.setFillColor(background ? CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
                                       : CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return MapTileImage(try #require(context.makeImage()))
    }

    private func render<V: View>(_ view: V, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let normalized = try #require(MapImage.imageContext(width: image.width, height: image.height))
        normalized.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try ItemPictureFixture.pixels(#require(normalized.makeImage())).bytes
    }
}
