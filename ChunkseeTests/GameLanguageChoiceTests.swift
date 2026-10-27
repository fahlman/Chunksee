import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct GameLanguageChoiceTests {
    private func game() throws -> ItemPictureFixture {
        // These declarations are data from the game's language files, including filenames
        // whose apparent language, region or script differs from the actual translation.
        let declarations = [
            "en_us": "en_us", "en_gb": "eng_GB", "en_pt": "qpe", "en_ud": "eng-Qabs_AU",
            "fr_fr": "fra_FR", "fr_ca": "fra_CA", "fra_de": "vmf_DE",
            "de_de": "deu_DE", "de_at": "bar_AT", "es_es": "spa_ES", "es_mx": "spa_MX",
            "sr_cs": "srp-Latn_RS", "sr_sp": "srp-Cyrl_RS", "no_no": "nob_NO",
            "zh_cn": "zho-Hans_CN", "zh_tw": "zho-Hant_TW",
        ]
        var files = declarations.reduce(into: [String: Data]()) { files, entry in
            var values = ["language.code": entry.value, "test.name": entry.key]
            if entry.key == "en_us" { values["test.fallback"] = "English fallback" }
            files["assets/minecraft/lang/\(entry.key).json"] = ItemPictureFixture.json(values)
        }
        files["assets/minecraft/lang/fr_at.json"] = ItemPictureFixture.json(["test.name": "Missing identity"])
        return try ItemPictureFixture(extraFiles: files)
    }

    @Test func regionalAndScriptPreferencesUseInstalledGameTranslations() async throws {
        let game = try game()
        defer { game.remove() }
        let library = try game.library()
        for (preference, expected) in [
            ("de-DE", "de_de"), ("de-US", "de_de"), ("de-AT", "de_de"),
            ("es-US", "es_mx"), ("es-419", "es_mx"), ("es-ES", "es_es"),
            ("zh-Hans-CN", "zh_cn"), ("zh-Hant-TW", "zh_tw"),
            ("sr-Cyrl-RS", "sr_sp"), ("sr-Latn-RS", "sr_cs"), ("nb-NO", "no_no"),
            ("fr-DE", "fr_fr"), ("fr-AT", "fr_fr"), ("fr-CA", "fr_ca"),
            ("ja-JP", "en_us"),
        ] {
            let names = await library.language(preference, minecraftDirectory: game.root)
            #expect(names?["test.name"] == expected, "Preference: \(preference)")
            #expect(names?["test.fallback"] == "English fallback")
        }
        let english = await library.language("en-PT", minecraftDirectory: game.root)
        #expect(["en_us", "en_gb"].contains(english?["test.name"] ?? ""))
        await library.close()
        #expect(await library.language("de-DE", minecraftDirectory: game.root) == nil)
    }

    @Test func sameLanguageChoiceDoesNotDependOnFileOrder() throws {
        let game = try game()
        defer { game.remove() }
        let assets = try #require(try GameAssets(contentsOf: game.jar)), choices = assets.languageCodes()
        for preference in ["es-US", "es-419", "de-US", "zh-Hans", "zh-Hant", "en-PT", "fr-DE", "sr-Cyrl-RS"] {
            let first = GameLanguageChoice.language(for: preference, available: choices) { assets.language($0) }
            let reversed = GameLanguageChoice.language(for: preference, available: Array(choices.reversed())) { assets.language($0) }
            #expect(first == reversed)
        }
    }

    @Test func anExactDeclaredMatchReadsOnlyThatLanguage() throws {
        let game = try game()
        defer { game.remove() }
        let assets = try #require(try GameAssets(contentsOf: game.jar))
        var reads: [String] = []
        let names = GameLanguageChoice.language(for: "fr-FR", available: assets.languageCodes()) {
            reads.append($0)
            return assets.language($0)
        }
        #expect(names?["test.name"] == "fr_fr")
        #expect(reads == ["fr_fr"])
    }

    @Test func anAbsentDeclarationDoesNotBecomeEnglishByInheritance() throws {
        let game = try game()
        defer { game.remove() }
        let assets = try #require(try GameAssets(contentsOf: game.jar))
        let names = GameLanguageChoice.language(for: "fr-AT", available: ["en_us", "fr_at"]) { assets.language($0) }
        #expect(names?["test.name"] == "en_us")
        #expect(GameLanguageChoice.language(for: "fr-FR", available: assets.languageCodes()) { _ in nil } == nil)
    }
}
