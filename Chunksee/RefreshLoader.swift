import Foundation
import Observation

/// Heat-map progress may finish after hiding; optional metadata stops when nobody needs it.
nonisolated enum InactiveReadPolicy: Equatable, Sendable {
    case finish, cancel
}

/// Producers without distinct request strengths need only one kind of invalidation.
nonisolated enum RefreshInvalidation: Sendable { case refresh }

/// A failed dependent read may still supply independent facts. Publish those facts while
/// retaining the failed request's strength for the next externally requested pass.
nonisolated enum RefreshRead<Value: Sendable>: Sendable {
    case complete(Value)
    case partial(Value)

    var value: Value {
        switch self { case .complete(let value), .partial(let value): value }
    }
    var isComplete: Bool {
        if case .complete = self { true } else { false }
    }
}

/// Retains a value while it reloads and folds changes during a read into one following pass.
/// Waiting callers do not own the read; only this loader or its world may cancel it.
@Observable
final class RefreshLoader<Source: Equatable & Sendable, Request: Sendable, Value: Sendable> {
    typealias Publication = (source: Source, value: Value?)
    private var publication: Publication
    var value: Value? { publication.value }
    var source: Source { publication.source }
    private(set) var isClosed = false
    let work: BackgroundWork.Scope
    private let priority: TaskPriority?
    private let whenInactive: InactiveReadPolicy
    private let firstRequest: Request
    private let merge: @Sendable (Request, Request) -> Request
    private let retainingValue: @Sendable (Value, Source, Source) -> Value?
    private let read: @Sendable (Source, Request, Value?) async throws -> RefreshRead<Value>
    /// The producer installs dependent work before making requests. Run it after synchronous
    /// Observation delivery, in the publishing turn; it does not notify consumers itself.
    @ObservationIgnored var published: @MainActor (Publication, Publication) -> Void = { _, _ in }
    @ObservationIgnored private var active: (id: UUID, request: Request)?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var retry: Request?
    @ObservationIgnored private var replacementID = UUID()

    init(partialRead: @escaping @Sendable (Source, Request, Value?) async throws -> RefreshRead<Value>,
         work: BackgroundWork, priority: TaskPriority?, whenInactive: InactiveReadPolicy, source: Source,
         initialValue: Value? = nil,
         firstRequest: Request, merge: @escaping @Sendable (Request, Request) -> Request,
         retainingValue: @escaping @Sendable (Value, Source, Source) -> Value? = { _, _, _ in nil }) {
        self.work = work.makeScope()
        self.priority = priority
        self.whenInactive = whenInactive
        publication = (source, initialValue)
        self.firstRequest = firstRequest
        self.merge = merge
        self.retainingValue = retainingValue
        self.read = partialRead
    }

    convenience init(work: BackgroundWork, priority: TaskPriority?, whenInactive: InactiveReadPolicy, source: Source,
                     initialValue: Value? = nil,
                     firstRequest: Request, merge: @escaping @Sendable (Request, Request) -> Request,
                     retainingValue: @escaping @Sendable (Value, Source, Source) -> Value? = { _, _, _ in nil },
                     read: @escaping @Sendable (Source, Request, Value?) async throws -> Value) {
        self.init(partialRead: { source, request, previous in .complete(try await read(source, request, previous)) },
                  work: work, priority: priority, whenInactive: whenInactive, source: source,
                  initialValue: initialValue, firstRequest: firstRequest, merge: merge, retainingValue: retainingValue)
    }

    func request(source: Source, isEnabled: Bool, refresh: Request?) {
        guard !isClosed, !work.isClosed else { return }
        let replaced = self.source != source
        let retained = replaced ? value.flatMap { retainingValue($0, self.source, source) } : nil
        if replaced {
            retireRead()
            pending = firstRequest
        }
        self.isEnabled = isEnabled
        if let refresh { pending = merged(pending, refresh) }
        if replaced {
            // Publish source and its compatible value together. Observers may synchronously
            // request another source; only their current demand may run after this callback.
            guard publishReplacement(source: source, value: retained) else { return }
        }
        if !self.isEnabled, whenInactive == .cancel, let active {
            retry = merged(retry, active.request)
            work.cancel()
            self.active = nil
        }
        guard self.isEnabled, active == nil, let request = takeRequest() else { return }
        let read = read, work = work, source = self.source, id = UUID()
        guard work.start(priority: priority, operation: { [weak self] in
            defer { if self?.active?.id == id { self?.active = nil } }
            var request = request
            repeat {
                guard !Task.isCancelled, !work.isClosed else { return }
                let updated: RefreshRead<Value>?
                do { updated = try await read(source, request, self?.value) }
                catch { updated = nil }
                guard let self, !Task.isCancelled, !self.isClosed, !work.isClosed,
                      self.active?.id == id else { return }
                // A thrown failure preserves the value; a partial result supplies its own
                // coherent retained portion. Successful empty values still publish removals.
                if let updated {
                    let previous = self.publication
                    self.publication = (source, updated.value)
                    guard self.active?.id == id, !self.isClosed, !work.isClosed else { return }
                    self.published(previous, self.publication)
                }
                // Publication can synchronously notify observers. A replacement or closure
                // during delivery or the producer continuation must not edit a new request.
                guard self.active?.id == id, !self.isClosed, !work.isClosed else { return }
                // Preserve failed request strength, but only external demand starts another
                // pass. A failed forced read must not become a weaker metadata-only retry.
                if updated?.isComplete != true { self.retry = self.merged(self.retry, request) }
                guard self.isEnabled, self.pending != nil, let next = self.takeRequest() else { return }
                request = next
                self.active = (id, request)
            } while true
        }) != nil else { return }
        active = (id, request)
    }

    /// A document read already prepared a coherent value for a replacement source. Admit it
    /// through the same owner that cancels old passes and rejects their late completions.
    func replace(source: Source, value: Value?) {
        guard !isClosed, !work.isClosed else { return }
        retireRead()
        pending = nil
        isEnabled = false
        _ = publishReplacement(source: source, value: value)
    }

    private func retireRead() {
        work.cancel()
        active = nil
        retry = nil
    }

    private func publishReplacement(source: Source, value: Value?) -> Bool {
        let id = UUID(), previous = publication
        replacementID = id
        publication = (source, value)
        guard !isClosed, !work.isClosed, replacementID == id else { return false }
        published(previous, publication)
        return !isClosed && !work.isClosed && replacementID == id
    }

    private func merged(_ previous: Request?, _ request: Request) -> Request {
        previous.map { merge($0, request) } ?? request
    }

    private func takeRequest() -> Request? {
        let request = pending.map { merged(retry, $0) } ?? retry ?? (value == nil ? firstRequest : nil)
        pending = nil
        retry = nil
        return request
    }

    func close() {
        isClosed = true
        pending = nil
        retry = nil
        work.close()
        publication = (source, nil)
    }

    func waitUntilFinished() async {
        await work.waitUntilFinished()
    }
}

extension RefreshLoader where Request == RefreshInvalidation {
    convenience init(work: BackgroundWork, priority: TaskPriority?, whenInactive: InactiveReadPolicy, source: Source,
                     initialValue: Value? = nil,
                     read: @escaping @Sendable (Source, Value?) async throws -> Value) {
        self.init(work: work, priority: priority, whenInactive: whenInactive, source: source,
                  initialValue: initialValue,
                  firstRequest: .refresh, merge: { _, _ in .refresh }) { source, _, previous in
            try await read(source, previous)
        }
    }

    func request(source: Source, isEnabled: Bool, reread: Bool) {
        request(source: source, isEnabled: isEnabled, refresh: reread ? .refresh : nil)
    }
}
