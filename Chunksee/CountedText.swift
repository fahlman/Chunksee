import Foundation

/// Counted labels and fractional units use native number formatting and grammatical agreement.
nonisolated enum CountedText {
    static func label(_ name: String, count: Int?, locale: Locale = .current) -> String {
        guard let count else { return name }
        return String(localized: "\(name) (\(count))", locale: locale)
    }

    static func hearts(_ count: Double, locale: Locale = .current) -> String {
        let format = format(locale)
        let shown = displayedCount(count, format: format)
        return String(AttributedString(localized: "^[\(shown, format: format) heart](inflect: true)", locale: locale).characters)
    }

    static func hearts(_ current: Double, of maximum: Double, locale: Locale = .current) -> String {
        let format = format(locale)
        let shown = displayedCount(maximum, format: format)
        // Only the maximum belongs to this noun phrase; 1 of 2 is plural, 0 of 1 is singular.
        return String(AttributedString(localized: "\(current, format: format) of ^[\(shown, format: format) heart](inflect: true)", locale: locale).characters)
    }

    static func blocks(_ count: Double, locale: Locale = .current) -> String {
        let format = format(locale)
        let shown = displayedCount(count, format: format)
        return String(AttributedString(localized: "^[\(shown, format: format) block](inflect: true)", locale: locale).characters)
    }

    private static func format(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...2)).locale(locale)
    }

    private static func displayedCount(_ count: Double, format: FloatingPointFormatStyle<Double>) -> Double {
        // Grammar must follow the displayed rounding (0.999 reads 1), not hidden saved digits.
        // Reuse the native format's parser rather than add a second precision/rounding policy.
        guard let value = try? format.parseStrategy.parse(count.formatted(format)), value.isFinite else { return count }
        return value
    }
}
