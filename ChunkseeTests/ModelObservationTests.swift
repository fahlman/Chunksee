import ChunkseeKit
import Foundation
import Observation
@testable import ChunkseeTestHost
import Testing

@Suite(.isolatedStores, .timeLimit(.minutes(1)))
struct ModelObservationTests {
    @Observable final class Input {
        var primary = 0
        var alternate = 0
        var usesAlternate = false
        var probe = 0
        var selected: Int { usesAlternate ? alternate : primary }
    }

    final class Consumer {
        let input: Input
        var isActive = true
        var previous: [Int] = []
        var values: [Int] = []
        var onDelivery: ((Consumer) -> Void)?
        var observation: ModelObservation?

        init(_ input: Input) {
            self.input = input
            observation = ModelObservation(self, isActive: { $0.isActive }, read: { $0.input.selected }) {
                consumer, previous in
                consumer.previous.append(previous)
                consumer.values.append(consumer.input.selected)
                consumer.onDelivery?(consumer)
            }
        }
    }

    final class Count { var value = 0 }

    @Test func eachChangePublishesBeforeTheSetterReturns() {
        let input = Input()
        let current = Consumer(input)
        #expect(current.values.isEmpty)
        input.primary = 1
        #expect(current.previous == [0] && current.values == [1])
        input.primary = 2
        #expect(current.previous == [0, 1] && current.values == [1, 2])
    }

    @Test func followsTheCurrentDependenciesOnly() {
        let input = Input(), consumer = Consumer(input)
        input.alternate = 3
        #expect(consumer.values.isEmpty)
        input.usesAlternate = true
        #expect(consumer.values == [3])
        input.primary = 7
        #expect(consumer.values == [3])
        input.alternate = 4
        #expect(consumer.values == [3, 4])
    }

    @Test func changesInsideAReactionAreObservedSynchronously() {
        let input = Input(), consumer = Consumer(input)
        consumer.onDelivery = { consumer in
            if consumer.input.primary == 1 { consumer.input.primary = 2 }
        }
        input.primary = 1
        #expect(consumer.previous == [0, 1] && consumer.values == [1, 2])
        input.primary = 3
        #expect(consumer.previous == [0, 1, 2] && consumer.values == [1, 2, 3])
    }

    @Test func cancellationInsideAReactionStopsLaterDelivery() {
        let input = Input(), consumer = Consumer(input)
        consumer.onDelivery = { consumer in
            consumer.observation?.cancel()
            consumer.input.primary = 2
        }
        input.primary = 1
        input.primary = 3
        #expect(consumer.values == [1])
    }

    @Test func anInactiveOwnerCannotResumeObservation() {
        let input = Input()
        let consumer = Consumer(input)
        consumer.isActive = false
        input.primary = 1
        consumer.isActive = true
        input.primary = 2
        #expect(consumer.values.isEmpty)
    }

    @Test func aRetainedObservationDoesNotKeepItsOwnerAlive() {
        let input = Input()
        var consumer: Consumer? = Consumer(input)
        weak var weakConsumer = consumer
        let observation = consumer?.observation
        consumer = nil
        #expect(weakConsumer == nil)
        input.primary = 1
        withExtendedLifetime(observation) {}
    }

    @Test func nestedPublicationsDoNotMultiplySubscriptions() {
        let input = Input(), count = Count()
        let derived = ModelObservation(input, isActive: { _ in true }, read: { $0.primary }) { input, _ in
            input.alternate = input.primary
        }
        let consumer = ModelObservation(count, isActive: { _ in true }, read: { _ in
            _ = input.primary
            _ = input.alternate
            _ = input.probe
        }) { count, _ in count.value += 1 }
        for value in 1...10 { input.primary = value }
        // Either delivery order is valid: the consumer can see one or both publications.
        #expect(count.value >= 10 && count.value <= 20)
        let before = count.value
        input.probe += 1
        #expect(count.value == before + 1)
        withExtendedLifetime((derived, consumer)) {}
    }

    @Test func querySourceWorkStaysBoundedAfterNestedReplacement() async {
        let defaults = TestDefaults.make(), work = BackgroundWork(), input = Input(), reads = Count()
        let names = PlayerNames(defaults: defaults), saved = SavedSearches(defaults: defaults)
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: PlayerRoster([]))
        let derived = ModelObservation(input, isActive: { _ in true }, read: { $0.primary }) { input, _ in
            input.alternate = input.primary
        }
        let store = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: {
                _ = input.primary
                _ = input.alternate
                _ = input.probe
                reads.value += 1
                return .unavailable
            })
        reads.value = 0
        input.probe += 1
        let singleChange = reads.value
        #expect(singleChange > 0)
        for value in 1...10 { input.primary = value }
        reads.value = 0
        input.probe += 1
        #expect(reads.value == singleChange)
        store.close(); index.cancel(); work.close()
        await work.waitUntilFinished()
        withExtendedLifetime(derived) {}
    }

    @Test func playerSourceWorkStaysBoundedAfterNestedReplacement() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let work = BackgroundWork(), input = Input(), reads = Count(), generation = UUID()
        let derived = ModelObservation(input, isActive: { _ in true }, read: { $0.primary }) { input, _ in
            input.alternate = input.primary
        }
        let store = PlayerRecordStore(world: WorldReadSource(try World(contentsOf: root)), work: work,
            names: PlayerNames(defaults: TestDefaults.make()), gameSource: {
                _ = input.primary
                _ = input.alternate
                _ = input.probe
                reads.value += 1
                return WorldGameDataSource(generation: generation, selection: .loading)
            })
        let handle = try #require(store.acquire(UUID()))
        reads.value = 0
        input.probe += 1
        let singleChange = reads.value
        #expect(singleChange > 0)
        for value in 1...10 { input.primary = value }
        reads.value = 0
        input.probe += 1
        #expect(reads.value == singleChange)
        handle.close(); store.close(); work.close()
        await work.waitUntilFinished()
        withExtendedLifetime(derived) {}
    }
}
