import CoreGraphics
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct CoordinateNavigationTests {
    @Test func nativeDestinationsAndCreatureMarkersUseTheSameSupportedLocations() {
        let examples: [(Double, Double, Double, Bool)] = [
            (-8.7, 63.9, -16.1, true),
            (Double(Int32.min), Double(Int.min), Double(Int32.max) + 0.5, true),
            (Double(Int32.min) - 0.5, 64, 0, false),
            (0, 64, Double(Int32.max) + 1, false),
            (0, .nan, 0, false), (0, Double(Int.max), 0, false),
        ]
        for (x, y, z, expected) in examples {
            let location = Coordinates(CGPoint(x: x, y: z), y: y)
            let creature = Creature(id: "minecraft:cat", x: x, y: y, z: z, customName: "Cat")
            #expect(location.isMappable == expected)
            #expect(Coordinates.canLocate(x: x, y: y, z: z) == expected)
            #expect((CreatureMarker(creature, dimension: "minecraft:overworld") != nil) == expected)
        }
        let point = MapCoordinates(point: CGPoint(x: -0.1, y: 0.1))
        #expect(point?.position == CGPoint(x: -1, y: 0) && point?.y == nil)
    }

    @Test func signedCoordinatesAcceptPastedMinusAndWhitespace() {
        #expect(MapCoordinates(text: "−266 71")?.position == CGPoint(x: -266, y: 71))
        #expect(MapCoordinates(text: "  -266\n +71 ")?.position == CGPoint(x: -266, y: 71))
        #expect(MapCoordinates(text: "0 -0")?.position == .zero)
        #expect(MapCoordinates(text: "−266 71")?.y == nil)
        let triple = MapCoordinates(text: "\t−266  −48\n +71 ")
        #expect(triple?.position == CGPoint(x: -266, y: 71))
        #expect(triple?.y == -48)
        #expect(MapCoordinates(text: "\(Int32.min) \(Int.min) \(Int32.max)")?.y == Int.min)
        #expect(MapCoordinates(text: "0 \(Int.max) 0")?.y == Int.max)
        #expect(triple?.entryText(height: triple?.y) == "-266 -48 71")
        #expect(triple?.entryText(height: nil) == "-266 71")
    }

    @Test(arguments: ["", "-", "X −266", "1.5", "NaN", "1e3", "2147483648", "999999999999999999999999999999"])
    func invalidCoordinatesCannotBecomeMapDestinations(_ text: String) {
        #expect(MapCoordinates(text: "\(text) 71") == nil)
        #expect(MapCoordinates(text: "-266 \(text)") == nil)
    }

    @Test(arguments: ["1", "1 2 3 4", "1 2.5 3", "1 NaN 3", "1 999999999999999999999999 3", "1,2,3", "~1 64 2"])
    func malformedCopiedCoordinatesAreRejected(_ text: String) {
        #expect(MapCoordinates(text: text) == nil)
    }

    @Test func aClickedMapPointUsesTheContainingBlockIncludingNegativeCoordinates() {
        let viewport = MapViewport(center: CGPoint(x: -0.1, y: -16.1), scale: 4)
        let block = viewport.blockPoint(at: CGPoint(x: 400, y: 300), in: CGSize(width: 800, height: 600))
        #expect(MapCoordinates(point: block)?.position == CGPoint(x: -1, y: -17))
        #expect(MapCoordinates(point: CGPoint(x: CGFloat.nan, y: 0)) == nil)
        #expect(MapCoordinates(point: CGPoint(x: Double(Int32.max) + 1, y: 0)) == nil)
    }
}
