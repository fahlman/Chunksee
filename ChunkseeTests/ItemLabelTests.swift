import ChunkseeKit
import ChunkseeIndex
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ItemLabelTests {
    func item(_ id: String, count: Int32 = 1, name: String? = nil, extra: [String: NBT] = [:]) -> NBT {
        var components = extra
        if let name { components["minecraft:custom_name"] = .string(name) }
        return .compound(["id": .string(id), "count": .int(count), "components": .compound(components)])
    }

    @Test func searchKeepsKindsNamesAndContainerContext() throws {
        let container = NBT.compound([
            "id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
            "CustomName": .string("Supplies"), "Items": .list([
                item("minecraft:diamond", count: 2, name: "Keepsake"),
                item("minecraft:diamond", count: 3, name: "Keepsake"),
                item("minecraft:emerald", name: "Keepsake"),
            ]),
        ])
        let index = SearchIndex.overworld(DimensionContent(containers: ItemContainer.containers(inChunk: .compound([
            "block_entities": .list([container]),
        ]))))
        let hit = try #require(WorldSearch.search("keepsake", in: index, players: []) { _ in .named("") }.first)
        #expect(hit.title == "Chest “Supplies”")
        #expect(hit.detail == "5 Diamond “Keepsake”, 1 Emerald “Keepsake”")
        #expect(hit.count == 6)
        let diamond = try #require(ItemStack(item("minecraft:diamond", name: "Keepsake")))
        #expect(ItemAppearance.name(of: diamond) == "Diamond “Keepsake”")
        #expect(TradeText.describe(diamond) == "1 Diamond “Keepsake”")
    }

    @Test func summariesKeepDistinctNamespacedKindsAndUseLocalizedCounts() throws {
        let apples = [ItemStack(id: "first:apple", count: 2), ItemStack(id: "second:apple", count: 3)]
        #expect(WorldSearch.summary(of: apples, query: SearchQuery("apple"))?.text == "3 Apple, 2 Apple")
        #expect(WorldSearch.summary(of: apples, query: SearchQuery("first:apple"))?.count == 2)
        let plain = ItemStack(id: "minecraft:diamond", count: 1234)
        let style = ItemAppearance.LabelStyle()
        #expect(style.locale(Locale(identifier: "en_US")).format(plain) == "1,234 Diamond")
        #expect(style.locale(Locale(identifier: "fr_FR")).format(plain) == "1\u{202f}234 Diamond")
        #expect(style.locale(Locale(identifier: "ar_EG")).format(plain) == "١٬٢٣٤ Diamond")
    }

    @Test func tradeSearchFindsCustomNamesOnEveryCostAndRetainsEnchantments() throws {
        let creature = try #require(Creature(.compound([
            "id": .string("minecraft:villager"), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]),
            "VillagerData": .compound(["profession": .string("minecraft:weaponsmith"), "level": .int(5)]),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": item("minecraft:emerald", count: 24, name: "Token"),
                "buyB": item("minecraft:book", name: "Voucher"),
                "sell": item("minecraft:diamond_sword", name: "Excalibur", extra: [
                    "minecraft:enchantments": .compound(["minecraft:sharpness": .int(5)]),
                ]),
            ])])]),
        ])))
        let marker = try #require(CreatureMarker(creature, dimension: "minecraft:overworld"))
        let index = SearchIndex.overworld(DimensionContent(creaturePoints: PointMarkers([marker])))
        for word in ["token", "voucher", "excalibur", "sharpness", "diamond sword"] {
            let hit = try #require(WorldSearch.search("trade:\(word)", in: index, players: []) { _ in .named("") }.first)
            #expect(hit.detail == "1 Diamond Sword “Excalibur” (Sharpness V) for 24 Emerald “Token” + 1 Book “Voucher”")
        }
    }

    @Test(arguments: [false, true])
    func offersKeepBothCostsAndMakeSoldOutTradesExplicit(soldOut: Bool) throws {
        let trade = try #require(Trade(.compound([
            "buy": item("minecraft:emerald", count: 24, name: "Token"),
            "buyB": item("minecraft:book", name: "Voucher"),
            "sell": item("minecraft:enchanted_book", extra: [
                "minecraft:stored_enchantments": .compound(["minecraft:mending": .int(1)]),
            ]),
            "uses": .int(soldOut ? 12 : 0), "maxUses": .int(12),
        ])))
        let offer = "1 Enchanted Book (Mending) for 24 Emerald “Token” + 1 Book “Voucher”"
        #expect(TradeText.offer(trade) == offer + (soldOut ? " (sold out)" : ""))
    }

    @Test func writtenBookKeepsKindTitleAuthorAndBodySearch() throws {
        let savedBook = item("minecraft:written_book", extra: ["minecraft:written_book_content": .compound([
            "title": .string("Travels"), "author": .string("Writer"), "pages": .list([.string("A desert village")]),
        ])])
        let book = try #require(ItemStack(savedBook))
        #expect(ItemAppearance.name(of: book) == "Written Book “Travels” by Writer")
        #expect(WorldSearch.summary(of: [book], query: SearchQuery("desert village"))?.text == "1 Written Book “Travels” by Writer")
        let trade = try #require(Trade(.compound(["buy": item("minecraft:emerald"), "sell": savedBook])))
        #expect(TradeText.searchText(of: trade).contains("Travels"))
        var renamed = book
        renamed.customName = "Keepsake"
        #expect(ItemAppearance.label(of: renamed) == "Written Book “Keepsake”")
        #expect(WorldSearch.matches(renamed, query: SearchQuery("travels")))
    }
}
