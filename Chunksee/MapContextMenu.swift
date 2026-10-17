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
    private static var requests: [NSPasteboard.Name: UUID] = [:]

    /// Every Copy Coordinates action comes here. A marker supplies its saved Y; other locations
    /// use the block actually drawn by this map. A late read cannot replace a newer clipboard.
    static func copy(_ point: CGPoint, y: Double? = nil, on map: MapModel, to pasteboard: NSPasteboard = .general) {
        guard let coordinates = MapCoordinates(point: point) else { return }
        let id = UUID(), changeCount = pasteboard.changeCount
        requests[pasteboard.name] = id
        func finish(_ y: Int?) {
            guard requests[pasteboard.name] == id else { return }
            requests[pasteboard.name] = nil
            guard pasteboard.changeCount == changeCount else { return }
            guard let y else { NSSound.beep(); return }
            pasteboard.clearContents()
            pasteboard.setString("\(coordinates.x) \(y) \(coordinates.z)", forType: .string)
        }
        if let y {
            finish(Int(exactly: y.rounded(.down)))
        } else {
            map.readTopBlock(at: coordinates.position) { finish($0?.y) }
        }
    }
}
