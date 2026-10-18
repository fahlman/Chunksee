import Foundation

/// A reader that deliberately finishes after cancellation, like a disk read already underway.
/// Tests wait for entry/cancellation handshakes, then release the precise pending operation.
actor AsyncReadGate<Value: Sendable> {
    private var reads: [String: [CheckedContinuation<Value, Never>]] = [:]
    private var releasedValue: Value?
    private(set) var requested: [String] = []
    private var entered: [String: [(count: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private var cancelled: Set<String> = []
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func read(_ key: String) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let value = releasedValue { continuation.resume(returning: value) }
                else { reads[key, default: []].append(continuation) }
                requested.append(key)
                let count = requested.filter { $0 == key }.count
                let waiters = entered.removeValue(forKey: key) ?? []
                for waiter in waiters {
                    if count >= waiter.count { waiter.continuation.resume() }
                    else { entered[key, default: []].append(waiter) }
                }
            }
        } onCancel: {
            Task { await self.noteCancellation(key) }
        }
    }

    func waitForRequest(_ key: String, count: Int = 1) async {
        guard requested.filter({ $0 == key }).count < count else { return }
        await withCheckedContinuation { entered[key, default: []].append((count, $0)) }
    }

    func finish(_ key: String, with value: Value) {
        precondition(reads[key]?.isEmpty == false, "Release only an entered read")
        reads[key]!.removeFirst().resume(returning: value)
    }

    /// Release queued and subsequent reads while still recording every request. Coalescing
    /// tests can finish both the old repeated-read behavior and the shared-read candidate.
    func releaseAllAndFuture(with value: Value) {
        releasedValue = value
        finishAll(with: value)
    }

    /// Cleanup after a failed assertion/setup must still drain every suspended read.
    func finishAll(with value: Value) {
        let pending = reads.values.flatMap { $0 }
        reads = [:]
        for continuation in pending { continuation.resume(returning: value) }
    }

    private func noteCancellation(_ key: String) {
        cancelled.insert(key)
        for waiter in cancellationWaiters.removeValue(forKey: key) ?? [] { waiter.resume() }
    }

    func waitForCancellation(_ key: String) async {
        guard !cancelled.contains(key) else { return }
        await withCheckedContinuation { cancellationWaiters[key, default: []].append($0) }
    }
}
