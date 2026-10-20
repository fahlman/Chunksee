import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct CountedTextTests {
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
            #expect(distance.formatted(CountedText.blocks.locale(english)) == expected)
        }
        let french = Locale(identifier: "fr_FR"), arabic = Locale(identifier: "ar_EG")
        #expect(1.0.formatted(CountedText.hearts.locale(french)) == "1 heart")
        #expect(1.25.formatted(CountedText.hearts.locale(french)) == "1,25 hearts")
        #expect(1.0.formatted(CountedText.hearts(of: 2).locale(french)) == "1 of 2 hearts")
        #expect(1.0.formatted(CountedText.hearts.locale(arabic)) == "١ heart")
        #expect(1234.5.formatted(CountedText.blocks.locale(arabic)) == "١٬٢٣٤٫٥ blocks")
    }

    @Test func hungerLabelAndGaugeUseTheSameFoodMaximumAndHalfUnits() {
        let english = Locale(identifier: "en_US")
        for (food, value, fill, expected) in [
            (0, 0.0, 0.0, "0 of 10 drumsticks"),
            (1, 0.5, 0.05, "0.5 of 10 drumsticks"),
            (17, 8.5, 0.85, "8.5 of 10 drumsticks"),
            (20, 10.0, 1.0, "10 of 10 drumsticks"),
            (24, 12.0, 1.0, "12 of 10 drumsticks"),
        ] {
            let reading = HungerPresentation(food: food)
            #expect(reading.value == value)
            #expect(reading.maximum == 10)
            #expect(reading.gaugeValue / reading.maximum == fill)
            #expect(reading.value.formatted(CountedText.hunger(of: reading.maximum).locale(english)) == expected)
        }
        #expect(0.0.formatted(CountedText.hunger(of: 1).locale(english)) == "0 of 1 drumstick")
        #expect(1.0.formatted(CountedText.hunger(of: 2).locale(english)) == "1 of 2 drumsticks")
        #expect(8.5.formatted(CountedText.hunger(of: 10).locale(Locale(identifier: "fr_FR"))) == "8,5 of 10 drumsticks")
    }
}
