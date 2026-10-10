import Foundation

/// A reader that deliberately finishes after cancellation, like a disk read already underway.
/// Tests wait for entry/cancellation handshakes, then release the precise pending operation.
actor AsyncReadGate<Value: Sendable> {
    private var reads: [String: [CheckedContinuation<Value, Never>]] = [:]
    private(set) var requested: [String] = []
    private var entered: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelled: Set<String> = []
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func read(_ key: String) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reads[key, default: []].append(continuation)
                requested.append(key)
                for waiter in entered.removeValue(forKey: key) ?? [] { waiter.resume() }
            }
        } onCancel: {
            Task { await self.noteCancellation(key) }
        }
    }

    func waitForRequest(_ key: String) async {
        guard !requested.contains(key) else { return }
        await withCheckedContinuation { entered[key, default: []].append($0) }
    }

    func finish(_ key: String, with value: Value) {
        precondition(reads[key]?.isEmpty == false, "Release only an entered read")
        reads[key]!.removeFirst().resume(returning: value)
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
