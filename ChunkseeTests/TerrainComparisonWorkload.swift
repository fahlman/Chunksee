import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

/// One frozen declaration drives the cases and the eventual decision fields at both endpoints.
nonisolated enum TerrainComparisonWorkload {
    static let root = "/Users/ryan/Developer/Chunksee-runs/"
    static let path = root + "terrain-crisp-edges-evidence/paired-timing-design-1/workload-1.json"
    static let sha256 = "58fadaeb49de5d02e0e0f9a0bc00145eba590efe44b8d13c8a994b56cb395ee3"
    static let amendmentPath = root + "terrain-crisp-edges-evidence/paired-timing-design-1/export-receipts-amendment-1.md"
    static let amendmentSHA256 = "4436b88cea432ecd998f5fffbd4af23a6ff8a4633fb9b4b8054a43cb66640d4e"

    struct Environment: Decodable, Sendable {
        let viewSizePoints: [Double]
        let displayScale: Double
        let colorSpace: String
        let locale: String
        let contrast: String
        let appearance: String
        let dimension: String

        var size: CGSize { CGSize(width: viewSizePoints[0], height: viewSizePoints[1]) }
        var renderLocale: Locale { Locale(identifier: locale) }
    }

    struct Settings: Decodable, Sendable {
        let style: MapStyle
        let surface: Bool
        let gameArtwork: Bool
        let lightingMode: MapLightingMode
        let castsShadows: Bool
        let blendsBiomeColors: Bool
        let timeSpent: Bool
        let slimeChunks: Bool
    }

    struct ViewCase: Decodable, Sendable {
        let id: String
        let spot: String
        let center: [Double]
        let scale: Double
        let settings: Settings

        var viewport: MapViewport {
            MapViewport(center: CGPoint(x: center[0], y: center[1]), scale: scale)
        }
    }

    struct ExportCase: Decodable, Sendable {
        let id: String
        let bounds: [Double]
        let blocksPerPixel: Int
        let settings: Settings

        func plan() throws -> MapExportPlan {
            try MapExportPlan(bounds: CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]),
                              blocksPerPixel: blocksPerPixel)
        }
    }

    struct Field: Decodable, Sendable {
        let id: String
        let kind: String
        let unit: String
        let relativeAllowance: Double
        let absoluteAllowance: Double
    }

    struct Declaration: Decodable, Sendable {
        struct Inputs: Decodable, Sendable {
            let spotsSHA256: String
            let sourceManifestSHA256: String
            let gameManifestSHA256: String
        }
        let environment: Environment
        let inputs: Inputs
        let productHeads: [String: String]
        let views: [ViewCase]
        let exports: [ExportCase]
        let primaryFields: [Field]
        let timingOrder: [String]
    }

    static func read() throws -> Declaration {
        let data = try Data(contentsOf: URL(filePath: path))
        try #require(TerrainComparisonFiles.digest(data) == sha256)
        try #require(TerrainComparisonFiles.digest(Data(contentsOf: URL(filePath: amendmentPath))) == amendmentSHA256)
        let result = try JSONDecoder().decode(Declaration.self, from: data)
        let environment = result.environment
        try #require(environment.viewSizePoints == [960, 640] && environment.displayScale == 2)
        try #require(environment.colorSpace == "sRGB" && environment.locale == "en_US")
        try #require(environment.contrast == "standard" && environment.appearance == "light")
        try #require(environment.dimension == "minecraft:overworld")
        try #require(result.views.count == 24 && result.exports.count == 6)
        try #require(result.primaryFields.count == 109 && Set(result.primaryFields.map(\.id)).count == 109)
        for row in result.views {
            try #require(row.center.count == 2 && row.center.allSatisfy(\.isFinite))
            try #require(row.scale.isFinite && row.scale > 0)
        }
        for row in result.exports { try #require(row.bounds.count == 4 && row.bounds.allSatisfy(\.isFinite)) }
        return result
    }
}
