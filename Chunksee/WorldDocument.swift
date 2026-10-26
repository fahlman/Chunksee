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
    /// Resolved document paths to dimension IDs, prepared off-main with the opening metadata.
    let dimensionDocuments: [String: String]
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
            let dimensions = world.dimensions()
            var documents: [String: String] = [:]
            for dimension in dimensions {
                let path = dimension.documentURL(inWorldAt: url).resolvingSymlinksInPath().path
                if documents[path] == nil { documents[path] = dimension.id }
            }
            let details = WorldDetails.read(world)
            let snapshot = WorldSnapshot(access: access, world: world, dimensions: dimensions, dimensionDocuments: documents,
                                         players: world.players(enchantments: details.definitions.enchantments), details: details)
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

extension ChunkseeKit.Dimension {
    /// The folder that is this dimension's document. In the older layout the Overworld's files sit
    /// directly in the world folder, which isn't a document, so its region folder stands in.
    nonisolated func documentURL(inWorldAt world: URL) -> URL {
        url.standardizedFileURL == world.standardizedFileURL ? regionDirectory : url
    }
}

/// A dimension document's opening read: its world's metadata, read through the world's access.
nonisolated struct DimensionSnapshot: Sendable {
    enum Source: Sendable {
        case snapshot(WorldSnapshot)
        case opening(WorldOpening)
    }
    let source: Source
    let folder: WorldFolders.Folder
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
        guard let folder = folders.world(containing: url) else { throw WorldOpenError.needsWorldFolder }
        let world = try WorldSnapshot.readContents(folder.url)
        let path = url.resolvingSymlinksInPath().path
        guard let dimensionID = world.dimensionDocuments[path] else {
            world.access.release()
            throw WorldOpenError.notADimension
        }
        return DimensionSnapshot(source: .snapshot(world), folder: folder,
                                 dimensionID: dimensionID, documentURL: url)
    }

    @MainActor
    func discardUnused() {
        switch source {
        case .snapshot(let world): world.access.release()
        case .opening(let opening): opening.finish()
        }
    }

    /// Attach before finishing the opening, so closing the previous last view cannot end access.
    @MainActor
    func makeSession(in model: AppModel) throws -> WorldSession {
        switch source {
        case .snapshot(let world):
            return WorldSession(resources: model.resources(for: world, folder: folder), dimensionID: dimensionID)
        case .opening(let opening):
            guard let resources = opening.resources, !resources.isClosed else { throw CancellationError() }
            let session = WorldSession(resources: resources, dimensionID: dimensionID)
            opening.finish()
            return session
        }
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
        var model: AppModel?
        var reuseOpenWorld: @MainActor @Sendable () -> Bool = { true }

        /// A world folder isn't itself a document: it holds one for each dimension. Reading it
        /// remembers the world's access and lists those, for its window to open instead.
        @concurrent
        func read(from source: sending URL, progress: consuming Subprogress) async throws -> sending FolderSnapshot {
            try await readFolder(source)
        }

        @concurrent
        func readFolder(_ source: URL) async throws -> FolderSnapshot {
            try Task.checkCancellation()
            do {
                let world = try World(contentsOf: source)
                let dimensions = world.dimensions().map { $0.documentURL(inWorldAt: source) }
                try Task.checkCancellation()
                try folders.remember(source)
                return .world(dimensions: dimensions)
            } catch WorldError.missingLevelDat {
                do {
                    if let model, await reuseOpenWorld() {
                        guard let folder = folders.world(containing: source) else { throw WorldOpenError.needsWorldFolder }
                        if let snapshot = try await model.initialDimension(at: source.resolvingSymlinksInPath(), in: folder) {
                            do { try Task.checkCancellation() }
                            catch { await snapshot.discardUnused(); throw error }
                            return .dimension(snapshot)
                        }
                    }
                    return .dimension(try await DimensionSnapshot.read(source, folders: folders))
                } catch WorldOpenError.needsWorldFolder {
                    // Without a containing world, an arbitrary folder isn't known to be a
                    // dimension. Ask for a world instead of diagnosing lost access to one.
                    throw WorldOpenError.notAWorld
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw WorldOpenError.unreadable
            }
        }
    }

    nonisolated enum FolderSnapshot: Sendable {
        case dimension(DimensionSnapshot)
        case world(dimensions: [URL])
    }

    /// The dimension documents to open in place of this one, when it's a world folder.
    private(set) var worldDimensions: [URL]?

    func reader(configuration: sending ReadConfiguration) -> sending Reader {
        Reader(folders: model.worldFolders, model: model, reuseOpenWorld: { [weak self] in
            guard let self else { return false }
            return self.session == nil
        })
    }

    func apply(snapshot: sending FolderSnapshot, previous: sending FolderSnapshot?) async throws {
        let generation = UUID()
        applyGeneration = generation
        switch snapshot {
        case .dimension(let dimension): try await replaceSession(dimension, generation: generation)
        case .world(let dimensions):
            try Task.checkCancellation()
            worldDimensions = dimensions
        }
    }

    private func replaceSession(_ snapshot: DimensionSnapshot, generation: UUID) async throws {
        var current = snapshot
        var adopted = false
        defer { if !adopted { current.discardUnused() } }
        try Task.checkCancellation()
        while let url = configuration.fileURL,
              url.resolvingSymlinksInPath() != current.documentURL.resolvingSymlinksInPath() {
            // A move was reported while the snapshot was being read.
            current.discardUnused()
            current = try await DimensionSnapshot.read(url, folders: model.worldFolders, coordinator: configuration.makeFileCoordinator())
            try Task.checkCancellation()
            guard generation == applyGeneration else { return }
        }
        guard generation == applyGeneration else { return }
        let oldSession = session
        oldSession?.close()
        await oldSession?.waitUntilClosed()
        try Task.checkCancellation()
        guard generation == applyGeneration else { return }
        let opened = try current.makeSession(in: model)
        adopted = true
        if let oldSession { opened.restoreView(from: oldSession) }
        session = opened
    }

    /// macOS updates the document URL after a Finder move; lazy region readers need the new paths.
    func followFileURL() async throws {
        guard let url = configuration.fileURL, let dimension = session?.presentation.selectedDimension, let session,
              url.resolvingSymlinksInPath() != dimension.documentURL(inWorldAt: session.url).resolvingSymlinksInPath() else { return }
        let generation = UUID()
        applyGeneration = generation
        let snapshot = try await DimensionSnapshot.read(url, folders: model.worldFolders, coordinator: configuration.makeFileCoordinator())
        try Task.checkCancellation()
        guard generation == applyGeneration else { snapshot.discardUnused(); return }
        try await replaceSession(snapshot, generation: generation)
    }

    isolated deinit { session?.close() }
}

struct WorldDocumentView: View {
    let document: WorldDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let dimensions = document.worldDimensions {
                ProgressView("Opening world…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await openInstead(dimensions) }
            } else if let session = document.session {
                WorldView(session: session)
                    .background(DocumentWindowTitle(title: session.selectedDimensionID.map { session.presentation.dimensionName($0) } ?? session.presentation.displayName))
                    .id(ObjectIdentifier(session))
                    // Capture only the action: the session must not keep its own view or document alive.
                    .onAppear { session.routing.openDocument = { [openDocument] in try await openDocument(at: $0) } }
            } else {
                ProgressView("Opening world…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: document.configuration.fileURL) {
            do { try await document.followFileURL() }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
        .alert("Couldn’t Read World", isPresented: Binding {
            errorMessage != nil || document.session?.routing.openFailure != nil
        } set: { if !$0 { errorMessage = nil; document.session?.routing.openFailure = nil } }) {
            Button("OK", role: .cancel) { if document.worldDimensions != nil { dismiss() } }
        } message: { Text(errorMessage ?? document.session?.routing.openFailure ?? "") }
    }

    /// Opens a world folder's dimensions, then closes the folder's own window. Opened last, the
    /// first dimension ends up in front.
    private func openInstead(_ dimensions: [URL]) async {
        do {
            for url in dimensions.reversed() { try await openDocument(at: url) }
            dismiss()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
