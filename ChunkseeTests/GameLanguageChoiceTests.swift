import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct GameLanguageChoiceTests {
    @Test func regionalAndScriptPreferencesUseInstalledGameTranslations() async throws {
        let game = try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json(["test.name": "English", "test.fallback": "English fallback"]),
            "assets/minecraft/lang/de_de.json": ItemPictureFixture.json(["test.name": "Deutsch"]),
            "assets/minecraft/lang/es_es.json": ItemPictureFixture.json(["test.name": "Español"]),
            "assets/minecraft/lang/zh_cn.json": ItemPictureFixture.json(["test.name": "简体中文"]),
            "assets/minecraft/lang/zh_tw.json": ItemPictureFixture.json(["test.name": "繁體中文"]),
        ])
        defer { game.remove() }
        let library = try game.library()
        for (preference, expected) in [
            ("de-DE", "Deutsch"), ("de-US", "Deutsch"),
            ("es-US", "Español"), ("es-419", "Español"),
            ("zh-Hans-CN", "简体中文"), ("zh-Hant-TW", "繁體中文"),
            ("ja-JP", "English"),
        ] {
            let names = await library.language(preference, minecraftDirectory: game.root)
            #expect(names?["test.name"] == expected, "Preference: \(preference)")
            #expect(names?["test.fallback"] == "English fallback")
        }
        await library.close()
        #expect(await library.language("de-DE", minecraftDirectory: game.root) == nil)
    }

    @Test func sameLanguageChoiceDoesNotDependOnFileOrder() {
        let choices = ["es_mx", "en_us", "es_es", "de_de", "zh_tw", "zh_cn"]
        for preference in ["es-US", "es-419", "de-US", "zh-Hans", "zh-Hant"] {
            let code = GameLanguageChoice.code(for: preference, available: choices)
            #expect(code == GameLanguageChoice.code(for: preference, available: Array(choices.reversed())))
            #expect(code != "en_us")
        }
        #expect(GameLanguageChoice.code(for: "es-MX", available: choices) == "es_mx")
        #expect(GameLanguageChoice.code(for: "zh-Hans", available: choices) == "zh_cn")
        #expect(GameLanguageChoice.code(for: "zh-Hant", available: choices) == "zh_tw")
        #expect(GameLanguageChoice.code(for: "ja-JP", available: choices) == "en_us")
        #expect(GameLanguageChoice.code(for: "de-DE", available: []) == "en_us")
    }
}
