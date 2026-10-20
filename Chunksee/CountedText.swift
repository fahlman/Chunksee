import Foundation

/// Fractional units share native precision and grammar, including SwiftUI's environment locale.
nonisolated struct CountedText: FormatStyle, Sendable {
    private enum Phrase: Codable, Hashable, Sendable {
        case hearts
        case heartsOf(Double)
        case hunger
        case blocks
    }

    private var phrase: Phrase
    private var locale = Locale.autoupdatingCurrent

    static var hearts: Self { Self(phrase: .hearts) }
    static func hearts(of maximum: Double) -> Self { Self(phrase: .heartsOf(maximum)) }
    static var hunger: Self { Self(phrase: .hunger) }
    static var blocks: Self { Self(phrase: .blocks) }

    func locale(_ locale: Locale) -> Self {
        var copy = self
        copy.locale = locale
        return copy
    }

    func format(_ value: Double) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2)).locale(locale)
        switch phrase {
        case .hearts:
            let shown = Self.displayedCount(value, format: number)
            return String(AttributedString(localized: "^[\(shown, format: number) heart](inflect: true)", locale: locale).characters)
        case .heartsOf(let maximum):
            let shown = Self.displayedCount(maximum, format: number)
            // Only the maximum belongs to this noun phrase; 1 of 2 is plural, 0 of 1 is singular.
            return String(AttributedString(localized: "\(value, format: number) of ^[\(shown, format: number) heart](inflect: true)", locale: locale).characters)
        case .hunger:
            return String(localized: "\(value, format: number) of \(10.0, format: number) drumsticks", locale: locale)
        case .blocks:
            let shown = Self.displayedCount(value, format: number)
            return String(AttributedString(localized: "^[\(shown, format: number) block](inflect: true)", locale: locale).characters)
        }
    }

    static func label(_ name: String, count: Int?, locale: Locale = .current) -> String {
        guard let count else { return name }
        return String(localized: "\(name) (\(count))", locale: locale)
    }

    private static func displayedCount(_ count: Double, format: FloatingPointFormatStyle<Double>) -> Double {
        // Grammar must follow the displayed rounding (0.999 reads 1), not hidden saved digits.
        // Reuse the native format's parser rather than add a second precision/rounding policy.
        guard let value = try? format.parseStrategy.parse(count.formatted(format)), value.isFinite else { return count }
        return value
    }
}
