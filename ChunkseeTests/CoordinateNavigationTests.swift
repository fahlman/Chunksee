import CoreGraphics
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct CoordinateNavigationTests {
    @Test func signedCoordinatesAcceptPastedMinusAndWhitespace() {
        #expect(MapCoordinates(x: "−266", z: "71")?.position == CGPoint(x: -266, y: 71))
        #expect(MapCoordinates(x: "  -266\n", z: " +71 ")?.position == CGPoint(x: -266, y: 71))
        #expect(MapCoordinates(x: "0", z: "-0")?.position == .zero)
    }

    @Test(arguments: ["", "-", "X −266", "1.5", "NaN", "1e3", "2147483648", "999999999999999999999999999999"])
    func invalidCoordinatesCannotBecomeMapDestinations(_ text: String) {
        #expect(MapCoordinates(x: text, z: "71") == nil)
        #expect(MapCoordinates(x: "-266", z: text) == nil)
    }

    @Test func aClickedMapPointUsesTheContainingBlockIncludingNegativeCoordinates() {
        let viewport = MapViewport(center: CGPoint(x: -0.1, y: -16.1), scale: 4)
        let block = viewport.blockPoint(at: CGPoint(x: 400, y: 300), in: CGSize(width: 800, height: 600))
        #expect(MapCoordinates(point: block)?.position == CGPoint(x: -1, y: -17))
        #expect(MapCoordinates(point: CGPoint(x: CGFloat.nan, y: 0)) == nil)
        #expect(MapCoordinates(point: CGPoint(x: Double(Int32.max) + 1, y: 0)) == nil)
    }
}
