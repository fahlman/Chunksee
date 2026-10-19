import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct CountLabelTests {
    @Test func catalogPluralizesBiomeAreasAndBlockDepositsOnTheirProductionPaths() throws {
        for count in [1, 2, 1234] {
            let number = count.formatted(.number)
            let areas = BiomeScanner.areas(from: Dictionary(uniqueKeysWithValues: (0..<count).map {
                (ChunkPosition(x: $0, z: 0), "minecraft:plains")
            }))
            #expect(areas.count == 1)
            #expect(areas.first?.name == "\(number) \(count == 1 ? "chunk" : "chunks")")
            let index = SearchIndex.overworld(DimensionIndex(blocks: [
                ChunkDeposit(chunk: ChunkPosition(x: 0, z: 0),
                             deposit: BlockDeposit(block: .diamond, count: count, minY: -64, maxY: -49)),
            ]))
            let hits = WorldSearch.search("block:diamond", in: index, players: []) { _ in .named("") }
            #expect(hits.first?.detail == "\(number) \(count == 1 ? "block" : "blocks") · Y -64 to -49")
        }
    }

    @Test func storageCountsVaryIndependentlyAndKeepNativeGrouping() {
        let locale = Locale(identifier: "en_US")
        let cases: [(Int, Int, String)] = [
            (0, 0, "0 kinds of items in 0 containers"),
            (1, 1, "1 kind of item in 1 container"),
            (1, 2, "1 kind of item in 2 containers"),
            (2, 1, "2 kinds of items in 1 container"),
            (2, 2, "2 kinds of items in 2 containers"),
            (1234, 9876, "1,234 kinds of items in 9,876 containers"),
        ]
        for (kinds, containers, expected) in cases {
            #expect(StorageText.summary(kinds: kinds, containers: containers, locale: locale) == expected)
        }
    }
}
