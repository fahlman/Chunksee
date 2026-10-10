import AppKit

/// SwiftUI groups Close with Save and has no separate placements for Rename and Move.
/// Keep native document commands and hide only actions that edit a world folder.
final class ReadOnlyDocumentMenus: NSObject, NSApplicationDelegate {
    private static let editingActions: Set<Selector> = [
        #selector(NSDocument.save(_:)),
        #selector(NSDocument.saveAs(_:)),
        #selector(NSDocument.duplicate(_:)),
        #selector(NSDocument.rename(_:)),
        #selector(NSDocument.move(_:)),
        #selector(NSDocument.revertToSaved(_:)),
        #selector(NSDocument.browseVersions(_:))
    ]

    override init() {
        super.init()
        // SwiftUI and AppKit update document items when opening menus and changing windows.
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuItemsChanged), name: name, object: nil)
        }
    }

    func applicationWillUpdate(_ notification: Notification) { hideEditingCommands() }

    @objc private func menuItemsChanged(_ notification: Notification) { hideEditingCommands() }

    private func hideEditingCommands() {
        guard let fileMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.action == #selector(NSDocumentController.openDocument(_:)) }
        }) else { return }
        var followsRevert = false
        for item in fileMenu.items {
            // AppKit inserts the lazily populated Versions submenu immediately after
            // Revert to Saved. Before it is populated, it has no editing child to match.
            let isVersionsMenu = followsRevert && item.submenu != nil
            followsRevert = item.action == #selector(NSDocument.revertToSaved(_:))
            guard isVersionsMenu || Self.editsDocument(item) else { continue }
            // Hiding leaves SwiftUI's item indexes intact. Only change a value when needed,
            // because both setters notify observers, including this hook.
            if !item.isHidden { item.isHidden = true }
            if item.allowsKeyEquivalentWhenHidden { item.allowsKeyEquivalentWhenHidden = false }
        }
    }

    private static func editsDocument(_ item: NSMenuItem) -> Bool {
        if let action = item.action, editingActions.contains(action) { return true }
        return item.submenu?.items.contains(where: editsDocument) == true
    }
}
