import AppKit
import Combine
import FrontierCore

struct Settings: Codable, Equatable {
    var pomodoro = PomodoroConfig()
    var campfireOnDesktop = true
    var fireSound = false
    var endSound = true
    var volume = 0.6
    var showCores = true
    var showHonorHUD = true
    var honorBackdrop = true
    /// Bundle paths of the eight equipped apps; empty string = empty slot.
    var wheelSlots: [String] = []
    var hotKey = HotKeyChoice.optionTab
    /// Which display carries the desktop pieces: "all", or one display's id.
    var display = "all"

    init() {}

    // Tolerant decoding so new settings never invalidate an old state file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        pomodoro = try c.decodeIfPresent(PomodoroConfig.self, forKey: .pomodoro) ?? d.pomodoro
        campfireOnDesktop = try c.decodeIfPresent(Bool.self, forKey: .campfireOnDesktop) ?? d.campfireOnDesktop
        fireSound = try c.decodeIfPresent(Bool.self, forKey: .fireSound) ?? d.fireSound
        endSound = try c.decodeIfPresent(Bool.self, forKey: .endSound) ?? d.endSound
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        showCores = try c.decodeIfPresent(Bool.self, forKey: .showCores) ?? d.showCores
        showHonorHUD = try c.decodeIfPresent(Bool.self, forKey: .showHonorHUD) ?? d.showHonorHUD
        honorBackdrop = try c.decodeIfPresent(Bool.self, forKey: .honorBackdrop) ?? d.honorBackdrop
        wheelSlots = try c.decodeIfPresent([String].self, forKey: .wheelSlots) ?? d.wheelSlots
        hotKey = try c.decodeIfPresent(HotKeyChoice.self, forKey: .hotKey) ?? d.hotKey
        display = try c.decodeIfPresent(String.self, forKey: .display) ?? d.display
    }
}

enum HotKeyChoice: String, Codable, CaseIterable, Identifiable {
    case optionTab, optionSpace, controlOptionSpace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .optionTab: return "⌥ Tab"
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        }
    }
}

struct HonorToast: Equatable {
    let gained: Bool
    let id = UUID()
}

enum BackdropMode: Equatable { case none, campfire, stag, wolf }

private struct Snapshot: Codable {
    var settings = Settings()
    var ledger = Ledger()
}

/// Single source of truth. Owns the timers, and only runs the ones that are needed:
/// nothing ticks while the timer is idle, no task has a deadline and the HUD is hidden.
final class AppState: ObservableObject {
    @Published var settings: Settings { didSet { if settings != oldValue { settingsChanged(oldValue) } } }
    @Published private(set) var ledger: Ledger
    @Published private(set) var pomodoro: PomodoroEngine
    /// Drives countdown text; only advances while something on screen needs it.
    @Published private(set) var now = Date()
    @Published private(set) var vitals: VitalSample?
    @Published private(set) var slowCPU = SlowCore()
    @Published private(set) var slowRAM = SlowCore()
    @Published private(set) var slowWifi = SlowCore()
    @Published private(set) var slowBattery = SlowCore()
    @Published private(set) var toast: HonorToast?
    @Published var immersive = false

    /// Fired on timer transitions so audio/visuals can react.
    let pomodoroEvents = PassthroughSubject<PomodoroEvent, Never>()

    private let storeURL: URL?
    private let monitor = VitalsMonitor()
    private var pomodoroTimer: Timer?
    private var ledgerTimer: Timer?
    private var vitalsTimer: Timer?
    private var toastWork: DispatchWorkItem?
    private var doneWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var screenAsleep = false

    /// `storeURL: nil` keeps everything in memory (snapshots, tests).
    init(storeURL: URL? = AppState.defaultStoreURL, live: Bool = true) {
        self.storeURL = storeURL
        var snap = Snapshot()
        if let url = storeURL, let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) { snap = s }
        settings = snap.settings
        ledger = snap.ledger
        pomodoro = PomodoroEngine(config: snap.settings.pomodoro)
        ledger.rollover(now: Date())
        ledger.tick(now: Date())
        guard live else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenAsleep = true; self?.retime()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenAsleep = false; self?.wake()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wake()
        })
        retime()
        if settings.showCores { sampleVitals() }
    }

    static var defaultStoreURL: URL? {
        // FRONTIER_STATE points the app at a scratch file so test runs never touch real data.
        if let override = ProcessInfo.processInfo.environment["FRONTIER_STATE"] { return URL(fileURLWithPath: override) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Frontier/state.json")
    }

    // MARK: Derived

    var mood: HonorMood { Honor.mood(ledger.honor) }
    var rank: HonorRank { Honor.rank(ledger.honor) }
    var fireLevel: Double { pomodoro.fireLevel(now: now) }

    var backdrop: BackdropMode {
        if settings.campfireOnDesktop, pomodoro.phase != .idle { return .campfire }
        guard settings.honorBackdrop else { return .none }
        switch mood {
        case .stag: return .stag
        case .wolf: return .wolf
        case .neutral: return .none
        }
    }

    // MARK: Pomodoro

    func startTimer() {
        doneWork?.cancel()
        pomodoro.config = settings.pomodoro
        pomodoro.start(now: Date())
        now = Date()
        retime()
    }

    func togglePause() {
        if pomodoro.isPaused { pomodoro.resume(now: Date()) } else { pomodoro.pause(now: Date()) }
        now = Date()
        retime()
    }

    func resetTimer() {
        doneWork?.cancel()
        pomodoro.reset()
        immersive = false
        retime()
    }

    func skipPhase() {
        if let e = pomodoro.skip(now: Date()) { handle(e) }
        now = Date()
        retime()
    }

    private func pomodoroTick() {
        let t = Date()
        if let e = pomodoro.tick(now: t) { handle(e) }
        now = t
        if !pomodoro.isRunning { retime() }
    }

    private func handle(_ e: PomodoroEvent) {
        pomodoroEvents.send(e)
        guard e == .allDone else { return }
        // Let the embers glow a while, then give the desktop back.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pomodoro.phase == .done else { return }
            self.resetTimer()
        }
        doneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    // MARK: Ledger

    func addTask(_ text: String, limit: TimeInterval?) {
        ledger.add(text, limit: limit, now: Date())
        ledgerChanged()
    }

    func toggleTask(_ id: UUID) {
        guard let t = ledger.tasks.first(where: { $0.id == id }) else { return }
        if t.isDone {
            ledger.uncomplete(id)
        } else if ledger.complete(id, now: Date()) > 0 {
            show(HonorToast(gained: true))
        }
        ledgerChanged()
    }

    func deleteTask(_ id: UUID) {
        if ledger.delete(id, now: Date()) < 0 { show(HonorToast(gained: false)) }
        ledgerChanged()
    }

    /// Settles deadline pressure and the day boundary. Cheap; safe to call any time.
    func settleLedger() {
        let t = Date()
        let before = ledger
        var l = ledger
        let beforeRank = Honor.rank(l.honor)
        l.rollover(now: t)
        l.tick(now: t)
        now = t
        guard l != before else { return }
        ledger = l
        if Honor.rank(l.honor) != beforeRank, l.honor < before.honor { show(HonorToast(gained: false)) }
        save()
        retime()
    }

    private func ledgerChanged() {
        now = Date()
        save()
        retime()
    }

    private func show(_ t: HonorToast) {
        toastWork?.cancel()
        toast = t
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    // MARK: Vitals

    private func sampleVitals() {
        let s = monitor.sample()
        slowCPU.update(s.cpuFree)
        slowRAM.update(s.ramFree)
        if let w = s.wifi { slowWifi.update(w) }
        if let b = s.battery { slowBattery.update(b) }
        if s != vitals { vitals = s }
    }

    // MARK: Timers

    private func wake() {
        if let e = pomodoro.tick(now: Date()) { handle(e) }
        settleLedger()
        retime()
    }

    private func settingsChanged(_ old: Settings) {
        if !pomodoro.phase.isActive { pomodoro.config = settings.pomodoro }
        save()
        retime()
        if settings.showCores, !old.showCores { sampleVitals() }
    }

    /// Starts exactly the timers the current state needs and stops the rest.
    private func retime() {
        set(&pomodoroTimer, on: pomodoro.isRunning, every: 1, tolerance: 0.1) { [weak self] in self?.pomodoroTick() }
        set(&ledgerTimer, on: ledger.hasTimedOpenTasks || ledger.honor != 0, every: ledger.hasTimedOpenTasks ? 30 : 1800,
            tolerance: 10) { [weak self] in self?.settleLedger() }
        set(&vitalsTimer, on: settings.showCores && !screenAsleep, every: 5, tolerance: 1.5) { [weak self] in self?.sampleVitals() }
    }

    private func set(_ timer: inout Timer?, on: Bool, every interval: TimeInterval, tolerance: TimeInterval,
                     _ body: @escaping () -> Void) {
        if on, let t = timer, t.isValid, t.timeInterval == interval { return }
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in body() }
        t.tolerance = tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Persistence

    func save() {
        guard let url = storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(Snapshot(settings: settings, ledger: ledger)).write(to: url, options: .atomic)
        } catch {
            NSLog("Frontier: could not save state: \(error.localizedDescription)")
        }
    }

    // MARK: Test/demo hooks

    func debugSet(honor: Double) {
        ledger.honor = honor
    }

    func debugSet(vitals s: VitalSample, slow: Double) {
        vitals = s
        slowCPU = SlowCore(); slowCPU.update(slow)
        slowRAM = SlowCore(); slowRAM.update(s.ramFree)
        slowWifi = SlowCore(); slowWifi.update(s.wifi ?? 0)
        slowBattery = SlowCore(); slowBattery.update(s.battery ?? 0)
    }

    func debugToast(gained: Bool) { toast = HonorToast(gained: gained) }
}
