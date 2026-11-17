import Foundation

public struct PomodoroConfig: Codable, Equatable, Sendable {
    public var focusMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    public var rounds: Int

    public init(focusMinutes: Int = 25, shortBreakMinutes: Int = 5, longBreakMinutes: Int = 15, rounds: Int = 4) {
        self.focusMinutes = focusMinutes; self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes; self.rounds = rounds
    }
}

public enum PomodoroPhase: String, Codable, Sendable {
    case idle, focus, shortBreak, longBreak, done

    public var isActive: Bool { self == .focus || self == .shortBreak || self == .longBreak }
    public var isBreak: Bool { self == .shortBreak || self == .longBreak }
}

public enum PomodoroEvent: Equatable, Sendable { case focusEnded, breakEnded, allDone }

/// Timer state machine. Deadline-based, so it stays correct across sleep and late ticks.
public struct PomodoroEngine: Equatable, Sendable {
    public var config: PomodoroConfig
    public private(set) var phase: PomodoroPhase = .idle
    /// 1-based focus round.
    public private(set) var round: Int = 1
    public private(set) var phaseEnd: Date?
    public private(set) var pausedRemaining: TimeInterval?

    public init(config: PomodoroConfig = PomodoroConfig()) { self.config = config }

    public var isPaused: Bool { pausedRemaining != nil }
    public var isRunning: Bool { phase.isActive && !isPaused }

    public func duration(of p: PomodoroPhase) -> TimeInterval {
        switch p {
        case .focus: return TimeInterval(max(1, config.focusMinutes) * 60)
        case .shortBreak: return TimeInterval(max(1, config.shortBreakMinutes) * 60)
        case .longBreak: return TimeInterval(max(1, config.longBreakMinutes) * 60)
        case .idle, .done: return 0
        }
    }

    public func remaining(now: Date) -> TimeInterval {
        if let p = pausedRemaining { return p }
        guard phase.isActive, let end = phaseEnd else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }

    /// How tall the campfire burns, 0…1. Burns down through focus, rekindles through a break.
    public func fireLevel(now: Date) -> Double {
        let total = duration(of: phase)
        guard total > 0 else { return 0 }
        let frac = min(1, max(0, remaining(now: now) / total))
        return phase == .focus ? frac : 1 - frac
    }

    public mutating func start(now: Date) {
        round = 1
        begin(.focus, now: now)
    }

    public mutating func pause(now: Date) {
        guard isRunning else { return }
        pausedRemaining = remaining(now: now)
        phaseEnd = nil
    }

    public mutating func resume(now: Date) {
        guard let p = pausedRemaining else { return }
        pausedRemaining = nil
        phaseEnd = now.addingTimeInterval(p)
    }

    public mutating func reset() {
        phase = .idle; round = 1; phaseEnd = nil; pausedRemaining = nil
    }

    /// Ends the current phase immediately.
    @discardableResult
    public mutating func skip(now: Date) -> PomodoroEvent? {
        guard phase.isActive else { return nil }
        pausedRemaining = nil
        return advance(now: now)
    }

    /// Call periodically; returns an event when a phase has run out.
    @discardableResult
    public mutating func tick(now: Date) -> PomodoroEvent? {
        guard isRunning, let end = phaseEnd, now >= end else { return nil }
        return advance(now: now)
    }

    private mutating func begin(_ p: PomodoroPhase, now: Date) {
        phase = p
        pausedRemaining = nil
        phaseEnd = now.addingTimeInterval(duration(of: p))
    }

    private mutating func advance(now: Date) -> PomodoroEvent {
        switch phase {
        case .focus:
            begin(round >= max(1, config.rounds) ? .longBreak : .shortBreak, now: now)
            return .focusEnded
        case .shortBreak:
            round += 1
            begin(.focus, now: now)
            return .breakEnded
        default:
            phase = .done; phaseEnd = nil; pausedRemaining = nil
            return .allDone
        }
    }
}
