import AppKit
import SwiftUI

/// Scroll-wheel and trackpad-scroll input for the map.
///
/// AppKit is used because SwiftUI on macOS 27 has no scroll-wheel input for arbitrary views
/// (`SpatialEventGesture` carries no scroll deltas, and scroll modifiers apply only to scroll
/// views). A local event monitor sees scroll events in this app's windows; it handles only those
/// over the map's frame and passes everything else through untouched.
struct ScrollWheelInput: ViewModifier {
    enum Action: Equatable {
        /// Move the map with the fingers (trackpad two-finger scroll), in points.
        case pan(CGSize)
        /// Zoom by a factor around a point in the view (⌘-scroll, or a mouse wheel).
        case zoom(factor: CGFloat, anchor: CGPoint)
    }

    let perform: (Action) -> Void

    @State private var monitor: Any?
    @State private var frameInWindow: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frameInWindow = $0 }
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event was used by the map.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, let contentView = window.contentView else { return false }
        // AppKit window coordinates start at the bottom left; SwiftUI's global space at the top left.
        let p = event.locationInWindow
        let point = CGPoint(x: p.x, y: contentView.bounds.height - p.y)
        guard frameInWindow.contains(point) else { return false }
        let local = CGPoint(x: point.x - frameInWindow.minX, y: point.y - frameInWindow.minY)

        if let action = Self.action(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                    isTrackpad: event.hasPreciseScrollingDeltas,
                                    command: event.modifierFlags.contains(.command), at: local) {
            perform(action)
        }
        return true
    }

    /// What a scroll does: a trackpad scroll pans with the fingers; ⌘-scroll or a mouse wheel zooms
    /// around the pointer. Trackpad deltas are in points and wheel deltas in lines, so they're scaled
    /// to zoom at similar rates.
    static func action(deltaX: CGFloat, deltaY: CGFloat, isTrackpad: Bool, command: Bool, at anchor: CGPoint) -> Action? {
        if isTrackpad && !command {
            return .pan(CGSize(width: deltaX, height: deltaY))
        }
        let delta = isTrackpad ? deltaY / 200 : deltaY / 10
        guard delta != 0 else { return nil }
        return .zoom(factor: exp(delta), anchor: anchor)
    }
}

extension View {
    func scrollWheelInput(perform: @escaping (ScrollWheelInput.Action) -> Void) -> some View {
        modifier(ScrollWheelInput(perform: perform))
    }
}
