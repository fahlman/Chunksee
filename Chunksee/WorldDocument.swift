import AppKit
import Foundation
import ChunkseeKit
import Observation
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

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
        } catch let error as WorldOpenError {
            throw error
        } catch WorldError.missingLevelDat {
            throw WorldOpenError.notAWorld
        } catch {
            throw WorldOpenError.unreadable
        }
    }
}

/// The world folders the user opened. A dimension's document is a folder inside its world, and
/// the sandbox grants a reopened document only its own folder, so access to the world itself,
/// for `level.dat`, players and the other dimensions, is kept here as app-scoped bookmarks.
nonisolated final class WorldFolders: Sendable {
    // Apple documents UserDefaults as thread-safe; the lock keeps each read-modify-write whole.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let lock = Mutex(())
    private static let key = "worldFolderBookmarks"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Call while the folder is accessible, as it is right after the Open panel chose it.
    func remember(_ world: URL) {
        guard let bookmark = try? world.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) else { return }
        lock.withLock { _ in
            let others = resolved().filter { $0.url.standardizedFileURL != world.standardizedFileURL }
            defaults.set(others.map(\.bookmark) + [bookmark], forKey: Self.key)
        }
    }

    /// The remembered world folder that contains `url`, wherever it has since moved.
    func world(containing url: URL) -> URL? {
        lock.withLock { _ in
            let worlds = resolved()
            defaults.set(worlds.map(\.bookmark), forKey: Self.key)
            let path = url.resolvingSymlinksInPath().path
            return worlds.map { $0.url.resolvingSymlinksInPath() }
                .filter { path.hasPrefix($0.path + "/") }
                .max { $0.path.count < $1.path.count }
        }
    }

    /// Resolves every bookmark, dropping those whose folders are gone and refreshing stale ones.
    private func resolved() -> [(url: URL, bookmark: Data)] {
        (defaults.array(forKey: Self.key) as? [Data] ?? []).compactMap { data in
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale) else { return nil }
            guard isStale else { return (url, data) }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let refreshed = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
            return (url, refreshed ?? data)
        }
    }
}

extension ChunkseeKit.Dimension {
    /// The folder that is this dimension's document. In the older layout the Overworld's files sit
    /// directly in the world folder, which isn't a document, so its region folder stands in.
    nonisolated func documentURL(inWorldAt world: URL) -> URL {
        url.standardizedFileURL == world.standardizedFileURL ? regionDirectory : url
    }
}

/// A dimension document's opening read: its world's metadata, read through the world's access.
nonisolated struct DimensionSnapshot: Sendable {
    let world: WorldSnapshot
    let dimensionID: String
    let documentURL: URL

    @concurrent
    static func read(_ url: URL, folders: WorldFolders) async throws -> DimensionSnapshot {
        try readContents(url, folders: folders)
    }

    /// Outside the framework's initial read, coordinate access with the document's presenter.
    @concurrent
    static func read(_ url: URL, folders: WorldFolders, coordinator: sending NSFileCoordinator) async throws -> DimensionSnapshot {
        var coordinationError: NSError?
        var result: Result<DimensionSnapshot, any Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try readContents(coordinatedURL, folders: folders) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw WorldOpenError.unreadable }
        return try result.get()
    }

    private static func readContents(_ url: URL, folders: WorldFolders) throws -> DimensionSnapshot {
        guard let worldURL = folders.world(containing: url) else { throw WorldOpenError.needsWorldFolder }
        let world = try WorldSnapshot.readContents(worldURL)
        let path = url.resolvingSymlinksInPath().path
        guard let dimension = world.dimensions.first(where: {
            $0.documentURL(inWorldAt: worldURL).resolvingSymlinksInPath().path == path
        }) else {
            world.access.release()
            throw WorldOpenError.notADimension
        }
        return DimensionSnapshot(world: world, dimensionID: dimension.id, documentURL: url)
    }
}

/// Each dimension folder is a read-only URL document. DocumentGroup supplies the Open panel,
/// duplicate-open handling, recent documents, file coordination, window tabs and restoration.
/// Dimensions of one world share its resources, which close with the last of them.
@Observable
final class WorldDocument: ReadableDocument {
    nonisolated static let readableContentTypes: [UTType] = [.folder]
    let configuration: URLDocumentConfiguration
    private let model: AppModel
    private(set) var session: WorldSession?
    @ObservationIgnored private var applyGeneration = UUID()

    init(configuration: URLDocumentConfiguration, model: AppModel) {
        self.configuration = configuration
        self.model = model
    }

    nonisolated struct Reader: DocumentReader {
        let folders: WorldFolders

        /// A world folder isn't itself a document: it holds one for each dimension. Opening it
        /// remembers the world's access and opens those instead.
        @concurrent
        func read(from source: sending URL, progress: consuming Subprogress) async throws -> sending DimensionSnapshot {
            if let world = try? World(contentsOf: source) {
                folders.remember(source)
                let documents = world.dimensions().map { $0.documentURL(inWorldAt: source) }
                Task { @MainActor in
                    // SwiftUI's openDocument action exists only in a view's environment, so ask the
                    // document controller DocumentGroup uses. Opened last, the first dimension is in front.
                    for url in documents.reversed() {
                        do { _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true) }
                        catch { NSDocumentController.shared.presentError(error) }
                    }
                }
                throw CocoaError(.userCancelled)
            }
            return try await DimensionSnapshot.read(source, folders: folders)
        }
    }

    func reader(configuration: sending ReadConfiguration) -> sending Reader { Reader(folders: model.worldFolders) }

    func apply(snapshot: sending DimensionSnapshot, previous: sending DimensionSnapshot?) async throws {
        let generation = UUID()
        applyGeneration = generation
        try await replaceSession(snapshot, generation: generation)
    }

    private func replaceSession(_ snapshot: DimensionSnapshot, generation: UUID) async throws {
        var current = snapshot
        while let url = configuration.fileURL,
              url.resolvingSymlinksInPath() != current.documentURL.resolvingSymlinksInPath() {
            // A move was reported while the snapshot was being read.
            current.world.access.release()
            current = try await DimensionSnapshot.read(url, folders: model.worldFolders, coordinator: configuration.makeFileCoordinator())
            try Task.checkCancellation()
            guard generation == applyGeneration else { current.world.access.release(); return }
        }
        guard generation == applyGeneration else { current.world.access.release(); return }
        let oldSession = session
        oldSession?.close()
        await oldSession?.waitUntilClosed()
        try Task.checkCancellation()
        guard generation == applyGeneration else { current.world.access.release(); return }
        let worldURL = current.world.access.url
        if let oldSession, oldSession.url != worldURL {
            oldSession.savedPlaces.relocate(to: worldURL)
            oldSession.resources.views.relocate(to: worldURL)
        }
        let opened = WorldSession(resources: model.resources(for: current.world), dimensionID: current.dimensionID)
        if let oldSession { opened.restoreView(from: oldSession) }
        session = opened
    }

    /// macOS updates the document URL after a Finder move; lazy region readers need the new paths.
    func followFileURL() async throws {
        guard let url = configuration.fileURL, let dimension = session?.selectedDimension, let session,
              url.resolvingSymlinksInPath() != dimension.documentURL(inWorldAt: session.url).resolvingSymlinksInPath() else { return }
        let generation = UUID()
        applyGeneration = generation
        let snapshot = try await DimensionSnapshot.read(url, folders: model.worldFolders, coordinator: configuration.makeFileCoordinator())
        try Task.checkCancellation()
        guard generation == applyGeneration else { snapshot.world.access.release(); return }
        try await replaceSession(snapshot, generation: generation)
    }

    isolated deinit { session?.close() }
}

struct WorldDocumentView: View {
    let document: WorldDocument
    @Environment(\.openDocument) private var openDocument
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session = document.session {
                WorldView(session: session)
                    .id(ObjectIdentifier(session))
                    .onAppear { session.openDimensionDocument = { open($0, of: session) } }
            } else {
                ProgressView("Opening World…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: document.configuration.fileURL) {
            do { try await document.followFileURL() }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
        .alert("Couldn’t Read World", isPresented: Binding {
            errorMessage != nil
        } set: { if !$0 { errorMessage = nil } }) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    /// Opening a dimension that's already open brings its window to the front.
    private func open(_ dimensionID: String, of session: WorldSession) {
        guard let url = session.resources.documentURL(for: dimensionID) else { return }
        Task {
            do { try await openDocument(at: url) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
