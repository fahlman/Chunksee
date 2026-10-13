import AppKit
import Observation
import SwiftUI

/// The AppKit boundary identifies the active tab for SwiftUI's menu commands.
@Observable
final class WorldWindowContext {
    private(set) weak var focusedSession: WorldSession?
    @ObservationIgnored private var entries: [ObjectIdentifier: Entry] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private final class Entry {
        weak var window: NSWindow?
        weak var session: WorldSession?
        init(_ window: NSWindow, _ session: WorldSession) { self.window = window; self.session = session }
    }

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }

    }

    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func register(_ window: NSWindow, session: WorldSession) {
        entries[ObjectIdentifier(window)] = Entry(window, session)
        session.invalidateRestorableState = { [weak window] in window?.invalidateRestorableState() }
        update()
    }

    func unregister(_ window: NSWindow) {
        entries[ObjectIdentifier(window)] = nil
        update()
    }

    private func update() {
        entries = entries.filter { $0.value.window != nil && $0.value.session != nil }
        for entry in entries.values {
            guard let window = entry.window, let session = entry.session else { continue }
            session.isKeyWindow = window.isKeyWindow
            let selected = window.tabGroup.map { $0.selectedWindow === window } ?? true
            session.isVisible = selected && window.isVisible && window.occlusionState.contains(.visible)
        }
        focusedSession = NSApp.mainWindow.flatMap { entries[ObjectIdentifier($0)]?.session }
        if let session = focusedSession, !session.isClosed {
            session.resources.activeDimensionID = session.selectedDimensionID
            session.saveView()
        }
    }
}

/// Every document window uses the same controller, hosting SwiftUI content in a native
/// window. AppKit manages its tab actions, document lifetime and restoration.
@objc(ChunkseeDimensionWindowController)
final class DimensionWindowController: NSWindowController {
    private(set) var session: WorldSession
    let dimension: String
    private let hosting: NSHostingController<AnyView>
    private static let dimensionKey = "Chunksee.dimension"
    private static let viewportKey = "Chunksee.viewport"

    init(session: WorldSession, identifier: NSUserInterfaceItemIdentifier?) {
        self.session = session
        dimension = session.selectedDimensionID ?? ""
        hosting = NSHostingController(rootView: AnyView(WorldView(session: session).frame(minWidth: 640, minHeight: 420)))
        hosting.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: hosting)
        window.styleMask.insert([.closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.toolbarStyle = .unified
        window.setContentSize(NSApp.mainWindow?.contentView?.bounds.size ?? CGSize(width: 1200, height: 800))
        window.minSize = CGSize(width: 640, height: 420)
        window.identifier = identifier ?? NSUserInterfaceItemIdentifier("Chunksee.dimension." + UUID().uuidString)
        window.isRestorable = true
        window.tab.title = session.dimensionName(dimension)
        window.tab.toolTip = session.displayName + " — " + window.tab.title
        super.init(window: window)
        shouldCloseDocument = false
        AppModel.shared.windows.register(window, session: session)
    }

    required init?(coder: NSCoder) { nil }

    func replaceSession(_ session: WorldSession) {
        self.session = session
        hosting.rootView = AnyView(WorldView(session: session).frame(minWidth: 640, minHeight: 420))
        if let window { AppModel.shared.windows.register(window, session: session) }
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(dimension as NSString, forKey: Self.dimensionKey)
        if let viewport = session.map?.viewport,
           let data = try? JSONEncoder().encode([Double(viewport.center.x), Double(viewport.center.y), Double(viewport.scale)]) {
            coder.encode(data as NSData, forKey: Self.viewportKey)
        }
    }

    static func dimension(from state: NSCoder) -> String? {
        state.decodeObject(of: NSString.self, forKey: dimensionKey) as String?
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard let data = coder.decodeObject(of: NSData.self, forKey: Self.viewportKey) as Data?,
              let values = try? JSONDecoder().decode([Double].self, from: data), values.count == 3,
              values.allSatisfy(\.isFinite) else { return }
        session.map?.viewport = MapViewport(center: CGPoint(x: values[0], y: values[1]), scale: values[2])
    }
}
