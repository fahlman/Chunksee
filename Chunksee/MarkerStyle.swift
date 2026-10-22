import ChunkseeIndex
import CoreGraphics
import SwiftUI

/// Marker kinds supply only colors and an SF Symbol. All bodies, highlights and captions
/// use the same renderer; selection and dimming are shared states, not per-kind styles.
struct MarkerStyle {
    nonisolated struct Symbol: Hashable, Sendable {
        let name: String
        let color: Color
    }

    let symbol: Symbol
    let fill: Color

    static let savedPlaceSymbol = "mappin"
    static let dimmedOpacity = 0.6
    // Reuse the font provider; thousands of unlabeled spawners must not allocate one per frame.
    private static let captionFont = Font.caption2.weight(.medium)

    static func playerAppearance(_ kind: MapMarker.Kind) -> (symbol: String, color: Color) {
        switch kind {
        case .player: ("person.fill", .blue)
        case .death: ("xmark", .red)
        case .respawn: (PlaceGroup.bed.symbol, .purple)
        }
    }

    static func structure(_ group: StructureGroup) -> MarkerStyle {
        MarkerStyle(symbol: Symbol(name: group.symbol, color: .white), fill: Color(hex: group.color))
    }

    static func place(_ group: PlaceGroup) -> MarkerStyle {
        MarkerStyle(symbol: Symbol(name: group.symbol, color: .white), fill: Color(hex: group.color))
    }

    static func creature(_ group: CreatureGroup) -> MarkerStyle {
        MarkerStyle(symbol: Symbol(name: group.symbol, color: .white), fill: Color(hex: group.color))
    }

    static var savedPlace: MarkerStyle {
        MarkerStyle(symbol: Symbol(name: savedPlaceSymbol, color: .white), fill: .accentColor)
    }

    static var search: MarkerStyle {
        MarkerStyle(symbol: Symbol(name: "magnifyingglass", color: .black), fill: .yellow)
    }

    static func player(_ kind: MapMarker.Kind) -> MarkerStyle {
        let appearance = playerAppearance(kind)
        return MarkerStyle(symbol: Symbol(name: appearance.symbol, color: .white), fill: appearance.color)
    }

    func drawBody(at point: CGPoint, scale: CGFloat, selected: Bool, dimmed: Bool,
                  in context: GraphicsContext, symbol resolve: (Symbol) -> GraphicsContext.ResolvedImage) {
        var context = context
        context.opacity = dimmed ? Self.dimmedOpacity : 1
        let path = Path(ellipseIn: MarkerGeometry.frame(at: point, scale: scale))
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(selected ? .accentColor : .white.opacity(0.9)), lineWidth: selected ? 2.5 : 1)
        let side = MarkerGeometry.symbolSide(at: scale)
        context.draw(resolve(symbol), in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
    }

    /// A hidden caption must not format a name or resolve text on every frame. Every marker
    /// shows its caption from 200% zoom, or while selected; collision priority stays with its data.
    func label(_ name: @autoclosure () -> String, id: @autoclosure () -> String,
               priority: MarkerLabelLayout.Priority, at point: CGPoint, scale: CGFloat, dimmed: Bool = false,
               in context: GraphicsContext) -> MarkerLabel? {
        guard scale >= 2 || priority == .selected else { return nil }
        let text = context.resolve(Text(name()).font(Self.captionFont).foregroundStyle(symbol.color))
        let size = text.measure(in: CGSize(width: 200, height: 30))
        let label = CGRect(x: point.x - size.width / 2 - 4, y: point.y + MarkerGeometry.radius(at: scale) + 2,
                           width: size.width + 8, height: size.height + 2)
        return MarkerLabel(placement: .init(id: id(), priority: priority, frame: label), text: text,
                           background: fill.opacity(0.85), opacity: dimmed ? Self.dimmedOpacity : 1)
    }
}
