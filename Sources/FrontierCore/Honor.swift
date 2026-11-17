import Foundation

/// Rank readout for the honor scale. Honor is never shown as a number.
public enum HonorRank: String, CaseIterable, Sendable {
    case trueToTheirWord = "TRUE TO THEIR WORD"
    case dependable = "DEPENDABLE"
    case fair = "FAIR"
    case undecided = "UNDECIDED"
    case unreliable = "UNRELIABLE"
    case givenToDrift = "GIVEN TO DRIFT"
    case lostToIt = "LOST TO IT"
}

/// Which vision the desktop shows.
public enum HonorMood: String, Sendable { case stag, wolf, neutral }

public enum Honor {
    public static let dailyDecay = 0.95

    /// Half-open ranges with an inclusive lower bound, evaluated top-down.
    public static func rank(_ h: Double) -> HonorRank {
        if h >= 0.75 { return .trueToTheirWord }
        if h >= 0.40 { return .dependable }
        if h >= 0.10 { return .fair }
        if h >= -0.10 { return .undecided }
        if h >= -0.40 { return .unreliable }
        if h >= -0.75 { return .givenToDrift }
        return .lostToIt
    }

    /// The desktop follows the rank the user can read: any rank on the good side of UNDECIDED shows
    /// the stag, any rank on the bad side shows the wolf. (They used to have their own, stricter
    /// cut-offs, which left the meter saying UNRELIABLE over an unchanged wallpaper.)
    public static func mood(_ h: Double) -> HonorMood {
        switch rank(h) {
        case .trueToTheirWord, .dependable, .fair: return .stag
        case .undecided: return .neutral
        case .unreliable, .givenToDrift, .lostToIt: return .wolf
        }
    }

    /// Applies a change with diminishing returns when moving away from zero.
    /// Moves toward zero always land at full strength.
    public static func apply(_ h: Double, delta: Double) -> Double {
        var d = delta
        if h != 0, (d > 0) == (h > 0) { d *= (1 - abs(h)) }
        return min(1, max(-1, h + d))
    }

    /// Continuous loss of `amount` honor. Unlike `apply`, the result depends only on the
    /// total drained, not on how it was sliced into ticks — so a long sleep costs exactly
    /// what the same hours awake would have.
    public static func drain(_ h: Double, amount: Double) -> Double {
        guard amount > 0 else { return h }
        var h = h, x = amount
        if h > 0 {                       // toward zero: full strength
            let step = min(h, x)
            h -= step; x -= step
        }
        if x > 0 { h = -1 + (1 + h) * exp(-x) }   // away from zero: dh/dx = -(1 - |h|)
        return max(-1, h)
    }

    /// Character fades toward neutral without upkeep.
    public static func decayed(_ h: Double, days: Int) -> Double {
        guard days > 0 else { return h }
        return h * pow(dailyDecay, Double(days))
    }
}
