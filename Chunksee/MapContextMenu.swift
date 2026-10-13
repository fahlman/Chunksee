import AppKit

/// SwiftUI has no map-point argument for contextMenu. AppKit captures the native event point;
/// the owning SwiftUI map supplies actions with their world-coordinate snapshots.
struct MapContextAction {
    var title: String
    var perform: () -> Void
}

enum MapContextMenu {
    static func make(actions: [MapContextAction]) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        for action in actions {
            let target = MapContextTarget(perform: action.perform)
            let item = NSMenuItem(title: action.title, action: #selector(MapContextTarget.performAction(_:)), keyEquivalent: "")
            item.target = target
            // NSMenuItem's target is weak. Keep the handler alive for the native menu's lifetime.
            item.representedObject = target
            menu.addItem(item)
        }
        return menu
    }
}

private final class MapContextTarget: NSObject {
    private let perform: () -> Void

    init(perform: @escaping () -> Void) {
        self.perform = perform
        super.init()
    }

    @objc func performAction(_ sender: NSMenuItem) { perform() }
}

enum MapClipboard {
    static func copy(_ point: CGPoint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Coordinates.text(point), forType: .string)
    }
}
