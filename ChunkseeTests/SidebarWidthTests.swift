import AppKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized) struct SidebarWidthTests {
    @Test func nativeSidebarUsesItsIdealWidthAndEnforcesItsMinimum() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        do {
            let controller = NSHostingController(rootView: WorldView(session: session))
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(CGSize(width: 1200, height: 800))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            func splitViews(in view: NSView) -> [NSSplitView] {
                let own = (view as? NSSplitView).map { [$0] } ?? []
                return own + view.subviews.flatMap { splitViews(in: $0) }
            }
            let splits = splitViews(in: controller.view)
            let split = try #require(splits.first {
                ($0.delegate as? NSSplitViewController)?.splitViewItems.contains { $0.behavior == .sidebar } == true
            })
            let splitController = try #require(split.delegate as? NSSplitViewController)
            let item = try #require(splitController.splitViewItems.first { $0.behavior == .sidebar })
            let sidebar = item.viewController.view
            #expect(abs(sidebar.frame.width - 220) < 1)
            // Native resize constraints must reject a width below the declared minimum.
            split.setPosition(130, ofDividerAt: 0)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width >= 180)
            window.setContentSize(CGSize(width: 900, height: 600))
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width >= 180)
        } catch {
            session.close(); await session.waitUntilClosed(); throw error
        }
        session.close(); await session.waitUntilClosed()
    }
}
