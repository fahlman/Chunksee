import CoreGraphics
import SwiftUI

/// Fixed marker presentation. Geometry also owns picking; groups keep their names and palette.
/// Different label/body styles are intentional and shared by on-screen and exported drawing.
struct MarkerStyle {
    nonisolated struct Symbol: Hashable, Sendable {
        let name: String
        let color: Color
        let opacity: Double

        init(name: String, color: Color, opacity: Double = 1) {
            self.name = name
            self.color = color
            self.opacity = opacity
        }
    }

    enum Shape {
        case circle, roundedRectangle

        func path(in rect: CGRect) -> Path {
            switch self {
            case .circle: Path(ellipseIn: rect)
            case .roundedRectangle: Path(roundedRect: rect, cornerRadius: 4)
            }
        }
    }

    struct Caption {
        let font: Font
        let maximumSize: CGSize
        let padding: CGSize
        let gap: CGFloat
        let background: Color?
        let backgroundOpacity: Double
        var minimumScale: CGFloat
    }

    let geometry: MarkerGeometry
    let shape: Shape
    let symbol: Symbol
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat
    let opacity: Double
    let caption: Caption?

    // Reuse semantic fonts/layout, and create a label's translucent fill only when it is shown.
    // Thousands of unlabeled spawners must not allocate font/color providers on each frame.
    private static let badgeCaption = Caption(font: .caption2.weight(.medium), maximumSize: CGSize(width: 200, height: 30),
        padding: CGSize(width: 4, height: 1), gap: 2, background: nil, backgroundOpacity: 0.85, minimumScale: 2)
    private static let structureCaption = Caption(font: .caption2.weight(.semibold), maximumSize: CGSize(width: 240, height: 40),
        padding: CGSize(width: 5, height: 1), gap: 2, background: nil, backgroundOpacity: 0.85, minimumScale: 0.5)
    private static let playerCaption = Caption(font: .caption.weight(.semibold), maximumSize: CGSize(width: 240, height: 40),
        padding: CGSize(width: 6, height: 2), gap: 3, background: .black, backgroundOpacity: 0.6, minimumScale: 0)

    static let savedPlaceSymbol = "mappin"
    // Sidebar eligibility also dims players with no usable position. Keep its existing strength,
    // distinct from an outdated map marker and from a villager's claimed place.
    static let playerSidebarDimmedOpacity = 0.6

    static func playerAppearance(_ kind: MapMarker.Kind) -> (symbol: String, color: Color) {
        switch kind {
        case .player: ("person.fill", .blue)
        case .death: ("xmark", .red)
        case .respawn: ("bed.double.fill", .purple)
        }
    }

    static func structure(_ group: StructureGroup) -> MarkerStyle {
        let color = Color(hex: group.color)
        return MarkerStyle(geometry: .structure, shape: .roundedRectangle,
            symbol: Symbol(name: group.symbol, color: .white), fill: color, stroke: .white.opacity(0.9),
            lineWidth: 1, opacity: 1,
            caption: structureCaption)
    }

    static func place(_ group: PlaceGroup, claimed: Bool) -> MarkerStyle {
        badge(geometry: .place(isPortal: group == .portal), symbol: group.symbol, color: Color(hex: group.color),
              opacity: claimed ? 0.65 : 1)
    }

    static func creature(_ group: CreatureGroup, selected: Bool) -> MarkerStyle {
        badge(geometry: .creature(selected: selected), symbol: group.symbol, color: Color(hex: group.color),
              selected: selected, nameFrom: selected ? 0 : 2)
    }

    static var savedPlace: MarkerStyle {
        badge(geometry: .savedPlace, symbol: savedPlaceSymbol, color: .accentColor)
    }

    static func search(selected: Bool) -> MarkerStyle {
        MarkerStyle(geometry: .search(selected: selected), shape: .circle,
            symbol: Symbol(name: "magnifyingglass", color: .black), fill: .yellow, stroke: .black.opacity(0.6),
            lineWidth: selected ? 2 : 1, opacity: 1, caption: nil)
    }

    static func player(_ kind: MapMarker.Kind, outdated: Bool, selected: Bool) -> MarkerStyle {
        let appearance = playerAppearance(kind)
        return MarkerStyle(geometry: .player(kind), shape: .circle,
            // Player glyphs were resolved in their faded context, unlike the shared place
            // glyphs. Preserve that resolution state as well as the final drawing opacity.
            symbol: Symbol(name: appearance.symbol, color: .white, opacity: outdated ? 0.55 : 1), fill: appearance.color,
            stroke: selected ? .accentColor : .white, lineWidth: selected ? 2.5 : 1.5,
            opacity: outdated ? 0.55 : 1,
            caption: kind == .player ? playerCaption : nil)
    }

    private static func badge(geometry: MarkerGeometry, symbol: String, color: Color,
                              opacity: Double = 1, selected: Bool = false, nameFrom: CGFloat = 2) -> MarkerStyle {
        var caption = badgeCaption
        caption.minimumScale = nameFrom
        return MarkerStyle(geometry: geometry, shape: .circle, symbol: Symbol(name: symbol, color: .white),
            fill: color, stroke: selected ? .accentColor : .white.opacity(0.9), lineWidth: selected ? 2 : 1,
            opacity: opacity,
            caption: caption)
    }

    /// Callers keep their existing bounds tests, including structure areas and player labels.
    func drawBody(at point: CGPoint, in context: GraphicsContext,
                  symbol resolve: (Symbol) -> GraphicsContext.ResolvedImage) {
        var context = context
        context.opacity = opacity
        let radius = geometry.radius
        let path = shape.path(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
        let side = geometry.symbolSide
        context.draw(resolve(symbol), in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
    }

    /// A hidden label must not format a creature/place name or resolve text on every frame.
    func drawName(_ name: @autoclosure () -> String, at point: CGPoint, scale: CGFloat, in context: GraphicsContext) {
        guard let caption, scale >= caption.minimumScale else { return }
        var context = context
        context.opacity = opacity
        let text = context.resolve(Text(name()).font(caption.font).foregroundStyle(.white))
        let size = text.measure(in: caption.maximumSize)
        let label = CGRect(x: point.x - size.width / 2 - caption.padding.width, y: point.y + geometry.radius + caption.gap,
                           width: size.width + caption.padding.width * 2, height: size.height + caption.padding.height * 2)
        context.fill(Path(roundedRect: label, cornerRadius: label.height / 2), with: .color((caption.background ?? fill).opacity(caption.backgroundOpacity)))
        context.draw(text, at: CGPoint(x: label.midX, y: label.midY))
    }
}
