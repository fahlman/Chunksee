import CoreGraphics
import Testing
@testable import Chunksee

@Suite struct CoordinateNavigationTests {
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
}
