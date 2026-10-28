import Foundation

/// Presentation measured from the selected game's top-down model and texture pixels.
/// Unavailable art cannot prove that a saved block should disappear.
nonisolated enum MapBlockCoverage: Equatable, Sendable {
    case covers
    case partial(opacity: Double)
    case none
    case unavailable
}
