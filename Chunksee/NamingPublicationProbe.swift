import Darwin
import Foundation
import Synchronization

/// Evidence-only clocks. Fixed numeric slots are allocated before the opening interval;
/// no world, query, image or formatted-name objects are retained by this recorder.
nonisolated enum NamingPublicationProbe {
    enum Phase: String, Codable, Sendable {
        case worldSnapshot, worldPreparation, regionIO
        case languageRead, nameConstruction, regionProjection, dimensionProjection
        case carriedPetProjection, indexSnapshot, queryContext, queryExecution
        case namePublication, indexPublication, queryPublication

        var group: Group {
            switch self {
            case .worldSnapshot, .worldPreparation, .regionIO: .worldRead
            default: .namesAndIndex
            }
        }

        var isSynchronous: Bool { group == .namesAndIndex }
    }

    enum Group: String, Codable, Sendable { case worldRead, namesAndIndex }
    enum Failure: Error { case incomplete, crossingSpans, invalidThreadCPU }

    struct Instant: Codable, Sendable {
        let wallNanoseconds: UInt64
        let threadID: UInt64?
        let threadCPUNanoseconds: UInt64?
        let valid: Bool

        fileprivate init(synchronous: Bool) {
            wallNanoseconds = DispatchTime.now().uptimeNanoseconds
            if synchronous {
                var cpu = timespec(), id: UInt64 = 0
                let clockStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu)
                let threadStatus = pthread_threadid_np(nil, &id)
                let ok = clockStatus == 0 && threadStatus == 0 && id != 0 &&
                    cpu.tv_sec >= 0 && cpu.tv_nsec >= 0 && cpu.tv_nsec < 1_000_000_000
                threadID = id
                threadCPUNanoseconds = ok ? UInt64(cpu.tv_sec) * 1_000_000_000 + UInt64(cpu.tv_nsec) : nil
                valid = ok
            } else {
                threadID = nil
                threadCPUNanoseconds = nil
                valid = true
            }
        }
    }

    struct Span: Codable, Sendable {
        let phase: Phase
        let start: Instant
        var end: Instant?
    }

    struct Token: Sendable {
        fileprivate let generation: Int
        fileprivate let index: Int
    }

    struct Component: Codable, Sendable {
        let spanIndex: Int
        let phase: Phase
        let parentIndex: Int?
        let inclusiveThreadCPUNanoseconds: UInt64?
        let exclusiveThreadCPUNanoseconds: UInt64?
    }

    struct Summary: Codable, Sendable {
        let worldReadWallSeconds: Double
        let namesAndIndexWallSeconds: Double
        let namesAndIndexThreadCPUSeconds: Double
        let components: [Component]
    }

    struct Report: Codable, Sendable {
        let spans: [Span]
        let unfinished: Int
        let overflowed: Bool
        let invalidEndpoint: Bool
        let capacity: Int

        var isComplete: Bool { unfinished == 0 && !overflowed && !invalidEndpoint }

        /// All aggregation runs after the opening clock stops. Nested synchronous delivery
        /// is charged to its leaf component, not counted again in its caller's CPU total.
        func summarized() throws -> Summary {
            guard isComplete else { throw Failure.incomplete }
            var parents = [Int?](repeating: nil, count: spans.count)
            var inclusive = [UInt64?](repeating: nil, count: spans.count)
            for (index, span) in spans.enumerated() where span.phase.isSynchronous {
                let end = span.end!
                guard let startCPU = span.start.threadCPUNanoseconds, let endCPU = end.threadCPUNanoseconds,
                      span.start.threadID == end.threadID, endCPU >= startCPU else { throw Failure.invalidThreadCPU }
                inclusive[index] = endCPU - startCPU
                for previous in 0..<index where spans[previous].phase.isSynchronous &&
                    spans[previous].start.threadID == span.start.threadID {
                    let outer = spans[previous], outerEnd = outer.end!
                    guard span.start.wallNanoseconds < outerEnd.wallNanoseconds else { continue }
                    guard end.wallNanoseconds <= outerEnd.wallNanoseconds else { throw Failure.crossingSpans }
                    guard startCPU >= outer.start.threadCPUNanoseconds!,
                          endCPU <= outerEnd.threadCPUNanoseconds! else { throw Failure.invalidThreadCPU }
                    parents[index] = previous
                }
            }
            var exclusive = inclusive
            for index in spans.indices {
                if let parent = parents[index], let childCPU = inclusive[index], let parentCPU = exclusive[parent] {
                    guard parentCPU >= childCPU else { throw Failure.invalidThreadCPU }
                    exclusive[parent] = parentCPU - childCPU
                }
            }
            let components = spans.indices.map {
                Component(spanIndex: $0, phase: spans[$0].phase, parentIndex: parents[$0],
                          inclusiveThreadCPUNanoseconds: inclusive[$0], exclusiveThreadCPUNanoseconds: exclusive[$0])
            }
            return Summary(worldReadWallSeconds: unionWall(for: .worldRead),
                           namesAndIndexWallSeconds: unionWall(for: .namesAndIndex),
                           namesAndIndexThreadCPUSeconds: Double(exclusive.compactMap { $0 }.reduce(0, +)) / 1e9,
                           components: components)
        }

        private func unionWall(for group: Group) -> Double {
            let selected = spans.filter { $0.phase.group == group }.sorted {
                $0.start.wallNanoseconds < $1.start.wallNanoseconds
            }
            var end: UInt64 = 0, total: UInt64 = 0
            for span in selected {
                let nextEnd = span.end!.wallNanoseconds
                if nextEnd > end {
                    total += nextEnd - max(end, span.start.wallNanoseconds)
                    end = nextEnd
                }
            }
            return Double(total) / 1e9
        }
    }

    private struct State: Sendable {
        var recording = false
        var generation = 0
        var count = 0
        var slots: [Span?] = []
        var overflowed = false
        var invalidEndpoint = false
    }

    private static let capacity = 4096
    private static let state = Mutex(State())

    static func start() {
        state.withLock { value in
            precondition(!value.recording)
            value.generation += 1
            value.count = 0
            value.slots = [Span?](repeating: nil, count: capacity)
            value.overflowed = false
            value.invalidEndpoint = false
            value.recording = true
        }
    }

    static func begin(_ phase: Phase?) -> Token? {
        guard let phase else { return nil }
        return state.withLock { value in
            guard value.recording else { return nil }
            guard value.count < capacity else { value.overflowed = true; return nil }
            let index = value.count
            value.count += 1
            let start = Instant(synchronous: phase.isSynchronous)
            if !start.valid { value.invalidEndpoint = true }
            value.slots[index] = Span(phase: phase, start: start)
            return Token(generation: value.generation, index: index)
        }
    }

    static func end(_ token: Token?) {
        guard let token else { return }
        state.withLock { value in
            guard value.recording, value.generation == token.generation, token.index < value.count,
                  var span = value.slots[token.index], span.end == nil else {
                value.invalidEndpoint = true
                return
            }
            let end = Instant(synchronous: span.phase.isSynchronous)
            if !end.valid || end.wallNanoseconds <= span.start.wallNanoseconds ||
                (span.phase.isSynchronous && (span.start.threadID != end.threadID ||
                    (end.threadCPUNanoseconds ?? 0) < (span.start.threadCPUNanoseconds ?? 0))) {
                value.invalidEndpoint = true
            }
            span.end = end
            value.slots[token.index] = span
        }
    }

    static func finish() -> Report {
        state.withLock { value in
            precondition(value.recording)
            value.recording = false
            let spans = value.slots.prefix(value.count).compactMap { $0 }
            return Report(spans: spans, unfinished: spans.filter { $0.end == nil }.count,
                          overflowed: value.overflowed, invalidEndpoint: value.invalidEndpoint, capacity: capacity)
        }
    }
}
