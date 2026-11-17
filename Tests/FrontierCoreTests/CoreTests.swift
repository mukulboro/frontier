import Foundation
import Testing
@testable import FrontierCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

@Suite struct HonorTests {
    @Test func rankBoundariesResolveUpward() {
        #expect(Honor.rank(0.75) == .trueToTheirWord)
        #expect(Honor.rank(0.40) == .dependable)
        #expect(Honor.rank(0.10) == .fair)
        #expect(Honor.rank(0) == .undecided)
        #expect(Honor.rank(-0.10) == .undecided)
        #expect(Honor.rank(-0.11) == .unreliable)
        #expect(Honor.rank(-0.40) == .unreliable)
        #expect(Honor.rank(-0.75) == .givenToDrift)
        #expect(Honor.rank(-0.76) == .lostToIt)
    }

    @Test func diminishingReturnsOnlyAwayFromZero() {
        #expect(approx(Honor.apply(0, delta: 0.1), 0.1))
        #expect(approx(Honor.apply(0.5, delta: 0.1), 0.55))     // away: halved
        #expect(approx(Honor.apply(0.5, delta: -0.1), 0.4))     // toward: full
        #expect(approx(Honor.apply(-0.5, delta: -0.1), -0.55))
        #expect(approx(Honor.apply(-0.5, delta: 0.1), -0.4))
    }

    @Test func neverSaturatesOrEscapesBounds() {
        var h = 0.0
        for _ in 0..<500 { h = Honor.apply(h, delta: 0.1) }
        #expect(h < 1.0 && h > 0.99)
        #expect(Honor.apply(0.2, delta: -5) == -1)
    }

    @Test func drainIsPathIndependent() {
        var sliced = 0.3
        for _ in 0..<1000 { sliced = Honor.drain(sliced, amount: 0.001) }
        #expect(approx(Honor.drain(0.3, amount: 1.0), sliced))
        #expect(approx(Honor.drain(0.3, amount: 0.2), 0.1))     // toward zero is linear
        #expect(Honor.drain(-0.5, amount: 50) >= -1)
        #expect(Honor.drain(0.2, amount: 0) == 0.2)
    }

    @Test func moodThresholds() {
        #expect(Honor.mood(0.40) == .stag)
        #expect(Honor.mood(0.39) == .neutral)
        #expect(Honor.mood(-0.40) == .wolf)
        #expect(approx(Honor.decayed(0.8, days: 2), 0.8 * 0.95 * 0.95))
    }

    @Test func fiveOnTimeTasksSummonTheStag() {
        var l = Ledger()
        for i in 0..<5 {
            let t = l.add("task \(i)", limit: 3600, now: t0)!
            l.complete(t.id, now: t0.addingTimeInterval(60))
        }
        #expect(Honor.mood(l.honor) == .stag)
    }
}

@Suite struct TaskTests {
    @Test func parsesTags() {
        let p = TaskRules.parse("Mend the  fence #Ranch #chores #ranch")
        #expect(p.title == "Mend the fence")
        #expect(p.tags == ["ranch", "chores"])
        #expect(TaskRules.parse("  #only ").title.isEmpty)
    }

    @Test func drainIsZeroUntilFinalQuarter() {
        let t = TaskItem(title: "x", createdAt: t0, dueAt: t0.addingTimeInterval(4000))
        #expect(TaskRules.expectedDrain(t, now: t0.addingTimeInterval(2999)) == 0)
        #expect(approx(TaskRules.expectedDrain(t, now: t0.addingTimeInterval(3500)), 0.025))
        #expect(approx(TaskRules.expectedDrain(t, now: t0.addingTimeInterval(4000)), 0.05))
        #expect(approx(TaskRules.expectedDrain(t, now: t0.addingTimeInterval(4000 + 3600)), 0.17))
        #expect(TaskRules.expectedDrain(t, now: t0.addingTimeInterval(86400 * 3)) == TaskRules.drainCap)
        #expect(TaskRules.expectedDrain(TaskItem(title: "free", createdAt: t0), now: t0.addingTimeInterval(1e7)) == 0)
    }

    @Test func tickIsIdempotentAndTimeDriven() {
        var l = Ledger()
        l.add("a", limit: 4000, now: t0)
        #expect(l.tick(now: t0.addingTimeInterval(3500)) < 0)
        let h = l.honor
        #expect(l.tick(now: t0.addingTimeInterval(3500)) == 0)   // no double-charge
        #expect(l.honor == h)
        // One big jump (sleep) equals many small ticks.
        var a = Ledger(), b = Ledger()
        a.add("a", limit: 4000, now: t0); b.add("a", limit: 4000, now: t0)
        a.tick(now: t0.addingTimeInterval(9000))
        for s in stride(from: 0.0, through: 9000, by: 30) { b.tick(now: t0.addingTimeInterval(s)) }
        #expect(approx(a.honor, b.honor, 1e-9))
        #expect(a.honor < 0)
    }

    @Test func urgencyStates() {
        var t = TaskItem(title: "x", createdAt: t0, dueAt: t0.addingTimeInterval(4000))
        #expect(TaskRules.urgency(t, now: t0) == .calm)
        #expect(TaskRules.urgency(t, now: t0.addingTimeInterval(3500)) == .near)
        #expect(TaskRules.urgency(t, now: t0.addingTimeInterval(4001)) == .overdue)
        t.completedAt = t0
        #expect(TaskRules.urgency(t, now: t0.addingTimeInterval(4001)) == .none)
    }

    @Test func completeOnTimeBeatsLate() {
        var a = Ledger(), b = Ledger()
        let ta = a.add("a", limit: 3600, now: t0)!, tb = b.add("a", limit: 3600, now: t0)!
        let ga = a.complete(ta.id, now: t0.addingTimeInterval(100))
        let gb = b.complete(tb.id, now: t0.addingTimeInterval(4000))
        #expect(approx(ga, 0.10))
        #expect(gb > 0 && gb < ga)
        #expect(a.honor > b.honor)
        #expect(a.complete(ta.id, now: t0) == 0)   // completing twice does nothing
    }

    @Test func uncompleteTakesTheHonorBack() {
        var l = Ledger()
        let t = l.add("a", limit: nil, now: t0)!
        l.complete(t.id, now: t0)
        l.uncomplete(t.id)
        #expect(approx(l.honor, 0))
        #expect(!l.tasks[0].isDone)
    }

    @Test func deletingOpenTaskCostsHonorButDoneTaskIsFree() {
        var l = Ledger()
        let open = l.add("a", limit: nil, now: t0)!
        #expect(approx(l.delete(open.id, now: t0), -0.05))
        let done = l.add("b", limit: nil, now: t0)!
        l.complete(done.id, now: t0)
        let h = l.honor
        #expect(l.delete(done.id, now: t0) == 0)
        #expect(l.honor == h && l.tasks.isEmpty)
    }

    @Test func twoNeglectedTasksBringTheWolf() {
        var l = Ledger()
        l.add("a", limit: 1800, now: t0); l.add("b", limit: 1800, now: t0); l.add("c", limit: 1800, now: t0)
        l.tick(now: t0.addingTimeInterval(86400 / 2))
        #expect(Honor.mood(l.honor) == .wolf)
    }

    @Test func rolloverDecaysAndClearsFinishedWork() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var l = Ledger()
        l.rollover(now: t0, calendar: cal)
        let a = l.add("done", limit: nil, now: t0)!
        l.add("open", limit: nil, now: t0)
        l.complete(a.id, now: t0)
        let h = l.honor
        l.rollover(now: t0, calendar: cal)
        #expect(l.tasks.count == 2 && l.honor == h)            // same day: nothing happens
        l.rollover(now: t0.addingTimeInterval(86400 * 2), calendar: cal)
        #expect(l.tasks.map(\.title) == ["open"])
        #expect(approx(l.honor, h * 0.95 * 0.95))
    }

    @Test func ledgerRoundTripsThroughJSON() throws {
        var l = Ledger()
        l.add("a #x", limit: 600, now: t0)
        let back = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(l))
        #expect(back == l)
    }
}

@Suite struct PomodoroTests {
    func engine() -> PomodoroEngine {
        PomodoroEngine(config: PomodoroConfig(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, rounds: 2))
    }

    @Test func fullCycle() {
        var e = engine()
        #expect(e.phase == .idle && !e.isRunning)
        e.start(now: t0)
        #expect(e.phase == .focus && e.remaining(now: t0) == 1500)
        #expect(e.tick(now: t0.addingTimeInterval(1499)) == nil)
        var now = t0.addingTimeInterval(1500)
        #expect(e.tick(now: now) == .focusEnded)
        #expect(e.phase == .shortBreak && e.remaining(now: now) == 300)
        now += 300
        #expect(e.tick(now: now) == .breakEnded)
        #expect(e.phase == .focus && e.round == 2)
        now += 1500
        #expect(e.tick(now: now) == .focusEnded)
        #expect(e.phase == .longBreak)                 // last round earns the long break
        now += 900
        #expect(e.tick(now: now) == .allDone)
        #expect(e.phase == .done && !e.isRunning && e.remaining(now: now) == 0)
    }

    @Test func pauseFreezesTime() {
        var e = engine()
        e.start(now: t0)
        e.pause(now: t0.addingTimeInterval(100))
        #expect(e.isPaused && !e.isRunning)
        #expect(e.remaining(now: t0.addingTimeInterval(5000)) == 1400)
        #expect(e.tick(now: t0.addingTimeInterval(5000)) == nil)
        e.resume(now: t0.addingTimeInterval(5000))
        #expect(e.remaining(now: t0.addingTimeInterval(5100)) == 1300)
    }

    @Test func fireBurnsDownInFocusAndRekindlesOnBreak() {
        var e = engine()
        #expect(e.fireLevel(now: t0) == 0)
        e.start(now: t0)
        #expect(e.fireLevel(now: t0) == 1)
        #expect(approx(e.fireLevel(now: t0.addingTimeInterval(750)), 0.5))
        #expect(e.skip(now: t0.addingTimeInterval(750)) == .focusEnded)
        let b = t0.addingTimeInterval(750)
        #expect(e.fireLevel(now: b) == 0)
        #expect(approx(e.fireLevel(now: b.addingTimeInterval(150)), 0.5))
    }

    @Test func resetAndSkipWhenIdle() {
        var e = engine()
        #expect(e.skip(now: t0) == nil)
        e.start(now: t0); e.reset()
        #expect(e.phase == .idle && e.round == 1)
    }
}

@Suite struct WheelTests {
    @Test func segmentsRunClockwiseFromTwelve() {
        #expect(WheelMath.segment(dx: 0, dy: 100, deadZone: 50) == 0)     // up
        #expect(WheelMath.segment(dx: 100, dy: 100, deadZone: 50) == 1)
        #expect(WheelMath.segment(dx: 100, dy: 0, deadZone: 50) == 2)     // right
        #expect(WheelMath.segment(dx: 0, dy: -100, deadZone: 50) == 4)    // down
        #expect(WheelMath.segment(dx: -100, dy: 0, deadZone: 50) == 6)    // left
        #expect(WheelMath.segment(dx: -100, dy: 100, deadZone: 50) == 7)
    }

    @Test func deadZoneAndBoundaries() {
        #expect(WheelMath.segment(dx: 10, dy: 10, deadZone: 50) == nil)
        // 22.5° is the seam between segment 0 and 1.
        let r = 100.0
        func at(_ deg: Double) -> Int? {
            WheelMath.segment(dx: r * sin(deg * .pi / 180), dy: r * cos(deg * .pi / 180), deadZone: 50)
        }
        #expect(at(22.4) == 0 && at(22.6) == 1)
        #expect(at(-22.4) == 0 && at(-22.6) == 7)
        #expect(at(359.9) == 0)
        for i in 0..<8 { #expect(at(WheelMath.centerAngle(of: i)) == i) }
    }
}

@Suite struct VitalsTests {
    @Test func wifiQualityMapping() {
        #expect(VitalsMath.wifiQuality(rssi: -90) == 0)
        #expect(VitalsMath.wifiQuality(rssi: -40) == 1)
        #expect(approx(VitalsMath.wifiQuality(rssi: -65), 0.5))
        #expect(VitalsMath.wifiQuality(rssi: 0) == 0)     // not associated
    }

    @Test func cpuFreeFromTickDeltas() {
        #expect(approx(VitalsMath.cpuFree(prev: (100, 1000), cur: (150, 1200)), 0.75))
        #expect(VitalsMath.cpuFree(prev: (100, 1000), cur: (100, 1000)) == 1)
    }

    @Test func slowCoreLagsBehind() {
        var c = SlowCore()
        c.update(1.0)
        #expect(c.value == 1.0)
        c.update(0.0)
        #expect(c.value! > 0.9)
    }

    @Test func hoverReadouts() {
        let v = VitalSample(cpuFree: 0.93, ramFree: 0.45, battery: 0.824, charging: true, wifi: 0.7,
                            wifiRSSI: -55, ramTotalGB: 24)
        #expect(v.batteryText == "82%")
        #expect(v.wifiText == "-55 dBm")
        #expect(v.ramText == "13.2 / 24 GB")
        #expect(v.cpuText == "7% load")
        let off = VitalSample(cpuFree: 1, ramFree: 1, battery: nil, charging: false, wifi: 0)
        #expect(off.batteryText == nil && off.wifiText == "Off")
    }

    @Test func liveSampleIsSane() {
        let m = VitalsMonitor()
        _ = m.sample()
        let s = m.sample()
        #expect((0...1).contains(s.cpuFree) && (0...1).contains(s.ramFree))
        #expect(s.ramFree > 0 && s.ramFree < 1)
        if let b = s.battery { #expect((0...1).contains(b)) }
        if let w = s.wifi { #expect((0...1).contains(w)) }
    }
}

@Suite struct CampTests {
    @Test func skyFollowsTheClock() {
        #expect(SkyPhase.at(hour: 0) == .night)
        #expect(SkyPhase.at(hour: 4.99) == .night)
        #expect(SkyPhase.at(hour: 5) == .dawn)
        #expect(SkyPhase.at(hour: 7.5) == .day)
        #expect(SkyPhase.at(hour: 12) == .day)
        #expect(SkyPhase.at(hour: 17) == .dusk)
        #expect(SkyPhase.at(hour: 19.5) == .night)
        #expect(SkyPhase.at(hour: 23.99) == .night)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let six = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 6, minute: 10))!
        #expect(SkyPhase.at(six, calendar: cal) == .dawn)
    }

    @Test func upgradesUnlockInOrder() {
        #expect(CampUpgrade.unlocked(renown: 0).isEmpty)
        #expect(CampUpgrade.unlocked(renown: 0.99).isEmpty)
        #expect(CampUpgrade.unlocked(renown: 1) == [.choppingBlock])
        #expect(CampUpgrade.unlocked(renown: 6.5) == [.choppingBlock, .lantern, .tent])
        #expect(CampUpgrade.unlocked(renown: 99) == CampUpgrade.allCases)
        let t = CampUpgrade.allCases.map(\.threshold)
        #expect(t == t.sorted() && Set(t).count == t.count)
    }

    @Test func progressTowardTheNextUpgrade() {
        let a = CampUpgrade.next(renown: 0.5)!
        #expect(a.upgrade == .choppingBlock && approx(a.progress, 0.5))
        let b = CampUpgrade.next(renown: 4)!           // between lantern (3) and tent (6)
        #expect(b.upgrade == .tent && approx(b.progress, 1.0 / 3.0))
        #expect(CampUpgrade.next(renown: 15) == nil)
    }

    @Test func renownAccumulatesAndNeverFades() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var l = Ledger()
        l.rollover(now: t0, calendar: cal)
        let a = l.add("a", limit: nil, now: t0)!
        let gained = l.complete(a.id, now: t0)
        #expect(approx(l.renown, gained))
        l.rollover(now: t0.addingTimeInterval(86400 * 30), calendar: cal)
        #expect(l.honor < gained)                       // honor faded over the month…
        #expect(approx(l.renown, gained))               // …renown did not
        let b = l.add("b", limit: 60, now: t0)!
        l.tick(now: t0.addingTimeInterval(86400))       // losing honor doesn't cost renown either
        #expect(approx(l.renown, gained))
        l.complete(b.id, now: t0.addingTimeInterval(86400))
        let both = l.renown
        l.uncomplete(b.id)                              // but un-completing hands it back
        #expect(l.renown < both && l.renown >= 0)
    }

    @Test func oldStateWithoutRenownStillLoads() throws {
        let json = #"{"tasks":[],"honor":0.25,"lastDay":"2026-11-17"}"#
        let l = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
        #expect(l.honor == 0.25 && l.renown == 0)
    }

    @Test func watchHandSweepsThePhase() {
        var e = PomodoroEngine(config: PomodoroConfig(focusMinutes: 20, shortBreakMinutes: 5, longBreakMinutes: 10, rounds: 2))
        #expect(e.progress(now: t0) == 0)
        e.start(now: t0)
        #expect(e.progress(now: t0) == 0)
        #expect(approx(e.progress(now: t0.addingTimeInterval(300)), 0.25))
        #expect(e.progress(now: t0.addingTimeInterval(5000)) == 1)
        e.pause(now: t0.addingTimeInterval(600))
        #expect(approx(e.progress(now: t0.addingTimeInterval(9999)), 0.5))     // frozen while paused
    }
}
