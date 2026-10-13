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

    private static func readContents(_ url: URL) throws -> WorldSnapshot {
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

/// A Minecraft folder is a read-only URL document. DocumentGroup supplies the Open panel,
/// duplicate-open handling, recent documents, file coordination and system window restoration.
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
        @concurrent
        func read(from source: sending URL, progress: consuming Subprogress) async throws -> sending WorldSnapshot {
            try await WorldSnapshot.read(source)
        }
    }

    func reader(configuration: sending ReadConfiguration) -> sending Reader { Reader() }

    func apply(snapshot: sending WorldSnapshot, previous: sending WorldSnapshot?) async throws {
        let generation = UUID()
        applyGeneration = generation
        try await replaceSession(snapshot, generation: generation)
    }

    private func replaceSession(_ snapshot: WorldSnapshot, generation: UUID) async throws {
        var current = snapshot
        while let url = configuration.fileURL,
              url.resolvingSymlinksInPath() != current.access.url.resolvingSymlinksInPath() {
            // A move was reported while the snapshot was being read.
            current.access.release()
            current = try await WorldSnapshot.read(url, coordinator: configuration.makeFileCoordinator())
            try Task.checkCancellation()
            guard generation == applyGeneration else { return }
        }
        guard generation == applyGeneration else { return }
        let oldSession = session
        oldSession?.close()
        await oldSession?.waitUntilClosed()
        try Task.checkCancellation()
        guard generation == applyGeneration else { return }
        oldSession?.savedPlaces.relocate(to: current.access.url)
        let opened = WorldSession(snapshot: current, names: model.names, savedSearches: model.savedSearches)
        if let oldSession { opened.restoreView(from: oldSession) }
        session = opened
    }

    /// macOS updates the document URL after a Finder move; lazy region readers need the new paths.
    func followFileURL() async throws {
        guard let url = configuration.fileURL, let session,
              url.resolvingSymlinksInPath() != session.url.resolvingSymlinksInPath() else { return }
        let generation = UUID()
        applyGeneration = generation
        let snapshot = try await WorldSnapshot.read(url, coordinator: configuration.makeFileCoordinator())
        try Task.checkCancellation()
        guard generation == applyGeneration else { return }
        try await replaceSession(snapshot, generation: generation)
    }

    isolated deinit { session?.close() }
}

struct WorldDocumentView: View {
    let document: WorldDocument
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session = document.session {
                WorldView(session: session)
                    .id(ObjectIdentifier(session))
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
}
