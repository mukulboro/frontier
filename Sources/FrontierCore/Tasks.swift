import Foundation

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var tags: [String]
    public var createdAt: Date
    public var dueAt: Date?
    public var completedAt: Date?
    /// Honor already drained by this task's deadline pressure.
    public var drained: Double
    /// Honor granted when it was completed (so un-completing can take it back).
    public var awarded: Double

    public init(id: UUID = UUID(), title: String, tags: [String] = [], createdAt: Date,
                dueAt: Date? = nil, completedAt: Date? = nil, drained: Double = 0, awarded: Double = 0) {
        self.id = id; self.title = title; self.tags = tags; self.createdAt = createdAt
        self.dueAt = dueAt; self.completedAt = completedAt; self.drained = drained; self.awarded = awarded
    }

    public var isDone: Bool { completedAt != nil }
}

public enum TaskUrgency: Sendable { case none, calm, near, overdue }

public enum TaskRules {
    /// The final stretch of a task's window, where honor starts to slip.
    public static let nearFraction = 0.25
    /// Honor lost across the final stretch, reached exactly at the deadline.
    public static let nearDrain = 0.05
    public static let overdueRatePerHour = 0.12
    /// A single task can never cost more than this.
    public static let drainCap = 0.30
    public static let onTimeGain = 0.10
    public static let lateGain = 0.04
    public static let deletePenalty = 0.05

    /// Total honor this task should have drained by `now`. Pure function of time,
    /// so sleep, restarts and irregular ticks can't double-charge.
    public static func expectedDrain(_ t: TaskItem, now: Date) -> Double {
        guard let due = t.dueAt else { return 0 }
        let window = max(60, due.timeIntervalSince(t.createdAt))
        let nearStart = due.addingTimeInterval(-window * nearFraction)
        if now <= nearStart { return 0 }
        if now <= due {
            let p = now.timeIntervalSince(nearStart) / (window * nearFraction)
            return nearDrain * p
        }
        let hoursLate = now.timeIntervalSince(due) / 3600
        return min(drainCap, nearDrain + overdueRatePerHour * hoursLate)
    }

    public static func urgency(_ t: TaskItem, now: Date) -> TaskUrgency {
        guard !t.isDone, let due = t.dueAt else { return .none }
        if now > due { return .overdue }
        let window = max(60, due.timeIntervalSince(t.createdAt))
        return now > due.addingTimeInterval(-window * nearFraction) ? .near : .calm
    }

    /// "Mend the fence #ranch #chores" -> ("Mend the fence", ["ranch", "chores"])
    public static func parse(_ input: String) -> (title: String, tags: [String]) {
        var words: [String] = []
        var tags: [String] = []
        for w in input.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if w.hasPrefix("#"), w.count > 1 {
                let tag = w.dropFirst().lowercased()
                if !tags.contains(tag) { tags.append(tag) }
            } else {
                words.append(String(w))
            }
        }
        return (words.joined(separator: " "), tags)
    }
}

/// The day's tasks plus the honor they've earned or cost.
public struct Ledger: Codable, Equatable, Sendable {
    public var tasks: [TaskItem]
    public var honor: Double
    /// yyyy-MM-dd of the last day this ledger was touched.
    public var lastDay: String

    public init(tasks: [TaskItem] = [], honor: Double = 0, lastDay: String = "") {
        self.tasks = tasks; self.honor = honor; self.lastDay = lastDay
    }

    public var hasTimedOpenTasks: Bool { tasks.contains { !$0.isDone && $0.dueAt != nil } }

    @discardableResult
    public mutating func add(_ input: String, limit: TimeInterval?, now: Date) -> TaskItem? {
        let parsed = TaskRules.parse(input)
        guard !parsed.title.isEmpty else { return nil }
        let item = TaskItem(title: parsed.title, tags: parsed.tags, createdAt: now,
                            dueAt: limit.map { now.addingTimeInterval($0) })
        tasks.append(item)
        return item
    }

    /// Settles deadline pressure. Returns the honor change (≤ 0).
    @discardableResult
    public mutating func tick(now: Date) -> Double {
        let before = honor
        for i in tasks.indices where !tasks[i].isDone {
            let expected = TaskRules.expectedDrain(tasks[i], now: now)
            let d = expected - tasks[i].drained
            if d > 0 {
                honor = Honor.drain(honor, amount: d)
                tasks[i].drained = expected
            }
        }
        return honor - before
    }

    /// Returns the honor gained.
    @discardableResult
    public mutating func complete(_ id: UUID, now: Date) -> Double {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isDone else { return 0 }
        tick(now: now)
        let onTime = tasks[i].dueAt.map { now <= $0 } ?? true
        let before = honor
        honor = Honor.apply(honor, delta: onTime ? TaskRules.onTimeGain : TaskRules.lateGain)
        tasks[i].awarded = honor - before
        tasks[i].completedAt = now
        return honor - before
    }

    public mutating func uncomplete(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].isDone else { return }
        honor = min(1, max(-1, honor - tasks[i].awarded))
        tasks[i].awarded = 0
        tasks[i].completedAt = nil
    }

    /// Quietly dropping an open commitment costs honor. Returns the change.
    @discardableResult
    public mutating func delete(_ id: UUID, now: Date) -> Double {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return 0 }
        let before = honor
        if !tasks[i].isDone {
            tick(now: now)
            honor = Honor.apply(honor, delta: -TaskRules.deletePenalty)
        }
        tasks.remove(at: i)
        return honor - before
    }

    /// New day: honor fades toward neutral and yesterday's finished work is cleared.
    /// Unfinished tasks stay on the books.
    public mutating func rollover(now: Date, calendar: Calendar = .current) {
        let today = Ledger.dayKey(now, calendar: calendar)
        guard today != lastDay else { return }
        if !lastDay.isEmpty {
            tick(now: now)
            let days = Ledger.daysBetween(lastDay, today, calendar: calendar)
            honor = Honor.decayed(honor, days: max(1, days))
            let startOfToday = calendar.startOfDay(for: now)
            tasks.removeAll { ($0.completedAt ?? now) < startOfToday }
        }
        lastDay = today
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func daysBetween(_ a: String, _ b: String, calendar: Calendar) -> Int {
        func parse(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        guard let da = parse(a), let db = parse(b) else { return 1 }
        return calendar.dateComponents([.day], from: da, to: db).day ?? 1
    }
}
