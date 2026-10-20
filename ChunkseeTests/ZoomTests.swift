import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ZoomTests {
    @Test func percentageEntryUsesTheLocaleAndTheExistingManualLimits() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        #expect(ZoomPercentage.scale(from: "6.25", locale: english) == MapViewport.minimumManualScale)
        #expect(ZoomPercentage.scale(from: "3200", locale: english) == MapViewport.scaleRange.upperBound)
        #expect(ZoomPercentage.scale(from: " 125.5\n", locale: english) == 1.255)
        #expect(ZoomPercentage.scale(from: "125,5", locale: german) == 1.255)
        #expect(ZoomPercentage.entry(1.255, locale: english) == "125.5")
        #expect(ZoomPercentage.entry(1.255, locale: german) == "125,5")
        for scale in ZoomPercentage.levels {
            #expect(ZoomPercentage.scale(from: ZoomPercentage.entry(scale, locale: english), locale: english) == scale)
        }
    }

    @Test func invalidPercentageCannotEnterTheViewport() {
        let locale = Locale(identifier: "en_US")
        for value in ["", " ", "0", "-100", "6.24", "3200.01", "1e300", "NaN", "inf", "∞",
                      "100abc", "100 200", "100%", "--100"] {
            #expect(ZoomPercentage.scale(from: value, locale: locale) == nil, "Rejected input: \(value)")
        }
    }

    @Test func thePercentageFieldKeepsSmallFittedViewsReadable() {
        let locale = Locale(identifier: "en_US")
        #expect(ZoomPercentage.entry(MapViewport.scaleRange.lowerBound, locale: locale) == "0.000001")
        #expect(ZoomPercentage.entry(0.0000123456789, locale: locale) == "0.00123456789")
    }

}
