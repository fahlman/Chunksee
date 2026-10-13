import AppKit

/// The native document controller supplies the folder Open panel, recents and restoration.
final class WorldDocumentController: NSDocumentController {
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.treatsFilePackagesAsDirectories = true
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }
}

/// Keep the standard native File menu limited to viewing documents. The nib's
/// system Open Recent menu is populated by AppKit, without an app-owned recent list.
final class ReadOnlyDocumentMenus: NSObject, NSApplicationDelegate {
    private let documents: NSDocumentController = {
        _ = WorldDocumentController()
        return .shared
    }()
    private var fileMenu: NSMenu?
    private var finishedRestoring = false
    private var finishedLaunching = false

    override init() {
        super.init()
        var objects: NSArray?
        NSNib(nibNamed: "DocumentMenu", bundle: .main)?.instantiate(withOwner: self, topLevelObjects: &objects)
        fileMenu = (objects as? [Any])?.compactMap { $0 as? NSMenu }.first
        NotificationCenter.default.addObserver(self, selector: #selector(finishedRestoringWindows),
                                               name: NSApplication.didFinishRestoringWindowsNotification, object: nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        installFileMenu()
        if finishedRestoring { openIfNeeded() }
    }

    func applicationWillUpdate(_ notification: Notification) { installFileMenu() }

    @objc private func finishedRestoringWindows(_ notification: Notification) {
        finishedRestoring = true
        if finishedLaunching { openIfNeeded() }
    }

    private func openIfNeeded() {
        guard documents.documents.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.documents.documents.isEmpty else { return }
            self.documents.openDocument(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if let document = documents.documents.last { document.showWindows() }
            else { documents.openDocument(nil) }
        }
        return false
    }

    @objc func closeAllDocuments(_ sender: Any?) {
        documents.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
    }

    private func installFileMenu() {
        guard let main = NSApp.mainMenu, let fileMenu else { return }
        if let item = main.items.first(where: { $0.title == "File" }) {
            if item.submenu !== fileMenu { item.submenu = fileMenu }
        } else {
            let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
            item.submenu = fileMenu
            main.insertItem(item, at: min(1, main.numberOfItems))
        }
    }
}
