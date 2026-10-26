import SwiftUI

private struct SidebarPlainClickKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var sidebarPlainClick: Bool {
        get { self[SidebarPlainClickKey.self] }
        set { self[SidebarPlainClickKey.self] = newValue }
    }
}

/// List's binding handles a new selection. This adds an action only to its selected label,
/// leaving modified clicks and sibling controls such as visibility buttons to the List.
private struct SidebarReselection: ViewModifier {
    let item: SidebarItem
    let selection: SelectionModel
    @Environment(\.sidebarPlainClick) private var isPlainClick

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { selection.repeatSelection(item) },
                                 isEnabled: isPlainClick && selection.sidebarSelection == item)
    }
}

extension View {
    func repeatSidebarSelection(_ item: SidebarItem, in selection: SelectionModel) -> some View {
        modifier(SidebarReselection(item: item, selection: selection))
    }
}
