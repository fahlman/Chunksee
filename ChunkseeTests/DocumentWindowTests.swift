import AppKit
import ChunkseeKit
import ChunkseeKitTestSupport
import Observation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(1))) struct DocumentWindowTests {
    @Test func failedNativeReadsPublishTheirErrorAndLaterOpenNormally() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(World(contentsOf: root).dimension("minecraft:overworld"))
            .documentURL(inWorldAt: root).resolvingSymlinksInPath()
        let defaults = TestDefaults.make()
        let model = AppModel(defaults: defaults, cacheRoot: nil)
        let (documents, created) = AsyncStream.makeStream(of: WorldDocument.self)
        defer { created.finish() }
        var createdIterator = documents.makeAsyncIterator()
        var natives: [NSDocument] = []
        var owners: [WorldDocument] = []
        try #require(TestDocumentWindows.makeDocument == nil)
        TestDocumentWindows.makeDocument = { configuration in
            let document = WorldDocument(configuration: configuration, model: model)
            owners.append(document)
            created.yield(document)
            return document
        }
        defer { TestDocumentWindows.makeDocument = nil }
        func close() async {
            natives.forEach { $0.close() }
            for owner in owners {
                owner.session?.close()
                await owner.session?.waitUntilClosed()
            }
            await model.names.minecraft.waitUntilIdle()
        }
        do {
            // Native opening can throw here or return before SwiftUI creates and reads its
            // document. Wait for the actual document and failure in both cases.
            do {
                let (native, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
                natives.append(native)
                #expect(!reused)
            } catch {
                #expect(!(error is CancellationError))
            }
            let failed = try #require(await createdIterator.next())
            for await _ in Observations<Void, Never>.untilFinished({
                failed.openingFailure == nil ? .next(()) : .finish
            }) {}
            #expect(failed.session == nil && failed.worldDimensions == nil)
            #expect(failed.openingFailure == WorldOpenError.notAWorld.localizedDescription)

            // A retired or canceled read must not put a newer opening back into its error state.
            let retired = failed.makeReader()
            let current = failed.makeReader()
            await #expect(throws: WorldOpenError.notAWorld) { try await retired.readFolder(dimension) }
            #expect(failed.openingFailure == nil)
            let canceled = Task { try await current.readFolder(dimension) }
            canceled.cancel()
            await #expect(throws: CancellationError.self) { try await canceled.value }
            #expect(failed.openingFailure == nil)
            await #expect(throws: WorldOpenError.notAWorld) { try await current.readFolder(dimension) }
            #expect(failed.openingFailure == WorldOpenError.notAWorld.localizedDescription)
            natives.forEach { $0.close() }
            NSDocumentController.shared.document(for: dimension)?.close()

            // Opening the world grants access. A fresh native document can then use the normal
            // reader and shared preparation, without a second document registry or retry loop.
            let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
            guard case .world = try await reader.readFolder(root) else {
                Issue.record("World did not supply its folder access")
                await close()
                return
            }
            let (openedNative, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
            natives.append(openedNative)
            #expect(!reused)
            let opened = try #require(await createdIterator.next())
            for await _ in Observations<Void, Never>.untilFinished({
                opened.session == nil && opened.openingFailure == nil ? .next(()) : .finish
            }) {}
            #expect(opened.openingFailure == nil)
            #expect(opened.session?.selectedDimensionID == "minecraft:overworld")
            let session = try #require(opened.session)
            defaults.removeObject(forKey: "worldFolderBookmarks")
            let rereader = opened.makeReader()
            await #expect(throws: WorldOpenError.notAWorld) { try await rereader.readFolder(dimension) }
            #expect(opened.openingFailure == nil && opened.session === session)
            #expect(!session.resources.isClosed)
        } catch {
            await close()
            throw error
        }
        await close()
    }

    @Test func applyFailuresPublishTheirErrorAndPreserveLoadedSessions() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(World(contentsOf: root).dimension("minecraft:overworld"))
            .documentURL(inWorldAt: root).resolvingSymlinksInPath()
        let defaults = TestDefaults.make()
        let model = AppModel(defaults: defaults, cacheRoot: nil)
        let (documents, created) = AsyncStream.makeStream(of: WorldDocument.self)
        defer { created.finish() }
        var iterator = documents.makeAsyncIterator()
        var natives: [NSDocument] = []
        var owners: [WorldDocument] = []
        try #require(TestDocumentWindows.makeDocument == nil)
        TestDocumentWindows.makeDocument = { configuration in
            let document = WorldDocument(configuration: configuration, model: model)
            owners.append(document)
            created.yield(document)
            return document
        }
        defer { TestDocumentWindows.makeDocument = nil }
        func close() async {
            natives.forEach { $0.close() }
            NSDocumentController.shared.document(for: dimension)?.close()
            for owner in owners {
                owner.session?.close()
                await owner.session?.waitUntilClosed()
            }
            await model.names.minecraft.waitUntilIdle()
        }
        // A snapshot read before the document moved takes apply's coordinated reread path.
        func displacedSnapshot() async throws -> DimensionSnapshot {
            DimensionSnapshot(source: .snapshot(try await WorldSnapshot.read(root)),
                folder: .init(id: UUID(), url: root), dimensionID: "minecraft:overworld",
                documentURL: root.appendingPathComponent("previous-dimension-location"))
        }
        do {
            do {
                let (native, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
                natives.append(native)
                #expect(!reused)
            } catch {
                #expect(!(error is CancellationError))
            }
            let failed = try #require(await iterator.next())
            for await _ in Observations<Void, Never>.untilFinished({
                failed.openingFailure == nil ? .next(()) : .finish
            }) {}
            try #require(failed.configuration.fileURL?.resolvingSymlinksInPath() == dimension)
            try #require(failed.session == nil)

            // The host captures the document value even when macOS discards its failed window.
            // Apply error reporting must not depend on native restoration retaining that window.
            let cancelledSnapshot = try await displacedSnapshot()
            _ = failed.makeReader()
            let cancelled = Task { try await failed.apply(snapshot: .dimension(cancelledSnapshot), previous: nil) }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(failed.openingFailure == nil && failed.session == nil)

            let displaced = try await displacedSnapshot()
            _ = failed.makeReader()
            await #expect(throws: WorldOpenError.needsWorldFolder) {
                try await failed.apply(snapshot: .dimension(displaced), previous: nil)
            }
            #expect(failed.openingFailure == WorldOpenError.needsWorldFolder.localizedDescription)
            #expect(failed.session == nil)

            natives.forEach { $0.close() }
            NSDocumentController.shared.document(for: dimension)?.close()
            try model.worldFolders.remember(root)
            let (native, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
            natives.append(native)
            #expect(!reused)
            let opened = try #require(await iterator.next())
            for await _ in Observations<Void, Never>.untilFinished({
                opened.session == nil && opened.openingFailure == nil ? .next(()) : .finish
            }) {}
            let session = try #require(opened.session)
            #expect(opened.openingFailure == nil)
            defaults.removeObject(forKey: "worldFolderBookmarks")
            let unreadableReplacement = try await displacedSnapshot()
            await #expect(throws: WorldOpenError.needsWorldFolder) {
                try await opened.apply(snapshot: .dimension(unreadableReplacement), previous: nil)
            }
            #expect(opened.openingFailure == nil && opened.session === session)
            #expect(!session.resources.isClosed)
        } catch {
            await close()
            throw error
        }
        await close()
    }

    @Test(arguments: [false, true], [CGFloat(640), 900])
    func inspectorFitsAndZoomsAfterShrinking(_ showsNotice: Bool, _ width: CGFloat) async throws {
        try await checkWindow(width: width, showsNotice: showsNotice, opensInspector: true, tabbed: true)
    }

    @Test func zoomWithoutOpeningInspector() async throws {
        try await checkWindow(width: 640, showsNotice: false, opensInspector: false, tabbed: true)
    }

    @Test func inspectorWithoutTabs() async throws {
        try await checkWindow(width: 640, showsNotice: false, opensInspector: true, tabbed: false)
    }

    private func checkWindow(width: CGFloat, showsNotice: Bool, opensInspector: Bool, tabbed: Bool) async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let game = try ItemPictureFixture(extraFiles: ["version.json": ItemPictureFixture.json([
            "id": "Layout Test Release", "world_version": 6_000, "stable": true
        ])])
        defer { game.remove() }
        let levelURL = root.appendingPathComponent("level.dat")
        var fields = try #require(try NBT.read(contentsOf: levelURL)["Data"]?.compound)
        fields["DataVersion"] = .int(6_001)
        fields["Version"] = .compound(["Name": .string("Layout Test Snapshot")])
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound(fields)]), to: levelURL)
        let world = try World(contentsOf: root)
        let dimension = try #require(world.dimension("minecraft:overworld"))
            .documentURL(inWorldAt: root).resolvingSymlinksInPath()
        let model = AppModel(defaults: TestDefaults.make(), cacheRoot: nil)
        try model.worldFolders.remember(root)
        let (createdDocuments, created) = AsyncStream.makeStream(of: Result<WorldDocument, any Error>.self)
        defer { created.finish() }
        try #require(TestDocumentWindows.makeDocument == nil)
        TestDocumentWindows.makeDocument = { configuration in
            let result = Result {
                // SwiftUI supplies the URL after constructing its document.
                try #require(configuration.fileURL == nil || configuration.fileURL?.resolvingSymlinksInPath() == dimension)
                return WorldDocument(configuration: configuration, model: model)
            }
            created.yield(result)
            return try result.get()
        }
        defer { TestDocumentWindows.makeDocument = nil }
        let (native, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
        defer { native.close() }
        #expect(!alreadyOpen)
        try #require(native.fileURL?.resolvingSymlinksInPath() == dimension)
        // AppKit's opener returns before SwiftUI creates and reads its document.
        var createdIterator = createdDocuments.makeAsyncIterator()
        let document = try #require(await createdIterator.next()).get()
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        defer { changed.finish() }
        var changeIterator = changes.makeAsyncIterator()
        while document.session == nil {
            _ = withObservationTracking { document.session } onChange: { changed.yield(()) }
            guard await changeIterator.next() != nil else { throw CancellationError() }
        }
        let session = try #require(document.session)
        try #require(document.configuration.fileURL?.resolvingSymlinksInPath() == dimension)
        defer { session.close() }
        if showsNotice {
            model.names.minecraft.choose(game.root)
            await session.resources.waitForRefresh()
        }
        #expect((session.resources.newerWorldBanner != nil) == showsNotice)
        let window = try #require(native.windowControllers.first?.window)
        let content = try #require(window.contentView)
        // A second disposable tab shows native tab chrome without changing Show Tab Bar's
        // persistent user preference. The reported crash used a tabbed document window.
        let otherTab = NSWindow(contentRect: window.frame, styleMask: window.styleMask,
                                backing: .buffered, defer: false)
        otherTab.isReleasedWhenClosed = false
        otherTab.isRestorable = false
        otherTab.tabbingIdentifier = window.tabbingIdentifier
        if tabbed {
            window.addTabbedWindow(otherTab, ordered: .above)
            window.tabGroup?.selectedWindow = window
        } else {
            window.tabbingMode = .disallowed
        }
        defer { otherTab.close() }
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect((window.tabGroup?.isTabBarVisible == true) == tabbed)
        print("Document window initial: \(type(of: window)), frame=\(window.frame), minimum=\(window.contentMinSize), tabs=\(window.tabGroup?.isTabBarVisible == true), key=\(window.isKeyWindow), active=\(NSApp.isActive)")
        let closedMinimum = window.contentMinSize
        #expect(closedMinimum.width <= 640)
        let smallSize = CGSize(width: max(width, closedMinimum.width), height: closedMinimum.height)
        window.setContentSize(smallSize)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(window.contentLayoutRect.height <= WorldView.minimumContentSize.height + 1)
        print("Document window at minimum: frame=\(window.frame)")

        func animate(_ change: () -> Void) async {
            await withCheckedContinuation { continuation in
                withAnimation(.default, completionCriteria: .removed, change) {
                    continuation.resume()
                }
            }
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func splitViews(in view: NSView) -> [NSSplitView] {
            let own = (view as? NSSplitView).map { [$0] } ?? []
            return own + view.subviews.flatMap { splitViews(in: $0) }
        }
        func checkColumns(inspectorShown: Bool = false) throws {
            let splits = splitViews(in: content)
            #expect(!splits.isEmpty)
            let items = splits.flatMap { ($0.delegate as? NSSplitViewController)?.splitViewItems ?? [] }
            let inspector = items.first { $0.behavior == .inspector }
            #expect((inspector?.isCollapsed == false) == inspectorShown)
            if inspectorShown {
                #expect(try #require(inspector).viewController.view.frame.width >= 320)
            }
            for split in splits where !split.isHiddenOrHasHiddenAncestor {
                for view in [split] + split.arrangedSubviews where !view.isHiddenOrHasHiddenAncestor {
                    let bounds = view.convert(view.bounds, to: content)
                    #expect(content.bounds.insetBy(dx: -1, dy: -1).contains(bounds),
                            "Column \(bounds) must fit within \(content.bounds)")
                }
            }
        }
        if opensInspector {
            await animate { session.selection.inspector = .world }
            print("Document inspector opened: frame=\(window.frame), minimum=\(window.contentMinSize)")
            try checkColumns(inspectorShown: true)
            let place = try #require(session.savedPlaces.add(name: "Window Test", dimension: "minecraft:overworld", at: .zero))
            await animate { session.selection.choose(.savedPlace(place.id)) }
            try checkColumns(inspectorShown: true)
            await animate { session.selection.inspector = nil }
            try checkColumns()
            #expect(window.contentMinSize.width <= closedMinimum.width + 1)
            // Revisit the original small size after the inspector made the window larger.
            window.setContentSize(smallSize)
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try checkColumns()
        }
        let beforeZoom = window.frame
        print("Document before Zoom: inspectorUsed=\(opensInspector), frame=\(beforeZoom)")
        window.performZoom(nil)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print("Document after Zoom: frame=\(window.frame)")
        #expect(window.frame != beforeZoom)
        try checkColumns()
        session.close()
        await session.waitUntilClosed()
        await model.names.minecraft.waitUntilIdle()
    }
}
