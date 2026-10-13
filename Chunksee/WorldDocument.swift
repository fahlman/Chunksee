import AppKit
import Foundation
import ChunkseeKit
import Synchronization

/// Balanced access that can outlive a cancelled read until that read actually finishes.
nonisolated final class WorldReadAccess: Sendable {
    let url: URL
    private let accessing: Mutex<Bool>

    init(_ url: URL) {
        self.url = url
        accessing = Mutex(url.startAccessingSecurityScopedResource())
    }

    func release() {
        accessing.withLock { active in
            if active { url.stopAccessingSecurityScopedResource() }
            active = false
        }
    }

    deinit { release() }
}

/// Only the small opening metadata is read here. Regions remain lazy, read by the session.
nonisolated struct WorldSnapshot: Sendable {
    let access: WorldReadAccess
    let world: World
    let dimensions: [ChunkseeKit.Dimension]
    let players: [PlayerInfo]
    let details: WorldDetails

    @concurrent
    static func read(_ url: URL) async throws -> WorldSnapshot {
        try readContents(url)
    }

    /// Outside the framework's initial read, coordinate access with the document's presenter.
    @concurrent
    static func read(_ url: URL, coordinator: sending NSFileCoordinator) async throws -> WorldSnapshot {
        var coordinationError: NSError?
        var result: Result<WorldSnapshot, any Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try readContents(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw WorldOpenError.unreadable }
        return try result.get()
    }

    static func readContents(_ url: URL) throws -> WorldSnapshot {
        let access = WorldReadAccess(url)
        do {
            try Task.checkCancellation()
            let world = try World(contentsOf: url)
            let snapshot = WorldSnapshot(access: access, world: world, dimensions: world.dimensions(),
                                         players: world.players(), details: WorldDetails.read(world))
            try Task.checkCancellation()
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch WorldError.missingLevelDat {
            throw WorldOpenError.notAWorld
        } catch {
            throw WorldOpenError.unreadable
        }
    }
}

/// One native document owns every dimension window. AppKit owns opening, recents,
/// file presentation, closing and restoration; SwiftUI supplies each window's content.
@objc(ChunkseeWorldDocument)
final class WorldDocument: NSDocument {
    private(set) var resources: WorldResources?
    private var dimensionSessions: [String: WorldSession] = [:]
    private let tabbingIdentifier = NSWindow.TabbingIdentifier("world-" + UUID().uuidString)
    private var moveTask: Task<Void, Never>?
    private var isClosing = false
    nonisolated private let pendingSnapshot = Mutex<WorldSnapshot?>(nil)

    override init() {
        super.init()
        hasUndoManager = false
    }

    convenience init(resources: WorldResources) {
        self.init()
        self.resources = resources
    }

    nonisolated override class var autosavesInPlace: Bool { false }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let snapshot = try WorldSnapshot.readContents(url)
        pendingSnapshot.withLock { $0 = snapshot }
        Task { @MainActor [weak self] in self?.installPendingSnapshot() }
    }

    private func installPendingSnapshot() {
        guard !isClosing else { pendingSnapshot.withLock { $0 = nil }; return }
        if let snapshot = pendingSnapshot.withLock({ value in
            defer { value = nil }
            return value
        }) { install(snapshot) }
    }

    private func install(_ snapshot: WorldSnapshot) {
        let oldViews = dimensionSessions
        let oldResources = resources
        for view in oldViews.values { view.close() }
        oldResources?.close()
        oldResources?.savedPlaces.relocate(to: snapshot.access.url)
        oldResources?.views.relocate(to: snapshot.access.url)
        let model = AppModel.shared
        resources = WorldResources(snapshot: snapshot, names: model.names, savedSearches: model.savedSearches,
                                   documentOwnsLifetime: true)
        dimensionSessions = [:]
        for (id, old) in oldViews {
            if let view = ensureView(in: id) { view.restoreView(from: old) }
        }
        for controller in windowControllers.compactMap({ $0 as? DimensionWindowController }) {
            if let view = ensureView(in: controller.dimension) { controller.replaceSession(view) }
        }
    }

    nonisolated override var fileURL: URL? {
        didSet {
            guard let url = fileURL else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isClosing else { return }
                self.installPendingSnapshot()
                guard let resources = self.resources,
                      url.resolvingSymlinksInPath() != resources.url.resolvingSymlinksInPath() else { return }
                self.moveTask?.cancel()
                self.moveTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let snapshot = try await WorldSnapshot.read(url, coordinator: NSFileCoordinator(filePresenter: self))
                        try Task.checkCancellation()
                        guard self.fileURL == url else { return }
                        self.install(snapshot)
                    } catch is CancellationError {}
                    catch { self.presentError(error) }
                }
            }
        }
    }

    override func makeWindowControllers() {
        installPendingSnapshot()
        guard windowControllers.isEmpty, let resources else { return }
        var first: NSWindow?
        for dimension in resources.dimensions {
            guard let window = makeController(for: dimension.id)?.window else { continue }
            if let first { first.addTabbedWindow(window, ordered: .above) }
            else { first = window }
        }
    }

    override func showWindows() {
        let selected = resources?.activeDimensionID ?? resources?.defaultDimensionID
        super.showWindows()
        let controller = windowControllers.compactMap { $0 as? DimensionWindowController }.first { $0.dimension == selected }
        if let window = controller?.window { window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil) }
    }

    @discardableResult
    private func makeController(for dimension: String, identifier: NSUserInterfaceItemIdentifier? = nil) -> DimensionWindowController? {
        if let existing = windowControllers.compactMap({ $0 as? DimensionWindowController }).first(where: { $0.dimension == dimension }) { return existing }
        guard let view = ensureView(in: dimension) else { return nil }
        let controller = DimensionWindowController(session: view, identifier: identifier)
        controller.window?.tabbingIdentifier = tabbingIdentifier
        addWindowController(controller)
        return controller
    }

    /// Native restoration has already reopened this document and retained its file access.
    /// Create just the requested view; AppKit restores tab groups and window placement.
    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                                        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        installPendingSnapshot()
        guard let dimension = DimensionWindowController.dimension(from: state),
              let controller = makeController(for: dimension, identifier: identifier) else {
            completionHandler(nil, nil); return
        }
        controller.restoreState(with: state)
        completionHandler(controller.window, nil)
    }

    func existingView(in id: String) -> WorldSession? { dimensionSessions[id] }

    @discardableResult
    func ensureView(in id: String) -> WorldSession? {
        if let view = dimensionSessions[id], !view.isClosed { return view }
        guard let resources, !resources.isClosed,
              resources.dimensions.contains(where: { $0.id == id }) else { return nil }
        let view = WorldSession(resources: resources, dimensionID: id)
        view.isVisible = false
        view.openDimensionTab = { [weak self, weak view] target, perform in
            self?.showDimension(target, from: view?.selectedDimensionID, perform: perform)
        }
        dimensionSessions[id] = view
        return view
    }

    private func showDimension(_ id: String, from source: String?, perform: (WorldSession) -> Void) {
        let existing = windowControllers.compactMap { $0 as? DimensionWindowController }.first { $0.dimension == id }
        guard let controller = existing ?? makeController(for: id), let window = controller.window else { return }
        if existing == nil,
           let parent = windowControllers.compactMap({ $0 as? DimensionWindowController }).first(where: { $0.dimension == source })?.window {
            parent.addTabbedWindow(window, ordered: .above)
        }
        perform(controller.session)
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    override func removeWindowController(_ windowController: NSWindowController) {
        if let controller = windowController as? DimensionWindowController {
            if let window = controller.window { AppModel.shared.windows.unregister(window) }
            dimensionSessions.removeValue(forKey: controller.dimension)?.close()
        }
        super.removeWindowController(windowController)
    }

    override func close() {
        isClosing = true
        pendingSnapshot.withLock { $0 = nil }
        moveTask?.cancel()
        for view in dimensionSessions.values { view.close() }
        resources?.close()
        super.close()
    }

    isolated deinit {
        moveTask?.cancel()
        for view in dimensionSessions.values { view.close() }
        resources?.close()
    }
}
