import Foundation
import ChunkseeKit
import Observation

/// App actions delivered through native dimension documents, without owning their windows.
@Observable
final class DimensionRouting {
    @ObservationIgnored private weak var source: WorldSession?
    /// Supplied by the document view, capturing only SwiftUI's environment action.
    @ObservationIgnored var openDocument: ((URL) async throws -> Void)?
    var openFailure: String?

    init(source: WorldSession) { self.source = source }

    func openDimension(_ id: String) {
        guard let source, !source.isClosed, source.dimensions.contains(where: { $0.id == id }) else { return }
        open(id, then: nil)
    }

    /// A cross-dimension action belongs to its destination, even if no opener is available.
    /// Returning true prevents the caller from applying it to the source's map instead.
    func route(to dimension: String, perform: @escaping (WorldSession) -> Void) -> Bool {
        guard let source, !source.isClosed, dimension != source.selectedDimensionID else { return false }
        open(dimension, then: perform)
        return true
    }

    private func open(_ dimension: String, then perform: ((WorldSession) -> Void)?) {
        guard let source, !source.isClosed, let openDocument,
              let url = source.resources.documentURL(for: dimension) else { return }
        let resources = source.resources
        let request = perform.flatMap { resources.whenShowing(dimension, perform: $0) }
        Task { [weak self] in
            do {
                try await openDocument(url)
            } catch {
                if let request { resources.cancelPending(request, in: dimension) }
                guard !(error is CancellationError), (error as? CocoaError)?.code != .userCancelled,
                      self?.source?.isClosed == false else { return }
                self?.openFailure = error.localizedDescription
            }
        }
    }
}
