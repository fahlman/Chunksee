import AppKit
import SwiftUI

/// URL-based DocumentGroup keeps the folder name even with navigationTitle on macOS 27.
/// Set only its native display name; SwiftUI still owns document URLs, windows and tabs.
struct DocumentWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title }

    final class TitleView: NSView {
        var title = "" { didSet { applyTitle() } }
        private weak var observedDocument: NSDocument?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            observedDocument = nil
            applyTitle()
        }

        private func applyTitle() {
            guard let controller = window?.windowController,
                  let document = controller.document as? NSDocument else { return }
            if observedDocument !== document {
                observedDocument = document
                // AppKit restores the native display name after attaching its content view.
                // NSDocument's UI properties and this callback are confined to the main actor.
                observation = document.observe(\.displayName) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.applyTitle() }
                }
            }
            guard !title.isEmpty, document.displayName != title else { return }
            document.displayName = title
            controller.synchronizeWindowTitleWithDocumentName()
        }
    }
}
