import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameSearchNamesTests {
    @Test func theSameSearchFactsUseExplicitNamesAcrossLabelsAndMapAccessibility() async throws {
        let english = try await EnchantmentNameFixture.names(), french = try await EnchantmentNameFixture.names("fr_FR")
        let containers = ItemContainer.containers(inChunk: .compound(["block_entities": .list([
            .compound(["id": .string("test:box"), "x": .int(-2), "y": .int(64), "z": .int(3),
                "CustomName": .string("Supplies"),
                "Items": .list([ItemLabelTests().item("test:token", count: 7, name: "Kept literally")])]),
        ])]))
        let index = SearchIndex.overworld(DimensionContent(containers: containers))
        let hit = try #require(WorldSearch.search("test:token", in: index, players: [], gameNames: english) { _ in .named("") }.first)
        let translated = try #require(WorldSearch.search("jeton", in: index, players: [], gameNames: french) { _ in .named("") }.first)
        #expect(hit == translated)
        #expect(hit.source == .container(kind: "test:box") && hit.count == 7)
        #expect(hit.items.first?.id == "test:token" && hit.items.first?.name.customName == "Kept literally")
        #expect(hit.title(in: english) == "Pack Box “Supplies”")
        #expect(hit.detail(in: english) == "7 Trade Token “Kept literally”")
        #expect(hit.detail(in: french) == "7 Jeton “Kept literally”")
        #expect(hit.items.first?.text(in: french) == hit.detail(in: french))

        let position = try #require(hit.position), viewport = MapViewport(center: position, scale: 8)
        let size = CGSize(width: 400, height: 200)
        var before = MapContent(gameNames: english), after = MapContent(gameNames: french)
        before.hits = [hit]; after.hits = [hit]
        let old = try #require(before.accessibleLocations(viewport: viewport, size: size).first)
        let current = try #require(after.accessibleLocations(viewport: viewport, size: size).first)
        #expect(old.name == "Pack Box “Supplies”, 7 Trade Token “Kept literally”")
        #expect(current.name == "Pack Box “Supplies”, 7 Jeton “Kept literally”")
        #expect(old.id == current.id && old.target == current.target && old.position == current.position && old.y == current.y)
        #expect(old.frame == current.frame)
        #expect(before.hit(at: CGPoint(x: 200, y: 100), viewport: viewport, size: size)?.target
            == after.hit(at: CGPoint(x: 200, y: 100), viewport: viewport, size: size)?.target)
        #expect(before.accessibleLocations(viewport: viewport, size: size).first?.name == old.name)
    }

    @Test func summariesKeepVisibleLabelGroupingDistinctIDsNestedCountsAndZeroMatches() throws {
        let book = try #require(ItemStack(ItemLabelTests().item("minecraft:written_book", count: 2, extra: [
            "minecraft:written_book_content": .compound([
                "title": .string("Field Notes"), "pages": .list([.string("Unrelated body text")]),
            ]),
        ])))
        let renamed = ItemStack(id: book.id, count: 3, customName: "Field Notes")
        let other = ItemStack(id: "test:written_book", count: 4, customName: "Field Notes")
        let zero = ItemStack(id: "test:zero", count: 0, customName: "Field Notes")
        let nested = ItemStack(id: "minecraft:bundle", contents: [renamed])
        let found = try #require(WorldSearch.summary(of: [book, nested, other, zero], query: SearchQuery("field notes"), gameNames: .unavailable))
        #expect(found.items.map(\.id) == [book.id, other.id, zero.id])
        #expect(found.items.map(\.count) == [5, 4, 0] && found.count == 9)
        #expect(found.text(in: .unavailable) == "5 Written Book “Field Notes”, 4 Written Book “Field Notes”, 0 Zero “Field Notes”")
        let zeroOnly = try #require(WorldSearch.summary(of: [zero], query: SearchQuery("field notes"), gameNames: .unavailable))
        #expect(zeroOnly.count == 0 && zeroOnly.items.count == 1)
        let hit = SearchHit(id: "zero", dimension: nil, position: nil, y: nil,
            content: .container(kind: "minecraft:chest", customName: nil, items: zeroOnly.items))
        #expect(hit.count == 0 && hit.detail(in: .unavailable) == "0 Zero “Field Notes”")
    }

    @Test func repeatedItemsKeepTheirNamesCountsAndEachSearchLanguage() async throws {
        let english = try await EnchantmentNameFixture.names(), french = try await EnchantmentNameFixture.names("fr_FR")
        let saved = ItemLabelTests()
        let containers = ItemContainer.containers(inChunk: .compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
                "Items": .list([
                    saved.item("test:token", count: 2),
                    saved.item("test:token", count: 3, name: "Morning"),
                    saved.item("test:token", count: 4, name: "Morning"),
                    saved.item("test:token", count: 5, name: "Evening"),
                ])]),
            .compound(["id": .string("minecraft:chest"), "x": .int(1), "y": .int(64), "z": .int(0),
                "Items": .list([
                    saved.item("test:token", count: 17),
                    saved.item("test:token", count: 19, name: "Morning"),
                    saved.item("test:token", count: 23, name: "Evening"),
                ])]),
        ])]))
        let index = SearchIndex.overworld(DimensionContent(containers: containers))
        func search(_ text: String, _ names: GameNames) -> [SearchHit] {
            WorldSearch.search(text, in: index, players: [], gameNames: names) { _ in .named("") }
        }

        let first = search("trade token", english), translated = search("jeton", french)
        #expect(first == translated && search("trade token", english) == first)
        #expect(first.map(\.count) == [59, 14])
        #expect(first.map { $0.items.map(\.count) } == [[23, 19, 17], [7, 5, 2]])
        #expect(first.first?.detail(in: english) == "23 Trade Token “Evening”, 19 Trade Token “Morning”, 17 Trade Token")
        #expect(translated.first?.detail(in: french) == "23 Jeton “Evening”, 19 Jeton “Morning”, 17 Jeton")
        #expect(search("jeton", english).isEmpty && search("trade token", french).isEmpty)
        #expect(search("test:token", french) == translated)
        let evening = search("test:token evening", french)
        #expect(evening.map(\.count) == [23, 5])
        #expect(evening.allSatisfy { $0.items.map(\.name.customName) == ["Evening"] })
    }

    @Test func repeatedBookLabelsKeepAuthorsTitlesAndPerStackPageMatches() throws {
        func book(_ count: Int32, title: String, author: String, page: String) -> NBT {
            ItemLabelTests().item("minecraft:written_book", count: count, extra: [
                "minecraft:written_book_content": .compound([
                    "title": .string(title), "author": .string(author), "pages": .list([.string(page)]),
                ]),
            ])
        }
        let containers = ItemContainer.containers(inChunk: .compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
                "Items": .list([
                    book(7, title: "Field Notes", author: "Ada", page: "desert"),
                    book(11, title: "Field Notes", author: "Ada", page: "forest"),
                    book(13, title: "Field Notes", author: "Bea", page: "desert"),
                    book(17, title: "Other Notes", author: "Ada", page: "mountain"),
                ])]),
        ])]))
        let index = SearchIndex.overworld(DimensionContent(containers: containers))
        func search(_ text: String) -> [SearchHit] {
            WorldSearch.search(text, in: index, players: [], gameNames: .unavailable) { _ in .named("") }
        }

        #expect(search("forest").map(\.count) == [11])
        #expect(search("desert").map(\.count) == [20])
        #expect(search("mountain").map(\.count) == [17])
        #expect(search("other notes").map(\.count) == [17])
        let field = try #require(search("field notes").first)
        #expect(field.count == 31)
        #expect(field.items.map { $0.text(in: .unavailable) } == [
            "18 Written Book “Field Notes” by Ada", "13 Written Book “Field Notes” by Bea",
        ])
        #expect(search("ada").map(\.count) == [35])
        #expect(search("bea").map(\.count) == [13])
    }
}
