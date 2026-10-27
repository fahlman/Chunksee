import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct GameTextTests {
    // Expected values were read from Minecraft's TranslatableContents in the installed 26.3
    // jar (SHA-1 e877b6a07acd633fb3bb475002175cec036e7b87), using synthetic strings only.
    // Reproduction and all raw output: advancement-title-names-evidence/text-probe-2.
    @Test func translatedComponentsFollowMinecraftSubstitutions() throws {
        let cases: [(id: String, json: String, expected: String)] = [
            ("literal", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"Plain title\",\"with\":[]}", "Plain title"),
            ("empty", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"\",\"with\":[]}", ""),
            ("single", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"Hello %s\",\"with\":[\"world\"]}", "Hello world"),
            ("indexed", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%2$s then %1$s\",\"with\":[\"first\",\"second\"]}", "second then first"),
            ("mixed", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%2$s / %s / %s\",\"with\":[\"A\",\"B\"]}", "B / A / B"),
            ("percent", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"100%% complete\",\"with\":[]}", "100% complete"),
            ("repeated", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%1$s %1$s\",\"with\":[\"A\"]}", "A A"),
            ("unicode", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"Café %s 🐈\",\"with\":[\"森\"]}", "Café 森 🐈"),
            ("boolean", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%s and %s\",\"with\":[true,false]}", "true and false"),
            ("number", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%s / %s\",\"with\":[1,1.5]}", "1.0 / 1.5"),
            ("nested", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"[%s]\",\"with\":[{\"translate\":\"chunksee.probe.inner\",\"fallback\":\"inner %s\",\"with\":[\"value\"]}]}", "[inner value]"),
            ("missing", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"Hello %s\",\"with\":[]}", "Hello %s"),
            ("out-of-range", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%2$s\",\"with\":[\"A\"]}", "%2$s"),
            ("zero", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%0$s\",\"with\":[\"A\"]}", "%0$s"),
            ("overflow", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%2147483648$s\",\"with\":[\"A\"]}", "%2147483648$s"),
            ("negative", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%-1$s\",\"with\":[\"A\"]}", "%-1$s"),
            ("uppercase", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%S\",\"with\":[\"A\"]}", "%S"),
            ("integer", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%d\",\"with\":[1]}", "%d"),
            ("dangling", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"text %\",\"with\":[]}", "text %"),
            ("decimal", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%1.2f\",\"with\":[1.5]}", "%1.2f"),
            ("numbered-percent", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%1$%\",\"with\":[]}", "%1$%"),
            ("leading-zero", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%01$s\",\"with\":[\"A\"]}", "A"),
            ("invalid-middle", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"%s then %q\",\"with\":[\"A\"]}", "%s then %q"),
            ("unused", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"Plain title\",\"with\":[\"unused\"]}", "Plain title"),
            ("empty-argument", "{\"translate\":\"chunksee.probe.missing\",\"fallback\":\"a%sb\",\"with\":[\"\"]}", "ab"),
        ]
        for fixture in cases {
            let title = try #require(TextComponent.content(json: Data(fixture.json.utf8)))
            #expect(GameNames().advancement("test:title", title: title) == fixture.expected, "\(fixture.id)")
        }
    }

    @Test func numericArgumentsFollowMinecraftDoubleText() throws {
        let cases: [(number: String, expected: String)] = [
            ("0.0", "0.0"),
            ("-0.0", "-0.0"),
            ("1", "1.0"),
            ("-1", "-1.0"),
            ("0.1", "0.1"),
            ("0.001", "0.001"),
            ("0.0009999999999999998", "9.999999999999998E-4"),
            ("0.0001", "1.0E-4"),
            ("9999999", "9999999.0"),
            ("10000000", "1.0E7"),
            ("10000000.000000002", "1.0000000000000002E7"),
            ("1e20", "1.0E20"),
            ("1e23", "1.0E23"),
            ("1.2345678901234567", "1.2345678901234567"),
            ("1.7976931348623157e308", "1.7976931348623157E308"),
            ("2.2250738585072014e-308", "2.2250738585072014E-308"),
            ("4.9e-324", "4.9E-324"),
            ("1e-323", "9.9E-324"),
            ("1.5e-323", "1.5E-323"),
            ("2e-323", "2.0E-323"),
            ("-4.9e-324", "-4.9E-324"),
            ("3.141592653589793", "3.141592653589793"),
            ("9007199254740991", "9.007199254740991E15"),
            ("9007199254740992", "9.007199254740992E15"),
            ("1.2345e-100", "1.2345E-100"),
            ("-1.2345e100", "-1.2345E100"),
        ]
        for fixture in cases {
            let number = try #require(Double(fixture.number))
            let direct = TextComponent.Content.translated(key: "test.number", fallback: "%s", arguments: [.number(number)])
            #expect(GameNames().advancement("test:title", title: direct) == fixture.expected, "Direct value: \(fixture.number)")
            let json = "{\"translate\":\"test.number\",\"fallback\":\"%s\",\"with\":[" + fixture.number + "]}"
            let title = try #require(TextComponent.content(json: Data(json.utf8)))
            #expect(GameNames().advancement("test:title", title: title) == fixture.expected, "\(fixture.number)")
        }
    }

    @Test func literalEmptySequenceAndMissingTranslationsKeepTheirMeaning() throws {
        let json = #"[{"text":"First ","extra":[{"translate":"missing.key","fallback":"fallback %s","with":["value"]}]},{"text":" / "},{"translate":"another.key"}]"#
        let title = try #require(TextComponent.content(json: Data(json.utf8)))
        #expect(GameNames().advancement("test:title", title: title) == "First fallback value / another.key")
        #expect(GameNames().advancement("test:title", title: .literal("")) == "")
        #expect(GameNames().advancement("test:missing_title") == "Missing Title")
    }

    @Test func validMaximumDepthRendersAndExpansionStopsAtItsBudget() throws {
        var json: Any = "End"
        for _ in 0..<63 { json = ["text": "", "extra": [json]] }
        let title = try #require(TextComponent.content(json: JSONSerialization.data(withJSONObject: json)))
        #expect(GameNames().advancement("test:title", title: title) == "End")

        // A tiny component can multiply its nested argument exponentially.
        var repeated: TextComponent.Content = .literal("x")
        for _ in 0..<20 {
            repeated = .translated(key: "test.repeated", fallback: "%1$s%1$s", arguments: [.component(repeated)])
        }
        #expect(GameNames().advancement("test:title", title: repeated) == "Title")
        let large = String(repeating: "x", count: 1024 * 1024)
        let expanded = TextComponent.Content.translated(key: "test.large", fallback: String(repeating: "%1$s", count: 17),
            arguments: [.string(large)])
        #expect(GameNames().advancement("test:title", title: expanded) == "Title")
    }
}
