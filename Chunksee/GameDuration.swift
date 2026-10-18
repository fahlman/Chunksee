import Foundation

/// Saved elapsed time at 20 game ticks per second, separate from the world's day-cycle clock.
nonisolated enum GameDuration {
    static func fromTicks(_ ticks: Int, roundingUp: Bool = false) -> Duration {
        // Effects round partial seconds up; elapsed time counts completed seconds. Divide
        // first so rounding a long saved duration cannot overflow an intermediate sum.
        let seconds = ticks / 20 + (roundingUp && ticks % 20 != 0 ? 1 : 0)
        return .seconds(seconds)
    }

    static func units(_ duration: Duration, locale: Locale = .current) -> String {
        duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }

    static func elapsed(_ ticks: Int, locale: Locale = .current) -> String? {
        guard ticks >= 0 else { return nil }
        return units(fromTicks(ticks), locale: locale)
    }
}
