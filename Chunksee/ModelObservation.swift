import Foundation
import Observation

/// A model owns synchronous observation for its lifetime, independently of visible views.
/// Every tracked publication and both closures must stay on the main actor.
/// The read captures dependencies without changing them; onChange receives the previous value.
@MainActor
final class ModelObservation {
    private var registration: UUID?
    private var observe: (@MainActor () -> Void)?
    private var applyChange: (@MainActor () -> Void)?

    init<Owner: AnyObject, Value>(_ owner: Owner,
                                 isActive: @escaping @MainActor (Owner) -> Bool,
                                 read: @escaping @MainActor (Owner) -> Value,
                                 onChange: @escaping @MainActor (Owner, Value) -> Void) {
        observe = { [weak self, weak owner] in
            guard let self else { return }
            guard let owner, isActive(owner) else { self.cancel(); return }
            let id = UUID()
            self.registration = id
            let previous = withObservationTracking(options: [.didSet]) {
                read(owner)
            } onChange: { [weak self] event in
                // A nested setter must not enter this registration while it is being retired.
                event.cancel()
                MainActor.assumeIsolated { self?.changed(id) }
            }
            self.applyChange = { [weak owner] in
                guard let owner, isActive(owner) else { return }
                onChange(owner, previous)
            }
        }
        observe?()
    }

    private func changed(_ id: UUID) {
        // Cancellation cannot retract a callback already captured by an outer setter.
        guard registration == id else { return }
        let change = applyChange
        registration = nil
        applyChange = nil
        // Track the new inputs before reacting, so changes made by the reaction are observed.
        observe?()
        change?()
    }

    func cancel() {
        // The native one-shot API provides its cancellation handle only when it fires. Clear
        // our reaction now; an already-registered callback will cancel itself without rearming.
        registration = nil
        observe = nil
        applyChange = nil
    }
}
