import CoreGraphics
import Foundation
import ChunkseeKit
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct NavigationTests {
    private func openWorld() async throws -> (URL, WorldSession) {
        let url = try TestWorld.make(chunks: [])
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        await session.search.waitForIndex()
        return (url, session)
    }

    @Test func coordinateJumpsPreserveZoomAndLocationFocusStillZoomsIn() async throws {
        let (url, session) = try await openWorld()
        defer { session.close(); try? FileManager.default.removeItem(at: url) }
        let map = try #require(session.map)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        #expect(!session.navigation.canFitWorld) // the dimension has no saved regions
        map.viewport = MapViewport(center: CGPoint(x: 123, y: -456), scale: 0.125)
        session.navigation.goToCoordinates(CGPoint(x: -266, y: 71))
        #expect(map.viewport == MapViewport(center: CGPoint(x: -265.5, y: 71.5), scale: 0.125))
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity),
                      CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0)] {
            session.navigation.goToCoordinates(point)
        }
        #expect(map.viewport == MapViewport(center: CGPoint(x: -265.5, y: 71.5), scale: 0.125))
        session.routing.focus(on: .init(dimension: "minecraft:overworld", x: 10, y: 64, z: 20))
        #expect(map.viewport.scale == 2)
        session.navigation.goBack()
        #expect(map.viewport == MapViewport(center: CGPoint(x: -265.5, y: 71.5), scale: 0.125))
        session.navigation.goBack()
        #expect(map.viewport == MapViewport(center: CGPoint(x: 123, y: -456), scale: 0.125))
        #expect(!session.navigation.canGoBack)
        session.navigation.goToCoordinates(CGPoint(x: -8.7, y: 14.2))
        #expect(map.viewport == MapViewport(center: CGPoint(x: -8.5, y: 14.5), scale: 0.125))
        session.close()
        await session.waitUntilClosed()
    }

    @Test func backForwardRememberPansAndZoomsAndANewJumpClearsForward() async throws {
        let (url, session) = try await openWorld()
        defer { session.close(); try? FileManager.default.removeItem(at: url) }
        let map = try #require(session.map)
        let original = MapViewport(center: CGPoint(x: 100.5, y: -199.5), scale: 0.25)
        map.viewport = original
        session.navigation.goToCoordinates(original.center)
        #expect(!session.navigation.canGoBack)
        session.navigation.goToCoordinates(CGPoint(x: -300, y: 40))
        map.viewport.pan(by: CGSize(width: 12, height: -8))
        map.viewport.scale = 8
        let adjusted = map.viewport
        session.navigation.goBack()
        #expect(map.viewport == original)
        #expect(!session.navigation.canGoBack && session.navigation.canGoForward)
        session.navigation.goToCoordinates(original.center) // a no-op does not discard Forward
        #expect(session.navigation.canGoForward)
        session.navigation.goForward()
        #expect(map.viewport == adjusted)
        session.navigation.goBack()
        session.navigation.goToCoordinates(CGPoint(x: 5, y: 6))
        #expect(!session.navigation.canGoForward)
        session.navigation.goBack()
        #expect(map.viewport == original)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func aReplacedDocumentSessionKeepsNavigationAndAnotherWorldHasNone() async throws {
        let (url, session) = try await openWorld()
        defer { session.close(); try? FileManager.default.removeItem(at: url) }
        let original = MapViewport(center: CGPoint(x: -100, y: 200), scale: 0.5)
        session.map?.viewport = original
        session.navigation.goToCoordinates(CGPoint(x: 10, y: -20))
        session.map?.setDepth(MapDepth(y: 12, isSurface: false))
        session.annotations.ruler.isEnabled = true
        session.annotations.ruler.mark(.zero)
        session.annotations.ruler.mark(CGPoint(x: 3, y: 4))
        session.close()
        await session.waitUntilClosed()
        let defaults = TestDefaults.make()
        let replacement = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { replacement.close() }
        replacement.restoreView(from: session)
        #expect(replacement.annotations.ruler == session.annotations.ruler && replacement.annotations.ruler.distance == 5)
        #expect(replacement.map?.viewport.center == CGPoint(x: 10.5, y: -19.5))
        #expect(replacement.map?.depth == MapDepth(y: 12, isSurface: false))
        replacement.navigation.goBack()
        #expect(replacement.map?.viewport == original)
        #expect(session.map?.viewport.center == CGPoint(x: 10.5, y: -19.5))
        let (otherURL, other) = try await openWorld()
        defer { other.close(); try? FileManager.default.removeItem(at: otherURL) }
        #expect(!other.navigation.canGoBack && !other.navigation.canGoForward)
        replacement.close(); other.close()
        await replacement.waitUntilClosed(); await other.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1)))
    func localNavigationStopsWithItsMapAndAReplacementCanRestoreTheClosedSource() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let work = BackgroundWork()
        let map = MapModel(work: work, dimension: dimension, center: .zero, cacheDirectory: nil)
        let navigation = MapNavigation(map: map)
        let original = map.viewport
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        var updatesIterator = updates.makeAsyncIterator()
        let couldGoBack = withObservationTracking { navigation.canGoBack } onChange: { continuation.yield(true) }
        #expect(!couldGoBack)
        navigation.goToCoordinates(CGPoint(x: -9, y: 13))
        let updated = await updatesIterator.next(isolation: #isolation)
        #expect(updated == true && navigation.canGoBack)
        map.setDepth(MapDepth(y: 22, isSurface: false))
        let lastView = map.viewport
        map.close()
        navigation.focus(on: CGPoint(x: 500, y: 600))
        navigation.goToCoordinates(.zero)
        navigation.goBack()
        navigation.goForward()
        navigation.fitWorld()
        #expect(map.viewport == lastView && !navigation.canGoBack && !navigation.canGoForward)

        let replacement = MapModel(work: work, dimension: dimension, center: .zero, cacheDirectory: nil)
        let restored = MapNavigation(map: replacement)
        restored.restore(from: navigation)
        #expect(replacement.viewport == lastView && replacement.depth == map.depth)
        #expect(restored.canGoBack)
        restored.goBack()
        #expect(replacement.viewport == original && map.viewport == lastView)
        replacement.close()
        work.close()
        await work.waitUntilFinished()
    }
}

@Suite(.isolatedStores) struct FitWorldTests {
    @Test func regionBoundsWithNegativeCoordinatesFitInsideTheMargin() throws {
        let regions: Set<RegionPosition> = [.init(x: -3, z: -2), .init(x: 1, z: 4)]
        let size = CGSize(width: 800, height: 600)
        let fit = try #require(MapViewport.fitting(regions, in: size))
        #expect(fit.center == CGPoint(x: -256, y: 768))
        for region in regions {
            let rect = try #require(fit.viewRect(for: region, in: size))
            #expect(rect.minX >= 24 - 0.001 && rect.maxX <= size.width - 24 + 0.001)
            #expect(rect.minY >= 24 - 0.001 && rect.maxY <= size.height - 24 + 0.001)
        }
        #expect(MapViewport.fitting([], in: size) == nil)
        #expect(MapViewport.fitting(regions, in: .zero) == nil)
    }

    @Test func distantRegionsFitBelowTheSmallestPresetWithoutEnumeratingEmptyRegions() throws {
        let regions: Set<RegionPosition> = [.init(x: -50_000, z: -50_000), .init(x: 50_000, z: 50_000)]
        let size = CGSize(width: 800, height: 600)
        let fit = try #require(MapViewport.fitting(regions, in: size))
        #expect(fit.scale < 1.0 / 16)
        #expect(Set(fit.visibleRegions(in: size, among: regions)) == regions)
        let grid = MapGrid(viewport: fit, size: size)
        #expect(grid.vertical.count < 100 && grid.horizontal.count < 100)
        #expect(!ZoomPercentage.text(fit.scale).hasPrefix("0%"))
        let larger = try #require(MapViewport.fitting(regions, in: CGSize(width: 1600, height: 1200)))
        #expect(larger.scale > fit.scale)
    }

    @Test func fitIsANavigationJumpAndAnEmptyDimensionCannotFit() async throws {
        let chunk = TestWorld.chunk(x: -33, z: 65, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let map = try #require(session.map)
        let original = map.viewport
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        #expect(session.navigation.canFitWorld)
        session.navigation.fitWorld()
        #expect(map.viewport.center == CGPoint(x: -768, y: 1280))
        session.navigation.goBack()
        #expect(map.viewport == original)
        session.close()
        await session.waitUntilClosed()
    }
}

@Suite(.isolatedStores) struct MapRulerTests {
    @Test(.timeLimit(.minutes(1)))
    func annotationChangesReachTheSheetAndMapWithoutRetainingTheDocument() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        var session: WorldSession? = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session?.close() }
        let annotations = try #require(session?.annotations)
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        defer { continuation.finish() }
        var iterator = updates.makeAsyncIterator()
        let initialDraft = withObservationTracking { session?.annotations.draft } onChange: { continuation.yield(true) }
        #expect(initialDraft == nil)
        annotations.savePlace(at: CGPoint(x: -8.7, y: 14.2))
        let draftChanged = await iterator.next(isolation: #isolation)
        #expect(draftChanged == true && annotations.draft?.position == CGPoint(x: -9, y: 14))
        annotations.draft = nil
        let initialRuler = withObservationTracking { session.map(MapContent.init(session:))?.ruler } onChange: { continuation.yield(true) }
        #expect(initialRuler?.isEnabled == false)
        annotations.beginMeasurement(at: CGPoint(x: -8.7, y: 14.2), in: "minecraft:overworld")
        let rulerChanged = await iterator.next(isolation: #isolation)
        #expect(rulerChanged == true && session.map(MapContent.init(session:))?.ruler.start?.position == CGPoint(x: -9, y: 14))
        session?.close()
        await session?.waitUntilClosed()
        annotations.savePlace(at: .zero)
        #expect(annotations.draft == nil)
        weak let released = session
        session = nil
        #expect(released == nil)
        annotations.savePlace(at: .zero)
        #expect(annotations.draft == nil && annotations.listedPlaces.isEmpty)
    }

    @Test func measurementUsesWholeBlocksAndTheThirdClickStartsAgain() {
        var ruler = MapRuler()
        ruler.mark(.zero)
        #expect(ruler.start == nil)
        ruler.isEnabled = true
        ruler.mark(CGPoint(x: -0.1, y: -0.1))
        ruler.mark(CGPoint(x: 2.8, y: 3.8))
        #expect(ruler.start?.position == CGPoint(x: -1, y: -1))
        #expect(ruler.end?.position == CGPoint(x: 2, y: 3))
        #expect(ruler.distance == 5)
        ruler.mark(CGPoint(x: 10, y: 20))
        #expect(ruler.start?.position == CGPoint(x: 10, y: 20) && ruler.end == nil)
        ruler.escape()
        #expect(ruler.start == nil && ruler.isEnabled)
        ruler.escape()
        #expect(!ruler.isEnabled)
    }

    @Test func largeCoordinatesDoNotOverflowAndTurningTheToolOffClearsIt() {
        var ruler = MapRuler()
        ruler.isEnabled = true
        ruler.mark(CGPoint(x: Int(Int32.min), y: 0))
        ruler.mark(CGPoint(x: Int(Int32.max), y: 0))
        #expect(ruler.distance == 4_294_967_295)
        ruler.isEnabled = false
        #expect(ruler.start == nil && ruler.end == nil && ruler.distance == nil)
    }
}
