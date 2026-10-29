import Foundation
import ChunkseeKit
import Observation
import Synchronization
@testable import ChunkseeTestHost
import Testing

@Suite(.isolatedStores)
struct RefreshLoaderTests {
    @Test(.timeLimit(.minutes(1))) func producerContinuesAfterDeliveryInThePublishingTurnAndNotAfterFailure() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Result<Int, CocoaError>>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish,
                                   source: "a", initialValue: 7) { source, _ in try await gate.read(source).get() }
        let events = Mutex<[String]>([])
        loader.published = { previous, current in
            events.withLock { $0.append("producer:\(previous.source):\(previous.value.map(String.init) ?? "nil")->\(current.source):\(current.value.map(String.init) ?? "nil")") }
        }
        withObservationTracking(options: [.didSet]) { _ = loader.source } onChange: { _ in
            MainActor.assumeIsolated {
                #expect(loader.source == "b" && loader.value == nil)
                events.withLock { $0.append("replacement delivered") }
            }
        }
        loader.request(source: "b", isEnabled: false, reread: false)
        // No suspension: the producer follows delivery before request returns.
        #expect(events.withLock { $0 } == ["replacement delivered", "producer:a:7->b:nil"])
        withObservationTracking(options: [.didSet]) { _ = loader.value } onChange: { _ in
            MainActor.assumeIsolated {
                #expect(loader.source == "b" && loader.value == 8)
                events.withLock { $0.append("read delivered") }
            }
        }
        loader.request(source: "b", isEnabled: true, reread: false)
        await gate.waitForRequest("b"); await gate.finish("b", with: .success(8))
        await loader.waitUntilFinished()
        let expected = ["replacement delivered", "producer:a:7->b:nil", "read delivered", "producer:b:nil->b:8"]
        #expect(events.withLock { $0 } == expected)
        loader.request(source: "b", isEnabled: true, reread: true)
        await gate.waitForRequest("b", count: 2)
        await gate.finish("b", with: .failure(CocoaError(.fileReadUnknown)))
        await loader.waitUntilFinished()
        #expect(loader.value == 8 && events.withLock { $0 } == expected)
        loader.close()
        #expect(events.withLock { $0 } == expected)
        work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func completedReadContinuationCanReplaceOrCloseWithoutEditingNewDemand(close: Bool) async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "a") { source, _ in
            await gate.read(source + String(await numbers.next()))
        }
        loader.published = { [weak loader] _, current in
            guard current.source == "a", current.value == 1, let loader else { return }
            if close { loader.close() }
            else {
                loader.request(source: "b", isEnabled: true, reread: false)
                loader.request(source: "b", isEnabled: true, reread: true)
            }
        }
        loader.request(source: "a", isEnabled: true, reread: false)
        await gate.waitForRequest("a0")
        loader.request(source: "a", isEnabled: true, reread: true)
        await gate.finish("a0", with: 1)
        if close {
            await loader.waitUntilFinished()
            #expect(loader.isClosed && loader.value == nil)
            #expect(await gate.requested == ["a0"])
        } else {
            await gate.waitForRequest("b1"); await gate.finish("b1", with: 2)
            await gate.waitForRequest("b2"); await gate.finish("b2", with: 3)
            await loader.waitUntilFinished()
            #expect(loader.source == "b" && loader.value == 3)
            #expect(await gate.requested == ["a0", "b1", "b2"])
        }
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func sourceContinuationCanReplaceBeforeTheOldRequestStarts() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish,
                                   source: "a", initialValue: 1) { source, _ in
            await gate.read(source + String(await numbers.next()))
        }
        loader.published = { [weak loader] _, current in
            guard current.source == "b", let loader else { return }
            loader.request(source: "c", isEnabled: true, reread: false)
            loader.request(source: "c", isEnabled: true, reread: true)
        }
        loader.request(source: "b", isEnabled: true, reread: false)
        #expect(loader.source == "c" && loader.value == nil)
        await gate.waitForRequest("c0"); await gate.finish("c0", with: 2)
        await gate.waitForRequest("c1"); await gate.finish("c1", with: 3)
        await loader.waitUntilFinished()
        #expect(loader.source == "c" && loader.value == 3)
        #expect(await gate.requested == ["c0", "c1"])
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test func preparedValueIsAvailableWithoutReadingAndCloseReleasesIt() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish,
                                   source: "prepared", initialValue: 7) { _, _ in await gate.read("refresh") }
        #expect(loader.value == 7)
        loader.request(source: "prepared", isEnabled: true, reread: false)
        await loader.waitUntilFinished()
        #expect(await gate.requested.isEmpty && loader.value == 7)
        loader.request(source: "prepared", isEnabled: true, reread: true)
        await gate.waitForRequest("refresh")
        #expect(loader.value == 7)
        await gate.finish("refresh", with: 8)
        await loader.waitUntilFinished()
        #expect(loader.value == 8)
        loader.close()
        #expect(loader.value == nil)
        work.close(); await work.waitUntilFinished()
    }

    nonisolated private enum Demand: String, Equatable, Sendable {
        case metadata, contents
        func merging(_ other: Self) -> Self { self == .contents || other == .contents ? .contents : .metadata }
    }

    @Test(.timeLimit(.minutes(1))) func partialResultsPublishWithoutLosingFailedDemandOrStartingRetryLoops() async {
        let work = BackgroundWork(), gate = AsyncReadGate<RefreshRead<Int>>()
        let loader = RefreshLoader(partialRead: { _, request, _ in await gate.read(request.rawValue) },
            work: work, priority: .utility, whenInactive: .finish, source: "fixed", initialValue: 1,
            firstRequest: Demand.metadata, merge: { $0.merging($1) })
        loader.request(source: "fixed", isEnabled: true, refresh: .contents)
        await gate.waitForRequest("contents"); await gate.finish("contents", with: .partial(2))
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        #expect(await gate.requested == ["contents"])
        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        await gate.waitForRequest("contents", count: 2)
        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        await gate.finish("contents", with: .partial(3))
        await gate.waitForRequest("contents", count: 3)
        #expect(loader.value == 3)
        await gate.finish("contents", with: .complete(4))
        await loader.waitUntilFinished()
        #expect(loader.value == 4)
        #expect(await gate.requested == ["contents", "contents", "contents"])
        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        await gate.waitForRequest("metadata"); await gate.finish("metadata", with: .complete(5))
        await loader.waitUntilFinished()
        #expect(loader.value == 5)
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func partialPublicationObserversCanReplaceOrCloseWithoutLeakingRetryStrength(close: Bool) async {
        let work = BackgroundWork(), gate = AsyncReadGate<RefreshRead<Int>>()
        let loader = RefreshLoader(partialRead: { source, request, _ in await gate.read(source + request.rawValue) },
            work: work, priority: .utility, whenInactive: .finish, source: "a", initialValue: 1,
            firstRequest: Demand.metadata, merge: { $0.merging($1) })
        withObservationTracking(options: [.didSet]) { _ = loader.value } onChange: { event in
            event.cancel()
            MainActor.assumeIsolated {
                if close { loader.close() }
                else { loader.request(source: "b", isEnabled: true, refresh: .metadata) }
            }
        }
        loader.request(source: "a", isEnabled: true, refresh: .contents)
        await gate.waitForRequest("acontents"); await gate.finish("acontents", with: .partial(2))
        if close {
            await loader.waitUntilFinished()
            #expect(loader.isClosed && loader.value == nil)
            #expect(await gate.requested == ["acontents"])
        } else {
            await gate.waitForRequest("bmetadata"); await gate.finish("bmetadata", with: .complete(3))
            await loader.waitUntilFinished()
            #expect(loader.source == "b" && loader.value == 3)
            #expect(await gate.requested == ["acontents", "bmetadata"])
        }
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func typedRequestsKeepProgressAndMergeFollowingDemand() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed",
                                   firstRequest: Demand.metadata, merge: { $0.merging($1) }) { _, request, _ in
            await gate.read(request.rawValue)
        }
        loader.request(source: "fixed", isEnabled: true, refresh: nil)
        await gate.waitForRequest("metadata")
        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        loader.request(source: "fixed", isEnabled: true, refresh: .contents)
        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        await gate.finish("metadata", with: 1)
        await gate.waitForRequest("contents")
        #expect(loader.value == 1)
        #expect(await gate.requested == ["metadata", "contents"])
        await gate.finish("contents", with: 2)
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        #expect(await gate.requested == ["metadata", "contents"])
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func failedAndInterruptedRequestsKeepTheirStrengthWithoutRetryLoops() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Result<Int, CocoaError>>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .cancel, source: "fixed",
                                   firstRequest: Demand.metadata, merge: { $0.merging($1) }) { _, request, _ in
            try await gate.read(request.rawValue + String(await numbers.next())).get()
        }
        loader.request(source: "fixed", isEnabled: true, refresh: nil)
        await gate.waitForRequest("metadata0"); await gate.finish("metadata0", with: .success(1))
        await loader.waitUntilFinished()
        loader.request(source: "fixed", isEnabled: true, refresh: .contents)
        await gate.waitForRequest("contents1")
        await gate.finish("contents1", with: .failure(CocoaError(.fileReadUnknown)))
        await loader.waitUntilFinished()
        #expect(loader.value == 1)
        #expect(await gate.requested.count == 2)

        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        await gate.waitForRequest("contents2")
        loader.request(source: "fixed", isEnabled: false, refresh: nil)
        await gate.waitForCancellation("contents2")
        loader.request(source: "fixed", isEnabled: true, refresh: nil)
        await gate.waitForRequest("contents3")
        loader.request(source: "fixed", isEnabled: true, refresh: .metadata)
        await gate.finish("contents3", with: .failure(CocoaError(.fileReadUnknown)))
        await gate.waitForRequest("contents4")
        #expect(loader.value == 1)
        await gate.finish("contents4", with: .success(2))
        await gate.finish("contents2", with: .success(99))
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        #expect(await gate.requested == ["metadata0", "contents1", "contents2", "contents3", "contents4"])
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func aSourceProjectionPublishesItsSourceAndValueTogetherAndRejectsRetiredReads() async {
        let work = BackgroundWork(), gate = AsyncReadGate<String>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "on",
                                   firstRequest: RefreshInvalidation.refresh, merge: { _, _ in .refresh },
                                   retainingValue: { _, old, new in old == "on" && new == "off" ? "numeric" : nil }) { source, _, _ in
            await gate.read(source + String(await numbers.next()))
        }
        loader.request(source: "on", isEnabled: true, reread: false)
        await gate.waitForRequest("on0"); await gate.finish("on0", with: "numeric+artwork")
        await loader.waitUntilFinished()
        loader.request(source: "on", isEnabled: true, reread: true)
        await gate.waitForRequest("on1")
        let observed = Mutex(false)
        withObservationTracking(options: [.didSet]) { _ = loader.source } onChange: { _ in
            MainActor.assumeIsolated {
                #expect(loader.source == "off" && loader.value == "numeric")
                observed.withLock { $0 = true }
            }
        }
        loader.request(source: "off", isEnabled: true, reread: false)
        #expect(observed.withLock { $0 } && loader.value == "numeric")
        await gate.waitForCancellation("on1"); await gate.waitForRequest("off2")
        loader.request(source: "other", isEnabled: true, reread: false)
        #expect(loader.value == nil)
        await gate.waitForCancellation("off2"); await gate.waitForRequest("other3")
        await gate.finish("other3", with: "other")
        await gate.finish("off2", with: "retired-off")
        await gate.finish("on1", with: "retired-on")
        await loader.waitUntilFinished()
        #expect(loader.source == "other" && loader.value == "other")
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func inactiveOptionalReadCancelsAndRetainsItsPublicationUntilDemandReturns() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .cancel, source: "fixed") { _, _ in
            await gate.read(String(await numbers.next()))
        }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("0"); await gate.finish("0", with: 1)
        await loader.waitUntilFinished()
        loader.request(source: loader.source, isEnabled: true, reread: true)
        await gate.waitForRequest("1")
        loader.request(source: loader.source, isEnabled: false, reread: false)
        await gate.waitForCancellation("1")
        #expect(loader.value == 1)
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("2"); await gate.finish("2", with: 2)
        for await ready in Observations({ loader.value == 2 }) where ready { break }
        var drained = false
        var waiting: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiting = Task { started.resume(); await loader.waitUntilFinished(); drained = true }
        }
        #expect(!drained)
        await gate.finish("1", with: 99)
        await waiting?.value
        #expect(drained && loader.value == 2)
        loader.request(source: loader.source, isEnabled: false, reread: false)
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await loader.waitUntilFinished()
        #expect(await gate.requested == ["0", "1", "2"])
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func failureRetriesOnlyOnAnotherRequestAndSuccessfulEmptyIsReusable() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Result<[Int], CocoaError>>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .cancel, source: "fixed") { _, _ in
            try await gate.read("value").get()
        }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value"); await gate.finish("value", with: .success([1]))
        await loader.waitUntilFinished()
        loader.request(source: loader.source, isEnabled: true, reread: true)
        await gate.waitForRequest("value", count: 2)
        await gate.finish("value", with: .failure(CocoaError(.fileReadUnknown)))
        await loader.waitUntilFinished()
        #expect(loader.value == [1])
        #expect(await gate.requested.count == 2)
        loader.request(source: loader.source, isEnabled: false, reread: false)
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value", count: 3)
        await gate.finish("value", with: .success([])); await loader.waitUntilFinished()
        loader.request(source: loader.source, isEnabled: false, reread: false)
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await loader.waitUntilFinished()
        #expect(loader.value == [])
        #expect(await gate.requested.count == 3)
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func replacementDuringPublicationKeepsItsQueuedRefresh() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "a") { source, _ in
            await gate.read(source + String(await numbers.next()))
        }
        let publications = Mutex<[String]>([])
        loader.published = { _, current in
            publications.withLock { $0.append("\(current.source):\(current.value.map(String.init) ?? "nil")") }
        }
        withObservationTracking(options: [.didSet]) { _ = loader.value } onChange: { _ in
            MainActor.assumeIsolated {
                loader.request(source: "b", isEnabled: true, reread: false)
                loader.request(source: "b", isEnabled: true, reread: true)
            }
        }
        loader.request(source: "a", isEnabled: true, reread: false)
        await gate.waitForRequest("a0"); await gate.finish("a0", with: 1)
        await gate.waitForRequest("b1"); await gate.finish("b1", with: 2)
        await gate.waitForRequest("b2"); await gate.finish("b2", with: 3)
        await loader.waitUntilFinished()
        #expect(loader.source == "b" && loader.value == 3)
        #expect(await gate.requested == ["a0", "b1", "b2"])
        #expect(publications.withLock { $0 } == ["b:nil", "b:2", "b:3"])
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func replacementClearsImmediatelyAndRetiredReadsStayOwned() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>(), numbers = ReadNumbers()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "a") { source, _ in
            await gate.read(source + String(await numbers.next()))
        }
        loader.request(source: "a", isEnabled: true, reread: false)
        await gate.waitForRequest("a0")
        await gate.finish("a0", with: 1); await loader.waitUntilFinished()
        loader.request(source: "a", isEnabled: true, reread: true)
        await gate.waitForRequest("a1")
        loader.request(source: "b", isEnabled: true, reread: false)
        #expect(loader.value == nil)
        await gate.waitForCancellation("a1"); await gate.waitForRequest("b2")
        loader.request(source: "a", isEnabled: true, reread: false)
        await gate.waitForCancellation("b2"); await gate.waitForRequest("a3")
        await gate.finish("a3", with: 4)
        var drained = false
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiter = Task { started.resume(); await loader.waitUntilFinished(); drained = true }
        }
        await gate.finish("b2", with: 3)
        #expect(!drained)
        await gate.finish("a1", with: 2)
        await waiter?.value
        #expect(drained && loader.value == 4)
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func failedReadRetainsButSuccessfulEmptyAndSourceRemovalClear() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Result<[Int], CocoaError>>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "a") { source, _ in
            try await gate.read(source).get()
        }
        loader.request(source: "a", isEnabled: true, reread: false)
        await gate.waitForRequest("a"); await gate.finish("a", with: .success([1]))
        await loader.waitUntilFinished()
        loader.request(source: "a", isEnabled: true, reread: true)
        await gate.waitForRequest("a", count: 2)
        await gate.finish("a", with: .failure(CocoaError(.fileReadUnknown)))
        await loader.waitUntilFinished(); #expect(loader.value == [1])
        loader.request(source: "a", isEnabled: true, reread: true)
        await gate.waitForRequest("a", count: 3); await gate.finish("a", with: .success([]))
        await loader.waitUntilFinished(); #expect(loader.value == [])
        loader.request(source: "removed", isEnabled: false, reread: false)
        #expect(loader.value == nil)
        #expect(await gate.requested == ["a", "a", "a"])
        loader.close(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func refreshesCoalesceAndHiddenInvalidationSurvives() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("value") }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        loader.request(source: loader.source, isEnabled: true, reread: true)
        loader.request(source: loader.source, isEnabled: true, reread: true)
        await gate.finish("value", with: 1)
        await gate.waitForRequest("value", count: 2)
        #expect(loader.value == 1)
        await gate.finish("value", with: 2)
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        #expect(await gate.requested == ["value", "value"])

        loader.request(source: loader.source, isEnabled: false, reread: true)
        #expect(await gate.requested.count == 2)
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value", count: 3)
        #expect(loader.value == 2)
        await gate.finish("value", with: 3)
        await loader.waitUntilFinished()
        #expect(loader.value == 3)
        loader.close()
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledWaiterDoesNotCancelTheSharedRead() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("value") }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiter = Task {
                started.resume()
                await loader.waitUntilFinished()
            }
        }
        waiter?.cancel()
        await gate.finish("value", with: 7)
        await waiter?.value
        #expect(loader.value == 7)
        #expect(await gate.requested == ["value"])
        loader.close()
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingOneLoaderKeepsItsSiblingAndRejectsLateResults() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let first = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("first") }
        let second = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("second") }
        first.request(source: first.source, isEnabled: true, reread: false)
        second.request(source: second.source, isEnabled: true, reread: false)
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.request(source: first.source, isEnabled: true, reread: true)
        first.close()
        await gate.waitForCancellation("first")
        #expect(!work.isClosed)
        await gate.finish("first", with: 1)
        await gate.finish("second", with: 2)
        await work.waitUntilFinished()
        #expect(first.value == nil && second.value == 2)
        #expect(await gate.requested.count == 2)
        first.request(source: first.source, isEnabled: true, reread: true)
        #expect(await gate.requested.count == 2)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingBeforeEntryStillDrainsTheLoader() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        await gate.releaseAllAndFuture(with: 1)
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("value") }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        loader.close()
        await loader.waitUntilFinished()
        #expect(loader.value == nil)
        #expect(await gate.requested.isEmpty)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func drainingIncludesWorkRegisteredDuringTheWait() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Void>()
        work.start(priority: .utility) {
            await gate.read("first")
            work.start(priority: .utility) { await gate.read("second") }
        }
        await gate.waitForRequest("first")
        var finished = false
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiter = Task {
                started.resume()
                await work.waitUntilFinished()
                finished = true
            }
        }
        await gate.finish("first", with: ())
        await gate.waitForRequest("second")
        #expect(!finished)
        await gate.finish("second", with: ())
        await waiter?.value
        #expect(finished)
        work.close()
        #expect(work.start(priority: .utility) {} == nil)
    }

    @Test(.timeLimit(.minutes(1))) func hidingDuringAReadDefersItsQueuedRefreshUntilShown() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("value") }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        loader.request(source: loader.source, isEnabled: true, reread: true)
        loader.request(source: loader.source, isEnabled: false, reread: false)
        await gate.finish("value", with: 1)
        await loader.waitUntilFinished()
        #expect(loader.value == 1)
        #expect(await gate.requested.count == 1)
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value", count: 2)
        await gate.finish("value", with: 2)
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func worldClosureDrainsRegisteredWorkAndPreventsPublication() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: resources.backgroundWork, priority: .utility, whenInactive: .finish, source: "fixed") { _, _ in await gate.read("value") }
        loader.request(source: loader.source, isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        loader.request(source: loader.source, isEnabled: true, reread: true)
        var finishedClosing = false
        let closing = Task {
            resources.close()
            await resources.waitUntilClosed()
            finishedClosing = true
        }
        await gate.waitForCancellation("value")
        #expect(resources.isClosed && resources.backgroundWork.isClosed && !finishedClosing)
        await gate.finish("value", with: 9)
        await closing.value
        #expect(finishedClosing && loader.value == nil)
        loader.request(source: loader.source, isEnabled: true, reread: true)
        #expect(await gate.requested == ["value"])
    }
}
