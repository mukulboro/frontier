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
        // The wallpaper changes exactly when the rank leaves UNDECIDED, in either direction.
        #expect(Honor.mood(0) == .neutral)
        #expect(Honor.mood(0.09) == .neutral && Honor.mood(-0.10) == .neutral)
        #expect(Honor.mood(0.10) == .stag && Honor.mood(0.9) == .stag)
        #expect(Honor.mood(-0.11) == .wolf && Honor.mood(-0.9) == .wolf)
        #expect(Honor.mood(-0.37) == .wolf)                     // UNRELIABLE must show the wolf
        for h in stride(from: -1.0, through: 1.0, by: 0.01) {
            #expect((Honor.mood(h) == .neutral) == (Honor.rank(h) == .undecided))
        }
        #expect(approx(Honor.decayed(0.8, days: 2), 0.8 * 0.95 * 0.95))
    }

    @Test func oneFinishedTaskSummonsTheStag() {
        var l = Ledger()
        for i in 0..<1 {
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

// MARK: Usage
//
// Every fixture here is invented. The tests never read the real ~/.claude, so no transcript content
// is ever touched by the suite.

private func fixtureRoot() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("frontier-usage-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
    return dir
}

/// One assistant row. `blocks` repeats it the way Claude Code does, once per content block.
private func row(id: String, request: String = "req", model: String = "claude-sonnet-5",
                 ts: String = "2026-11-17T09:00:00.000Z", cwd: String = "/Users/x/alpha",
                 out: Int = 100, input: Int = 2, write: Int = 50, read: Int = 900, blocks: Int = 1) -> String {
    (0..<blocks).map { i in
        """
        {"type":"assistant","timestamp":"\(ts)","cwd":"\(cwd)","requestId":"\(request)","apiBlockIndex":\(i),\
        "message":{"id":"\(id)","model":"\(model)","role":"assistant","content":[],"usage":{"input_tokens":\(input),\
        "output_tokens":\(out),"cache_creation_input_tokens":\(write),"cache_read_input_tokens":\(read)}}}
        """.replacingOccurrences(of: "\n", with: "")
    }.joined(separator: "\n")
}

@Suite struct UsageTests {
    @Test func countsEachMessageOnceDespiteRepeatedBlocks() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [row(id: "m1", blocks: 4), row(id: "m2", request: "r2", out: 20, blocks: 3)]
        try lines.joined(separator: "\n").appending("\n").write(to: root.appendingPathComponent("a/s.jsonl"), atomically: true, encoding: .utf8)
        let r = UsageScanner(root: root).scan()
        #expect(r.all.messages == 2)                 // not 7
        #expect(r.all.output == 120)
        #expect(r.all.cacheRead == 1800)
    }

    @Test func dedupesRepeatsThatAreNotAdjacentOrEvenInTheSameFile() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Interleaved repeats in one file...
        let interleaved = [row(id: "a", out: 10), row(id: "b", request: "r2", out: 20),
                           row(id: "a", out: 10), row(id: "b", request: "r2", out: 20)]
        try (interleaved.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("a/main.jsonl"), atomically: true, encoding: .utf8)
        // ...and the same call restated in a subagent transcript, as Claude Code really does.
        try (row(id: "a", out: 10) + "\n").write(to: root.appendingPathComponent("a/b/c/subagent.jsonl"), atomically: true, encoding: .utf8)
        let r = UsageScanner(root: root).scan()
        #expect(r.all.messages == 2)
        #expect(r.all.output == 30)
    }

    @Test func fingerprintIsStableAcrossRuns() {
        // Persisted between launches, so it must not depend on Swift's per-process hash seed.
        #expect(UsageScanner.fingerprint("msg_abc|req_def") == 0xe2d0_7211_956c_9735)
        #expect(UsageScanner.fingerprint("") == 0xcbf2_9ce4_8422_2325)
        #expect(UsageScanner.fingerprint("a") != UsageScanner.fingerprint("b"))
    }

    @Test func findsDeeplyNestedTranscripts() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try (row(id: "top") + "\n").write(to: root.appendingPathComponent("a/top.jsonl"), atomically: true, encoding: .utf8)
        try (row(id: "deep", out: 7) + "\n").write(to: root.appendingPathComponent("a/b/c/deep.jsonl"), atomically: true, encoding: .utf8)
        let r = UsageScanner(root: root).scan()
        #expect(r.all.messages == 2 && r.all.output == 107)
    }

    @Test func ignoresNonAssistantAndSyntheticRows() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let junk = """
        {"type":"user","message":{"role":"user","content":"secret"}}
        {"type":"api-request","requestId":"x"}
        {"type":"assistant","message":{"id":"s","model":"<synthetic>","usage":{"output_tokens":9999}}}
        not json at all
        """
        try (junk + "\n" + row(id: "real") + "\n").write(to: root.appendingPathComponent("a/s.jsonl"), atomically: true, encoding: .utf8)
        let r = UsageScanner(root: root).scan()
        #expect(r.all.messages == 1 && r.all.output == 100)
        #expect(r.models.keys.sorted() == ["claude-sonnet-5"])
    }

    @Test func incrementalScanAddsOnlyNewRowsAndNeverSplitsAMessage() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let file = root.appendingPathComponent("a/s.jsonl")
        let scanner = UsageScanner(root: root, cacheURL: cache)
        try (row(id: "m1", blocks: 3) + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(scanner.scan().all.messages == 1)
        // Append a half-written line: it must not be counted until its newline arrives.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let partial = row(id: "m2", request: "r2", out: 42)
        try handle.write(contentsOf: Data(partial.dropLast(20).utf8))
        try handle.close()
        var r = scanner.scan()
        #expect(r.all.messages == 1 && r.all.output == 100)
        // Completing the line counts it exactly once.
        let h2 = try FileHandle(forWritingTo: file)
        try h2.seekToEnd()
        try h2.write(contentsOf: Data((String(partial.suffix(20)) + "\n").utf8))
        try h2.close()
        r = scanner.scan()
        #expect(r.all.messages == 2 && r.all.output == 142)
        #expect(scanner.scan().all.messages == 2)      // rescanning changes nothing
    }

    @Test func rewrittenFileIsCountedFromScratch() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let file = root.appendingPathComponent("a/s.jsonl")
        let scanner = UsageScanner(root: root, cacheURL: cache)
        try (row(id: "m1") + "\n" + row(id: "m2", request: "r2") + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(scanner.scan().all.messages == 2)
        try (row(id: "only", out: 5) + "\n").write(to: file, atomically: true, encoding: .utf8)   // shrank
        #expect(scanner.scan().all.output == 5)
    }

    @Test func bucketsByDayProjectAndModel() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            row(id: "a", ts: "2026-11-17T09:00:00.000Z", cwd: "/Users/x/alpha", out: 10),
            row(id: "b", request: "r2", model: "claude-opus-5", ts: "2026-11-17T10:00:00.000Z", cwd: "/Users/x/beta", out: 20),
            row(id: "c", request: "r3", ts: "2026-11-16T10:00:00.000Z", cwd: "/Users/x/alpha", out: 30),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("a/s.jsonl"), atomically: true, encoding: .utf8)
        let r = UsageScanner(root: root).scan()
        #expect(r.projects["alpha"]?.output == 40 && r.projects["beta"]?.output == 20)
        #expect(r.models["claude-opus-5"]?.messages == 1)
        #expect(r.top(r.projects, 1).first?.name == "alpha")
        #expect(r.all.output == 60)
    }

    @Test func missingRootIsEmptyNotACrash() {
        let r = UsageScanner(root: URL(fileURLWithPath: "/nope/does/not/exist")).scan()
        #expect(r.all.messages == 0 && r.days.isEmpty)
    }

    @Test func utcTimestampsLandOnTheRightLocalDay() {
        // Kathmandu is UTC+5:45, so late-evening UTC is already tomorrow locally.
        let npt = 5 * 3600 + 45 * 60
        #expect(UsageScanner.localDay(fromISO: "2026-11-17T09:00:00.000Z", offsetSeconds: npt) == "2026-11-17")
        #expect(UsageScanner.localDay(fromISO: "2026-11-17T18:30:00.000Z", offsetSeconds: npt) == "2026-11-18")
        #expect(UsageScanner.localDay(fromISO: "2026-01-01T00:00:00.000Z", offsetSeconds: -8 * 3600) == "2025-12-31")
        #expect(UsageScanner.localDay(fromISO: "2026-02-28T20:00:00.000Z", offsetSeconds: npt) == "2026-03-01")   // leap year
        #expect(UsageScanner.localDay(fromISO: nil) == "unknown")
        #expect(UsageScanner.localDay(fromISO: "garbage") == "unknown")
    }

    @Test func civilCalendarRoundTrips() {
        for (y, m, d) in [(1970, 1, 1), (2000, 2, 29), (2026, 11, 17), (2026, 12, 31), (1999, 3, 1)] {
            let (a, b, c) = UsageScanner.civil(fromDays: UsageScanner.days(y: y, m: m, d: d))
            #expect((a, b, c) == (y, m, d))
        }
    }

    @Test func rollingWindowsAndSparkline() {
        var r = UsageReport()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        for (offset, out) in [(0, 100), (1, 50), (6, 25), (9, 1000)] {
            var t = UsageTotals(); t.output = out; t.messages = 1
            r.days[UsageScanner.dayKey(cal.date(byAdding: .day, value: -offset, to: today)!, calendar: cal)] = t
        }
        #expect(r.totals(sinceDaysAgo: 1, today: today, calendar: cal).output == 100)
        #expect(r.totals(sinceDaysAgo: 7, today: today, calendar: cal).output == 175)
        #expect(r.totals(sinceDaysAgo: 14, today: today, calendar: cal).output == 1175)
        let spark = r.recentDays(7, today: today, calendar: cal)
        #expect(spark.count == 7)
        #expect(spark.last?.totals.output == 100)       // today is last
        #expect(spark.first?.totals.output == 25)       // six days ago is first
    }

    @Test func tokenFormatting() {
        #expect(formatTokens(0) == "0")
        #expect(formatTokens(999) == "999")
        #expect(formatTokens(12_400) == "12.4k")
        #expect(formatTokens(3_100_000) == "3.1M")
        #expect(formatTokens(4_870_000_000) == "4.87B")
    }
}

// MARK: Usage limits
//
// Fixtures below are hand-written in the shape the CLIs print, not captured output.

@Suite struct LimitTests {
    static let claudeOutput = """
    Warning: this sign-in ends between 2026-11-19 and 2026-11-22 (in 2 days at the earliest). Run claude auth login before then.
    You are currently using your subscription to power your Claude Code usage

    Current session: 80% used \u{00B7} resets Nov 17 at 5:25pm (Asia/Katmandu)
    Current week (all models): 41% used \u{00B7} resets Nov 19 at 2:45pm (Asia/Katmandu)

    What's contributing to your usage?
    Approximate \u{00B7} sessions on this machine only \u{00B7} shares overlap

    Last 24h \u{00B7} 306 requests \u{00B7} 2 sessions
      90%  Start fresh when you switch tasks \u{00B7} run /clear
      13%  See what fills your context \u{00B7} run /context
      Top subagents: general-purpose 27%
    """

    @Test func readsTheQuotaLinesAndIgnoresAdvicePercentages() {
        let l = LimitParser.parse(Self.claudeOutput)
        #expect(l.count == 2)
        #expect(l[0].label == "Current session" && l[0].percentUsed == 80)
        #expect(l[0].resets == "Nov 17 at 5:25pm (Asia/Katmandu)")
        #expect(l[1].label == "Current week (all models)" && l[1].percentUsed == 41)
        // The indented "90% Start fresh" tips are a different measure entirely.
        #expect(!l.contains { $0.percentUsed == 90 || $0.percentUsed == 13 || $0.percentUsed == 27 })
    }

    @Test func remainingIsWhatTheRingShows() {
        let l = LimitParser.parse(Self.claudeOutput)
        #expect(l[0].percentLeft == 20 && approx(l[0].fractionLeft, 0.2))
        #expect(l[1].percentLeft == 59)
        var r = ProviderReading(provider: "Claude Code")
        r.limits = l
        #expect(r.tightest?.label == "Current session")      // the one closest to running out
    }

    @Test func shortLabelsFitUnderARing() {
        #expect(UsageLimit(label: "Current session", percentUsed: 1).shortLabel == "Session")
        #expect(UsageLimit(label: "Current week (all models)", percentUsed: 1).shortLabel == "Week")
        #expect(UsageLimit(label: "Opus", percentUsed: 1).shortLabel == "Opus")
    }

    @Test func edgeCases() {
        #expect(LimitParser.parse("Current session: 100% used").first?.percentLeft == 0)
        #expect(LimitParser.parse("Current session: 0% used \u{00B7} resets soon").first?.percentLeft == 100)
        // No reset clause at all.
        let noReset = LimitParser.parse("Weekly: 5% used")
        #expect(noReset.count == 1 && noReset[0].resets == nil)
        // Things that must never parse.
        #expect(LimitParser.parse("  90%  Start fresh when you switch tasks").isEmpty)
        #expect(LimitParser.parse("Top subagents: general-purpose 27%").isEmpty)
        #expect(LimitParser.parse("Last 24h \u{00B7} 306 requests").isEmpty)
        #expect(LimitParser.parse("").isEmpty)
        #expect(LimitParser.parse("garbage without a colon 50% used").isEmpty)
        #expect(LimitParser.parse("Session: abc% used").isEmpty)
        // Out-of-range values are clamped rather than trusted.
        #expect(UsageLimit(label: "x", percentUsed: 140).percentUsed == 100)
        #expect(UsageLimit(label: "x", percentUsed: -5).percentUsed == 0)
    }

    @Test func passesOnTheSignInWarning() {
        let n = LimitParser.notice(in: Self.claudeOutput)
        #expect(n?.hasPrefix("this sign-in ends") == true)
        #expect(LimitParser.notice(in: "Current session: 1% used") == nil)
    }

    @Test func failuresNeverLookLikeZeroPercent() {
        let bad = LimitParser.reading(provider: "Claude Code", output: "command not found", exitCode: 127)
        #expect(bad.limits.isEmpty && bad.problem == "couldn't read limits (exit 127)")
        let out = LimitParser.reading(provider: "Claude Code", output: "Please run claude login to continue", exitCode: 0)
        #expect(out.problem == "not signed in")
        let good = LimitParser.reading(provider: "Claude Code", output: Self.claudeOutput, exitCode: 0)
        #expect(good.problem == nil && good.limits.count == 2 && good.notice != nil)
    }

    @Test func builtInProvidersAreHonestAboutSupport() {
        let p = LimitProvider.builtIn
        #expect(p.first(where: { $0.executable == "claude" })?.supported == true)
        // No documented quota command exists for these, so they must not pretend otherwise.
        #expect(p.first(where: { $0.executable == "codex" })?.supported == false)
        #expect(p.first(where: { $0.executable == "agy" })?.supported == false)
        #expect(p.first(where: { $0.executable == "claude" })?.arguments.contains("--no-session-persistence") == true)
    }
}
