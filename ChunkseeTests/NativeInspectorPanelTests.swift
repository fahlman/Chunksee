import AppKit
import ChunkseeKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Diagnostic only: compare the two recorded opening histories on identical native hosts.
@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(2)))
struct NativeInspectorPanelTests {
    @Test func diagnosesSiblingInspectorPanel() async throws {
        for history in ["original", "reopened"] {
            try await checkHistory(history)
        }
    }

    private func checkHistory(_ history: String) async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["the_end", "the_nether"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/minecraft/\(name)/region"),
                                                    withIntermediateDirectories: true)
        }
        let world = try World(contentsOf: root)
        func url(_ name: String) throws -> URL {
            try #require(world.dimension("minecraft:\(name)"))
                .documentURL(inWorldAt: root).resolvingSymlinksInPath()
        }
        let overworldURL = try url("overworld"), endURL = try url("the_end"), netherURL = try url("the_nether")
        let model = AppModel(defaults: TestDefaults.make(), cacheRoot: nil)
        try model.worldFolders.remember(root)
        let (documents, created) = AsyncStream.makeStream(of: DocumentReference.self)
        defer { created.finish() }
        var iterator = documents.makeAsyncIterator()
        var references: [DocumentReference] = []
        try #require(TestDocumentWindows.makeDocument == nil)
        TestDocumentWindows.makeDocument = { configuration in
            let document = WorldDocument(configuration: configuration, model: model)
            let reference = DocumentReference(document)
            references.append(reference)
            created.yield(reference)
            return document
        }
        defer { TestDocumentWindows.makeDocument = nil }

        func record(_ fields: [String: Any]) throws {
            var fields = fields
            fields["history"] = history
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            // The supervisor's single foreground request must see the wait before the test exits.
            FileHandle.standardOutput.write(Data("Inspector panel diagnostic: ".utf8) + data + Data([10]))
        }
        func open(_ url: URL) async throws -> DocumentReference {
            try record(["event": "open", "dimension": url.lastPathComponent])
            let (native, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
            try #require(!reused)
            let reference = try #require(await iterator.next(isolation: #isolation))
            reference.native = native
            let document = try #require(reference.document)
            for await _ in Observations<Void, Never>.untilFinished({ [weak document] in
                guard let document else { return .finish }
                return document.session == nil && document.openingFailure == nil ? .next(()) : .finish
            }) {}
            try #require(document.openingFailure == nil && document.session != nil)
            try #require(native.fileURL?.resolvingSymlinksInPath() == url)
            try #require(document.configuration.fileURL?.resolvingSymlinksInPath() == url)
            reference.session = document.session
            reference.window = try #require(native.windowControllers.first?.window)
            return reference
        }
        func join(_ sibling: DocumentReference, to first: DocumentReference) throws {
            let window = try #require(first.window), other = try #require(sibling.window)
            let automatic = window.tabbedWindows?.contains(where: { $0 === other }) == true
            try record(["event": "join", "automatic": automatic])
            if !automatic { window.addTabbedWindow(other, ordered: .above) }
            try #require(window.tabbedWindows?.contains(where: { $0 === other }) == true)
        }
        func activate(_ reference: DocumentReference, phase: String, perform: () throws -> Void = {}) async throws {
            let window = try #require(reference.window), session = try #require(reference.document?.session)
            let (updates, updated) = AsyncStream.makeStream(of: Void.self)
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                object: window, queue: .main) { _ in updated.yield(()) }
            let focus = ModelObservation(session.resources, isActive: { !$0.isClosed },
                read: { $0.activeDimensionID }) { _, _ in updated.yield(()) }
            defer {
                NotificationCenter.default.removeObserver(observer)
                focus.cancel()
                updated.finish()
            }
            try perform()
            window.tabGroup?.selectedWindow = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.viewsNeedDisplay = true
            try record(["event": "awaiting-activation", "phase": phase,
                        "dimension": session.selectedDimensionID ?? "nil", "appActive": NSApp.isActive])
            // Read real focus and appearance after a native update; never wait for the desired
            // inspector result, which would hide a failure behind a readiness timeout.
            for await _ in updates {
                guard NSApp.isActive, window.isKeyWindow, window.isMainWindow,
                      session.resources.activeDimensionID == session.selectedDimensionID,
                      session.routing.openDocument != nil else { continue }
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let items = Self.splitItems(in: try #require(window.contentView))
                guard !items.isEmpty else { continue }
                try record(["event": "activated", "phase": phase,
                            "dimension": session.selectedDimensionID ?? "nil", "window": window.windowNumber,
                            "storageSelected": session.selection.sidebarSelection == .storage,
                            "modelShown": session.selection.isInspectorShown,
                            "collapsed": items.first { $0.behavior == .inspector }?.isCollapsed as Any? ?? NSNull()])
                return
            }
            throw CancellationError()
        }
        func close(_ target: DocumentReference, beside survivor: DocumentReference, phase: String) async throws {
            try await activate(target, phase: phase + "-target")
            let window = try #require(target.window), native = try #require(target.native)
            let targetURL = try #require(native.fileURL)
            try #require(NSApp.keyWindow === window && window.isMainWindow)
            try #require(window.tabGroup?.selectedWindow === window)
            try #require(NSDocumentController.shared.document(for: targetURL) === native)
            try record(["event": "close-target", "phase": phase,
                        "dimension": targetURL.lastPathComponent, "window": window.windowNumber])
            let group = window.tabGroup
            try await activate(survivor, phase: phase + "-survivor") {
                window.performClose(nil)
                let survivorWindow = try #require(survivor.window)
                try record(["event": "native-close-choice", "phase": phase,
                            "targetWindow": window.windowNumber, "survivorWindow": survivorWindow.windowNumber,
                            "selectedWindow": group?.selectedWindow?.windowNumber ?? -1,
                            "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
                            "selectedSurvivor": group?.selectedWindow === survivorWindow,
                            "keySurvivor": NSApp.keyWindow === survivorWindow,
                            "targetVisible": window.isVisible])
            }
            try #require(NSDocumentController.shared.document(for: targetURL) == nil)
            try #require(!window.isVisible)
            try #require(survivor.window?.tabbedWindows?.contains(where: { $0 === window }) != true)
            try record(["event": "closed", "phase": phase, "removedFromControllerAndTabs": true])
        }
        func cleanup() async {
            let sessions = references.compactMap { $0.session ?? $0.document?.session }
            references.forEach { $0.native?.close() }
            for session in sessions {
                session.close()
                await session.waitUntilClosed()
            }
            await model.names.minecraft.waitUntilIdle()
        }
        do {
            let end = try await open(endURL), nether = try await open(netherURL)
            var overworld = try await open(overworldURL)
            try join(nether, to: end)
            try join(overworld, to: end)
            try await activate(overworld, phase: "initial-overworld")
            if history == "reopened" {
                try await close(overworld, beside: nether, phase: "setup-overworld")
                try await close(nether, beside: end, phase: "setup-nether")
                overworld = try await open(overworldURL)
                try join(overworld, to: end)
                try await activate(overworld, phase: "reopened-overworld")
            } else {
                try await close(nether, beside: overworld, phase: "setup-nether")
            }
            let originalSession = ObjectIdentifier(try #require(overworld.document?.session))
            let originalSelection = ObjectIdentifier(try #require(overworld.document?.session?.selection))
            let originalResources = ObjectIdentifier(try #require(overworld.document?.session?.resources))
            let originalNative = ObjectIdentifier(try #require(overworld.native))
            let originalWindow = ObjectIdentifier(try #require(overworld.window))
            try #require(end.document?.session?.resources === overworld.document?.session?.resources)
            let session = try #require(overworld.document?.session)
            await withCheckedContinuation { continuation in
                withAnimation(.default, completionCriteria: .removed) {
                    session.selection.choose(.storage)
                } completion: { continuation.resume() }
            }

            func sample(_ phase: String, prerequisite: Bool = false) throws {
                let native = try #require(overworld.native), window = try #require(overworld.window)
                let current = try #require(overworld.document?.session), content = try #require(window.contentView)
                try #require(NSApp.isActive && window.isKeyWindow && window.isMainWindow)
                try #require(current.resources.activeDimensionID == current.selectedDimensionID)
                try #require(NSDocumentController.shared.document(for: overworldURL) === native)
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let inspectors = Self.splitItems(in: content).filter { $0.behavior == .inspector }
                let item = inspectors.first
                let visible = inspectors.count == 1 && item?.isCollapsed == false
                    && item?.viewController.view.isHiddenOrHasHiddenAncestor == false
                    && (item?.viewController.view.frame.width ?? 0) >= 320
                let identitiesMatch = ObjectIdentifier(current) == originalSession
                    && ObjectIdentifier(current.selection) == originalSelection
                    && ObjectIdentifier(current.resources) == originalResources
                    && ObjectIdentifier(native) == originalNative && ObjectIdentifier(window) == originalWindow
                let selected = current.selection.sidebarSelection == .storage
                let shown = current.selection.isInspectorShown && current.selection.inspector == .storage
                try record(["event": "sample", "phase": phase, "window": window.windowNumber,
                            "session": String(describing: ObjectIdentifier(current)),
                            "selection": String(describing: ObjectIdentifier(current.selection)),
                            "resources": String(describing: ObjectIdentifier(current.resources)),
                            "native": String(describing: ObjectIdentifier(native)),
                            "identitiesMatch": identitiesMatch, "storageSelected": selected, "modelShown": shown,
                            "inspectorCount": inspectors.count, "nativeVisible": visible,
                            "collapsed": item?.isCollapsed as Any? ?? NSNull(),
                            "inspectorFrame": item.map { NSStringFromRect($0.viewController.view.frame) } ?? "absent",
                            "sessionClosed": current.isClosed, "resourcesClosed": current.resources.isClosed,
                            "active": NSApp.isActive, "key": window.isKeyWindow, "main": window.isMainWindow])
                if prerequisite { try #require(visible && selected && shown && identitiesMatch) }
                #expect(visible && selected && shown && identitiesMatch && !current.isClosed && !current.resources.isClosed)
            }
            try sample("storage-before", prerequisite: true)
            try await close(end, beside: overworld, phase: "end")
            try sample("after-end-close")
            let reopened = try await open(endURL)
            try join(reopened, to: overworld)
            try await activate(reopened, phase: "reopened-end")
            try await activate(overworld, phase: "after-end-reopen")
            try sample("after-end-reopen")
            try #require(reopened.document?.session?.resources === overworld.document?.session?.resources)
            try #require(references.count == (history == "original" ? 4 : 5))
            try record(["event": "history-complete", "documents": references.count])
        } catch {
            await cleanup()
            try? record(["event": "cleanup", "completed": false, "error": String(describing: error)])
            throw error
        }
        await cleanup()
        try record(["event": "cleanup", "completed": true])
    }

    private static func splitItems(in view: NSView) -> [NSSplitViewItem] {
        let own = (view as? NSSplitView).flatMap { $0.delegate as? NSSplitViewController }?.splitViewItems ?? []
        return own + view.subviews.flatMap { splitItems(in: $0) }
    }

    /// Opening and closing must use native ownership, not a fixture that keeps old scenes alive.
    private final class DocumentReference {
        weak var document: WorldDocument?
        weak var native: NSDocument?
        weak var window: NSWindow?
        weak var session: WorldSession?
        init(_ document: WorldDocument) { self.document = document }
    }
}
