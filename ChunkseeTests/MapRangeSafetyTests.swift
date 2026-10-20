import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapRangeSafetyTests {
    private let size = CGSize(width: 800, height: 600)

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int.max)])
    func invalidCentersHaveNoGridOrVisibleRegions(_ value: Double) {
        for center in [CGPoint(x: value, y: 0), CGPoint(x: 0, y: value)] {
            let viewport = MapViewport(center: center)
            #expect(viewport.visibleRegionRange(in: size) == nil)
            #expect(viewport.visibleRegions(in: size, among: [.init(x: 0, z: 0)]).isEmpty)
            let grid = MapGrid(viewport: viewport, size: size)
            #expect(grid.vertical.isEmpty && grid.horizontal.isEmpty)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -1, .leastNonzeroMagnitude, .greatestFiniteMagnitude])
    func invalidScalesCannotTrapOrLoop(_ value: Double) {
        var viewport = MapViewport()
        viewport.scale = value
        #expect(viewport.visibleRegionRange(in: size) == nil)
        #expect(MapGrid(viewport: viewport, size: size).vertical.isEmpty)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude])
    func invalidViewSizesHaveNoRanges(_ value: Double) {
        let size = CGSize(width: value, height: value)
        #expect(MapViewport().visibleRegionRange(in: size) == nil)
        #expect(MapGrid(viewport: MapViewport(), size: size).vertical.isEmpty)
    }

    @Test func regionDistanceDoesNotMultiplyIntegersBeforeConverting() {
        let viewport = MapViewport()
        #expect(viewport.distanceToCenter(.init(x: Int.max, z: Int.min)).isFinite)
        #expect(viewport.visibleRegions(in: size, among: [.init(x: Int.max, z: Int.min)]).isEmpty)
    }

    @Test func negativeBoundsStillRoundDownAndGridEdgesRoundUp() throws {
        let viewport = MapViewport(center: CGPoint(x: -0.25, y: -0.25))
        let range = try #require(viewport.visibleRegionRange(in: CGSize(width: 1, height: 1)))
        #expect(range.xs == -1...0 && range.zs == -1...0)
        let grid = MapGrid(viewport: viewport, size: CGSize(width: 32, height: 32))
        #expect(grid.vertical.map(\.block) == [-16, 0])
    }

    @Test func invalidSavedViewsAreIgnoredAndDoNotOverwriteGoodViews() throws {
        let defaults = TestDefaults.make()
        let world = URL(fileURLWithPath: "/tmp/Map Range Safety")
        let views = WorldSettings(world: world, defaults: defaults)
        let key = "worldSettings." + world.path, dimension = "minecraft:overworld"
        for invalid in [[Double.nan, 0, 1], [0, .infinity, 1], [Double(Int.max), 0, 1], [0, 0, .nan], [0, 0, .infinity], [0, 0, -1]] {
            defaults.set(["views": [dimension: invalid]], forKey: key)
            #expect(views.viewport(for: dimension) == nil)
        }
        let good = MapViewport(center: CGPoint(x: -12.5, y: 40), scale: 2)
        views.save(good, for: dimension, selected: dimension)
        views.save(MapViewport(center: CGPoint(x: CGFloat.nan, y: 0)), for: dimension, selected: dimension)
        #expect(views.viewport(for: dimension) == good)
    }
}
