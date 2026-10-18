import Foundation
import Testing
@testable import Chunksee

@Suite struct CountedTextTests {
    @Test func heartsUseDisplayedPrecisionAndMaximumAgreementWithoutChangingGaugeData() {
        let english = Locale(identifier: "en_US")
        for (health, maximum, expected) in [
            (2.0, 2.0, "1 of 1 heart"), (0, 2, "0 of 1 heart"), (2, 4, "1 of 2 hearts"),
            (1, 2.5, "0.5 of 1.25 hearts"), (19.5, 40, "9.75 of 20 hearts"),
        ] {
            let reading = HealthPresentation(health: health, maximum: maximum)
            #expect(reading.text(locale: english) == expected)
            #expect(reading.health == health && reading.maximum == maximum)
            #expect(reading.gaugeValue == min(health, maximum))
        }
        #expect(HealthPresentation(health: 2, maximum: nil).text(locale: english) == "1 heart")
        #expect(HealthPresentation(health: nil, maximum: 2).text(locale: english) == "1 heart")
        #expect(HealthPresentation.hearts(1.998, locale: english) == "1 heart")
        #expect(HealthPresentation.hearts(2.5, locale: english) == "1.25 hearts")
    }

    @Test func rulerUnitsAndLocaleUseTheSameNativePrecision() {
        let english = Locale(identifier: "en_US")
        for (distance, expected) in [(0.0, "0 blocks"), (1, "1 block"), (1.004, "1 block"), (sqrt(2), "1.41 blocks"), (1234.5, "1,234.5 blocks")] {
            #expect(CountedText.blocks(distance, locale: english) == expected)
        }
        let french = Locale(identifier: "fr_FR"), arabic = Locale(identifier: "ar_EG")
        #expect(CountedText.hearts(1, locale: french) == "1 heart")
        #expect(CountedText.hearts(1.25, locale: french) == "1,25 hearts")
        #expect(CountedText.hearts(1, of: 2, locale: french) == "1 of 2 hearts")
        #expect(CountedText.hearts(1, locale: arabic) == "١ heart")
        #expect(CountedText.blocks(1234.5, locale: arabic) == "١٬٢٣٤٫٥ blocks")
    }
}
