import Foundation
import QuartzCore

/// Common surface for a season engine so ScreenController can swap them.
protocol SeasonEngine: AnyObject {
    func stepIfNeeded(_ now: CFTimeInterval)
    func setDensity(_ d: SnowDensity)
    func clear()
    func setNeverDisappear(_ value: Bool)
}

extension SeasonEngine {
    func setNeverDisappear(_ value: Bool) {}
}

/// The weather currently running on the desktop. Only one can be active.
enum Season: Int, CaseIterable {
    case snow = 0
    case autumn = 1

    var label: String {
        switch self {
        case .snow: return "Snow"
        case .autumn: return "Autumn"
        }
    }

    var tagline: String {
        switch self {
        case .snow: return "A quiet dusting"
        case .autumn: return "Leaves in the wind"
        }
    }

    /// SF Symbol used in the menu bar and season buttons.
    var symbol: String {
        switch self {
        case .snow: return "snowflake"
        case .autumn: return "leaf.fill"
        }
    }

    var detail: String {
        switch self {
        case .snow: return "Snow settles on windows, the Dock, and your files."
        case .autumn: return "Leaves drift down, gather, and pile up."
        }
    }
}

extension SnowDensity {
    /// Number of individual leaf bodies for the autumn season.
    var leafCount: Int {
        switch self {
        case .light: return 220
        case .normal: return 420
        case .heavy: return 700
        case .shower: return 1400
        }
    }

    func subtitle(for season: Season) -> String {
        switch season {
        case .snow:
            switch self {
            case .light: return "A quiet dusting"
            case .normal: return "A steady fall"
            case .heavy: return "A proper blizzard"
            case .shower: return "A full snow shower"
            }
        case .autumn:
            switch self {
            case .light: return "A few leaves"
            case .normal: return "Steady drift"
            case .heavy: return "Leaf storm"
            case .shower: return "A full leaf shower"
            }
        }
    }
}
