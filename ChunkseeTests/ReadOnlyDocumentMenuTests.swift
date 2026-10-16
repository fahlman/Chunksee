import AppKit
import Testing
@testable import Chunksee

@Suite struct ReadOnlyDocumentMenuTests {
    @Test func menuNotificationsDoNotMutateAnInProgressNativeUpdate() async {
        let original = NSApp.mainMenu
        defer { NSApp.mainMenu = original }
        let bar = NSMenu(), file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file; bar.addItem(fileItem)
        let nativeActions = [#selector(NSDocumentController.openDocument(_:)),
                             #selector(NSWindow.performClose(_:)), #selector(NSDocumentController.closeAllDocuments(withDelegate:didCloseAllSelector:contextInfo:))]
        let editingActions = [#selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)),
                              #selector(NSDocument.duplicate(_:)), #selector(NSDocument.rename(_:)),
                              #selector(NSDocument.move(_:)), #selector(NSDocument.revertToSaved(_:))]
        let native = nativeActions.map { NSMenuItem(title: NSStringFromSelector($0), action: $0, keyEquivalent: "") }
        let editing = editingActions.map { NSMenuItem(title: NSStringFromSelector($0), action: $0, keyEquivalent: "") }
        for item in native + editing { file.addItem(item) }
        let versions = NSMenuItem(title: "Versions", action: nil, keyEquivalent: "")
        versions.submenu = NSMenu(title: "Versions"); file.addItem(versions)
        let protected = editing + [versions]
        for item in protected { item.allowsKeyEquivalentWhenHidden = true }
        NSApp.mainMenu = bar

        let menus = ReadOnlyDocumentMenus()
        let completion = MenuFilteringCompletion(items: protected)
        defer { NotificationCenter.default.removeObserver(completion) }
        await withCheckedContinuation { continuation in
            completion.continuation = continuation
            NotificationCenter.default.addObserver(completion, selector: #selector(MenuFilteringCompletion.changed),
                                                   name: NSMenu.didChangeItemNotification, object: file)
            // This is the notification that used to hide items synchronously inside AppKit's
            // own update. Completion comes from the actual resulting menu changes, not a delay.
            NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: file)
            menus.applicationWillUpdate(Notification(name: NSApplication.willUpdateNotification))
            #expect(protected.allSatisfy { !$0.isHidden })
        }
        #expect(protected.allSatisfy { $0.isHidden && !$0.allowsKeyEquivalentWhenHidden })
        #expect(native.allSatisfy { !$0.isHidden })
        // Keep the bridge alive through its queued pass, just as the app delegate is.
        withExtendedLifetime(menus) {}
    }
}

private final class MenuFilteringCompletion: NSObject {
    let items: [NSMenuItem]
    var continuation: CheckedContinuation<Void, Never>?

    init(items: [NSMenuItem]) { self.items = items }

    @objc func changed(_ notification: Notification) {
        guard items.allSatisfy({ $0.isHidden && !$0.allowsKeyEquivalentWhenHidden }),
              let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}
