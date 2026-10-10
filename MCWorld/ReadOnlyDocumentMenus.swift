import AppKit

/// SwiftUI groups Close with Save and has no separate placements for Rename and Move.
/// Keep the native document commands and remove only actions that edit a world folder.
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

    func applicationWillUpdate(_ notification: Notification) {
        guard let fileMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.action == #selector(NSDocumentController.openDocument(_:)) }
        }) else { return }
        for item in fileMenu.items where Self.editsDocument(item) {
            fileMenu.removeItem(item)
        }
    }

    private static func editsDocument(_ item: NSMenuItem) -> Bool {
        if let action = item.action, editingActions.contains(action) { return true }
        return item.submenu?.items.contains(where: editsDocument) == true
    }
}
