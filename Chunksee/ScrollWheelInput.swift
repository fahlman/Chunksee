import AppKit
import SwiftUI

/// SwiftUI has no arbitrary-view scroll-wheel gesture. This transparent AppKit view participates
/// in its window's normal hit testing for scroll events only; other input reaches the SwiftUI map.
struct ScrollWheelInput: NSViewRepresentable {
    enum Action: Equatable {
        case pan(CGSize)
        case zoom(factor: CGFloat, anchor: CGPoint)
    }

    let perform: (Action) -> Void

    func makeNSView(context: Context) -> MapScrollView { MapScrollView(perform: perform) }
    func updateNSView(_ view: MapScrollView, context: Context) { view.perform = perform }

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

/// Native event routing distinguishes windows and respects controls layered over the map.
final class MapScrollView: NSView {
    var perform: (ScrollWheelInput.Action) -> Void
    override var isFlipped: Bool { true }

    init(perform: @escaping (ScrollWheelInput.Action) -> Void) {
        self.perform = perform
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let action = ScrollWheelInput.action(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                               isTrackpad: event.hasPreciseScrollingDeltas,
                                               command: event.modifierFlags.contains(.command), at: point) {
            perform(action)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

extension View {
    func scrollWheelInput(perform: @escaping (ScrollWheelInput.Action) -> Void) -> some View {
        overlay { ScrollWheelInput(perform: perform).accessibilityHidden(true) }
    }
}
