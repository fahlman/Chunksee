import AppKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .serialized) struct DocumentTitleTests {
    @Test(.timeLimit(.minutes(1))) func displayNamesUpdateNativeTitlesWithoutChangingDocumentURLs() async {
        let document = NSDocument()
        let url = URL(fileURLWithPath: "/tmp/Title Fixture/dimensions/mod_a/caves")
        document.fileURL = url
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        document.addWindowController(controller)
        defer { document.close() }
        let view = DocumentWindowTitle.TitleView()
        view.title = "Caves (mod_a:caves)"
        window.contentView = view
        #expect(document.displayName == "Caves (mod_a:caves)")
        #expect(window.title == "Caves (mod_a:caves)")
        #expect(window.tab.title == window.title)
        #expect(document.fileURL == url)
        let (names, continuation) = AsyncStream<String>.makeStream()
        let observation = document.observe(\.displayName, options: [.new]) { _, change in
            if let name = change.newValue { continuation.yield(name) }
        }
        defer { observation.invalidate(); continuation.finish() }
        document.displayName = "caves" // Native restoration can reset this after view attachment.
        for await name in names {
            if name == "Caves (mod_a:caves)" { break }
        }
        #expect(document.displayName == "Caves (mod_a:caves)")
        #expect(window.title == "Caves (mod_a:caves)")
        view.title = "Caves"
        #expect(window.title == "Caves")
        #expect(document.fileURL == url)
        #expect(!document.isDocumentEdited)
    }

    @Test func closingTheWindowReleasesTheTitleViewAndStopsChangingItsDocument() {
        let document = NSDocument()
        weak var releasedView: DocumentWindowTitle.TitleView?
        autoreleasepool {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            document.addWindowController(NSWindowController(window: window))
            let view = DocumentWindowTitle.TitleView()
            view.title = "The Nether"
            window.contentView = view
            releasedView = view
            document.close()
        }
        #expect(releasedView == nil)
        document.displayName = "Folder"
        #expect(document.displayName == "Folder")
    }
}
