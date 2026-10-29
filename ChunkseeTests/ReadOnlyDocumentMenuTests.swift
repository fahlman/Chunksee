import AppKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct ReadOnlyDocumentMenuTests {
    @Test(arguments: [false, true])
    func menuNotificationsDoNotMutateAnInProgressNativeUpdate(replacesMenu: Bool) async throws {
        let initial = DocumentMenuFixture()
        let selected = replacesMenu ? DocumentMenuFixture() : initial
        var currentMenu = initial.bar
        // Native window updates can replace NSApp.mainMenu while a test is suspended.
        // Exercise the real queued filter against menus this test alone owns.
        let menus = ReadOnlyDocumentMenus(mainMenu: { currentMenu })
        let completion = MenuFilteringCompletion(menu: selected.file, items: selected.protected)
        defer { completion.finish() }

        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: initial.file)
        menus.applicationWillUpdate(Notification(name: NSApplication.willUpdateNotification))
        #expect(initial.protected.allSatisfy { !$0.isHidden && $0.allowsKeyEquivalentWhenHidden })
        #expect(selected.protected.allSatisfy { !$0.isHidden && $0.allowsKeyEquivalentWhenHidden })
        // A replacement must be resolved during the deferred pass, not captured at scheduling.
        currentMenu = selected.bar
        var changes = completion.changes.makeAsyncIterator()
        try #require(await changes.next() != nil)
        #expect(selected.protected.allSatisfy { $0.isHidden && !$0.allowsKeyEquivalentWhenHidden })
        #expect(selected.native.allSatisfy { !$0.isHidden })
        if replacesMenu {
            #expect(initial.protected.allSatisfy { !$0.isHidden && $0.allowsKeyEquivalentWhenHidden })
            #expect(initial.native.allSatisfy { !$0.isHidden })
        }
        // Keep the bridge alive through its queued pass, just as the app delegate is.
        withExtendedLifetime(menus) {}
    }
}

private struct DocumentMenuFixture {
    let bar = NSMenu(), file = NSMenu(title: "File")
    let native: [NSMenuItem]
    let protected: [NSMenuItem]

    init() {
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file; bar.addItem(fileItem)
        let nativeActions = [#selector(NSDocumentController.openDocument(_:)),
                             #selector(NSWindow.performClose(_:)), #selector(NSDocumentController.closeAllDocuments(withDelegate:didCloseAllSelector:contextInfo:))]
        let editingActions = [#selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)),
                              #selector(NSDocument.duplicate(_:)), #selector(NSDocument.rename(_:)),
                              #selector(NSDocument.move(_:)), #selector(NSDocument.revertToSaved(_:))]
        native = nativeActions.map { NSMenuItem(title: NSStringFromSelector($0), action: $0, keyEquivalent: "") }
        let editing = editingActions.map { NSMenuItem(title: NSStringFromSelector($0), action: $0, keyEquivalent: "") }
        for item in native + editing { file.addItem(item) }
        let versions = NSMenuItem(title: "Versions", action: nil, keyEquivalent: "")
        versions.submenu = NSMenu(title: "Versions"); file.addItem(versions)
        protected = editing + [versions]
        for item in protected { item.allowsKeyEquivalentWhenHidden = true }
    }
}

private final class MenuFilteringCompletion: NSObject {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let items: [NSMenuItem]

    init(menu: NSMenu, items: [NSMenuItem]) {
        self.items = items
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: NSMenu.didChangeItemNotification, object: menu)
    }

    func finish() {
        NotificationCenter.default.removeObserver(self)
        continuation.finish()
    }

    @objc func changed(_ notification: Notification) {
        // Completion comes from the actual resulting menu changes, not a delay.
        guard items.allSatisfy({ $0.isHidden && !$0.allowsKeyEquivalentWhenHidden }) else { return }
        continuation.yield(())
        continuation.finish()
    }
}
