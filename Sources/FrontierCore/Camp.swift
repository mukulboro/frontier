import Foundation

/// The sky over the camp, following the real clock.
public enum SkyPhase: String, CaseIterable, Sendable {
    case night, dawn, day, dusk

    /// `hour` is the local time of day as a fraction, e.g. 17.5 for half past five.
    public static func at(hour: Double) -> SkyPhase {
        switch hour {
        case 5.0..<7.5: return .dawn
        case 7.5..<17.0: return .day
        case 17.0..<19.5: return .dusk
        default: return .night
        }
    }

    public static func at(_ date: Date, calendar: Calendar = .current) -> SkyPhase {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return at(hour: Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60)
    }
}

/// Things the camp gains as renown builds up. Ordered from first to last earned.
public enum CampUpgrade: String, CaseIterable, Sendable {
    case choppingBlock, lantern, tent, provisions, wagon

    public var title: String {
        switch self {
        case .choppingBlock: return "Chopping block"
        case .lantern: return "Lantern"
        case .tent: return "Tent"
        case .provisions: return "Provisions"
        case .wagon: return "Wagon"
        }
    }

    /// Renown needed. A solid day earns roughly 0.3–0.45, so the wagon is six or seven weeks of work.
    public var threshold: Double {
        switch self {
        case .choppingBlock: return 1
        case .lantern: return 3
        case .tent: return 6
        case .provisions: return 10
        case .wagon: return 15
        }
    }

    public static func unlocked(renown: Double) -> [CampUpgrade] {
        allCases.filter { renown >= $0.threshold }
    }

    /// The next thing to earn and how far along it is (0…1), or nil once the camp is complete.
    public static func next(renown: Double) -> (upgrade: CampUpgrade, progress: Double)? {
        guard let up = allCases.first(where: { renown < $0.threshold }) else { return nil }
        let floor = allCases.last(where: { renown >= $0.threshold })?.threshold ?? 0
        return (up, min(1, max(0, (renown - floor) / (up.threshold - floor))))
    }
}
