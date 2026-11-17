import AppKit
import Combine
import SwiftUI
import FrontierCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var state: AppState!
    private var desktop: DesktopController!
    private var wheel: WheelController!
    private let audio = FireAudio()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var bag = Set<AnyCancellable>()
    private var lastTitle = ""
    private var lastIcon = ""
    private lazy var hatIcon: NSImage = {
        let icon = Res.art("hat").copy() as! NSImage
        icon.size = NSSize(width: 19, height: 19)
        icon.isTemplate = true
        return icon
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        Theme.registerFonts()
        state = AppState()
        desktop = DesktopController(state: state)
        wheel = WheelController(state: state)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = hatIcon
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Frontier")
        }

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        state.pomodoroEvents
            .sink { [weak self] e in self?.played(e) }
            .store(in: &bag)
        refresh()
        runDemo()
    }

    /// `--demo timer|wheel|stag|wolf` starts in a given state, for automated checks.
    private func runDemo() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "timer":
            state.settings.pomodoro = PomodoroConfig(focusMinutes: 1, shortBreakMinutes: 1, longBreakMinutes: 1, rounds: 1)
            state.startTimer()
        case "tally":
            func mb() -> Int {
                var info = task_vm_info_data_t()
                var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
                return kr == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
            }
            print("before scan: \(mb()) MB")
            let t0 = Date()
            state.refreshUsage(force: true)
            var peak = 0
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
                peak = max(peak, mb())
                guard let u = self.state.usage else { return }
                timer.invalidate()
                print("scan done in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s  peak \(peak) MB  now \(mb()) MB")
                print("messages \(u.all.messages)  output \(formatTokens(u.all.output))  days \(u.days.count)  projects \(u.projects.count)")
                // Time the scanner itself; the published report may be unchanged, so there is
                // nothing to observe from outside.
                let cache = AppState.defaultStoreURL?.deletingLastPathComponent().appendingPathComponent("usage-cache.json")
                let t1 = Date()
                _ = UsageScanner(root: UsageScanner.defaultRoot, cacheURL: cache).scan()
                print("warm rescan \(String(format: "%.3f", Date().timeIntervalSince(t1)))s  footprint \(mb()) MB")
                NSApp.terminate(nil)
            }
        case "popover":
            // Opens the popover on a given tab so it can be photographed.
            let want = ProcessInfo.processInfo.environment["FRONTIER_TAB"] ?? "tally"
            state.refreshUsage(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                togglePopover()
                if let tab = PopoverTab.allCases.first(where: { $0.rawValue.lowercased() == want }) {
                    popover?.contentViewController = NSHostingController(rootView: PopoverView(state: state, tab: tab))
                }
            }
        case "media-test":
            // Volume is the only media key whose effect can be observed silently.
            func volume() -> Int {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "output volume of (get volume settings)"]
                let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
                return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            }
            var log = "preflight=\(MediaKeys.hasPermission)\n"
            let before = volume()
            log += "volume before=\(before)\n"
            _ = MediaKeys.post(.volumeDown)
            Thread.sleep(forTimeInterval: 0.7)
            let after = volume()
            log += "after volumeDown=\(after)  changed=\(after != before)\n"
            let p2 = Process(); p2.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p2.arguments = ["-e", "set volume output volume \(before)"]
            try? p2.run(); p2.waitUntilExit()
            try? log.write(toFile: ProcessInfo.processInfo.environment["FRONTIER_MEDIA_CHECK"] ?? NSTemporaryDirectory() + "mt.txt",
                           atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        case "limits":
            let t0 = Date()
            let readings = LimitsRunner.readAll()
            print(String(format: "checked in %.1fs", Date().timeIntervalSince(t0)))
            for r in readings {
                print("  \(r.provider): available=\(r.available) problem=\(r.problem ?? "-")")
                for l in r.limits { print("     \(l.shortLabel): \(l.percentLeft)% left  refills \(l.resets ?? "?")") }
                if let n = r.notice { print("     notice: \(n.prefix(70))") }
            }
            NSApp.terminate(nil)
        case "gramophone-test":
            // Exercises the real wheel actions, then puts the audio back as it was.
            let v0 = SystemAudio.volume, m0 = SystemAudio.isMuted
            print("volume before=\(v0.map { Int($0 * 100) }.map(String.init) ?? "nil")%  muted=\(String(describing: m0))")
            let tunes = GramophoneAction.all(playlist: "")
            for id in ["voldown", "voldown", "volup"] {
                tunes.first { $0.id == id }?.open?()
                usleep(250_000)
                print("  after \(id): \(SystemAudio.volume.map { Int($0 * 100) }.map(String.init) ?? "nil")%")
            }
            tunes.first { $0.id == "mute" }?.open?()
            usleep(300_000)
            print("  after mute: muted=\(String(describing: SystemAudio.isMuted))")
            tunes.first { $0.id == "mute" }?.open?()
            usleep(300_000)
            print("  after unmute: muted=\(String(describing: SystemAudio.isMuted))")
            if let v0 { SystemAudio.setVolume(v0) }
            if let m0, SystemAudio.isMuted != m0 { _ = SystemAudio.toggleMute() }
            usleep(200_000)
            print("restored volume=\(SystemAudio.volume.map { Int($0 * 100) }.map(String.init) ?? "nil")%  muted=\(String(describing: SystemAudio.isMuted))")
            print("transport needs permission: \(!MediaKeys.hasPermission)")
            NSApp.terminate(nil)
        case "wheel": wheel.open(pinned: true)
        case "media-check":
            let path = ProcessInfo.processInfo.environment["FRONTIER_MEDIA_CHECK"] ?? NSTemporaryDirectory() + "media-check.txt"
            try? "post_event_access=\(MediaKeys.hasPermission)\n".write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        case "wheel-selftest": wheelSelfTest()
        case "camp":      // a fully built camp, burning
            state.debugSet(renown: 20)
            state.settings.pomodoro = PomodoroConfig(focusMinutes: 2, shortBreakMinutes: 1, longBreakMinutes: 1, rounds: 1)
            state.startTimer()
        case "stag": state.debugSet(honor: 0.7)
        case "wolf": state.debugSet(honor: -0.7)
        default: break
        }
    }

    /// Drives the wheel's real open → select → summon path once and reports each step, then puts the
    /// user's frontmost app and pointer back. Takes about two seconds.
    private func wheelSelfTest() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
        let original = NSWorkspace.shared.frontmostApplication
        check("hotkey \(state.settings.hotKey.label) registered", wheel.registerHotKey())
        wheel.open(pinned: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            check("wheel window opens", wheel.isOpen)
            check("eight slots loaded", wheel.model.slots.count == 8)
            check("pointer starts in the dead zone (nothing selected)", wheel.model.selected == nil)
            guard let slot = wheel.model.slots.firstIndex(where: { $0?.name == "Finder" }) else {
                check("Finder is equipped", false); exit(1)
            }
            wheel.model.select(slot)
            check("hub shows metadata for the selection", wheel.model.meta?.name == "Finder" && wheel.model.meta?.running == true)
            check("metadata includes version and memory", wheel.model.meta?.version != nil && wheel.model.meta?.memoryMB != nil)
            // The gramophone face must not touch the app loadout.
            let loadout = state.settings.wheelSlots
            wheel.model.flipPage()
            check("R flips to the gramophone", wheel.model.page == .gramophone)
            check("gramophone has eight controls", wheel.model.tunes.count == 8)
            check("hub shows no app metadata on the gramophone", wheel.model.meta == nil)
            // Note: launched from a terminal this inherits the terminal's grant, so it only reflects
            // the installed app when run with `open`. See --demo media-check.
            check("media permission reported: \(MediaKeys.hasPermission ? "granted" : "not granted")", true)
            // Every path that could edit a slot, exercised on the wrong page.
            wheel.model.select(3)
            wheel.model.onEquip?(3, nil)
            _ = wheel.handleForTest(keyCode: 14)        // E
            _ = wheel.handleForTest(keyCode: 51)        // delete
            check("gramophone page cannot overwrite the app loadout", state.settings.wheelSlots == loadout)
            check("gramophone page never opens the app picker", !wheel.model.editing)
            wheel.model.flipPage()
            check("R flips back to the apps", wheel.model.page == .apps)

            // Settings must survive a save/load round trip, including the newest ones.
            var s = state.settings
            s.playlistURL = "https://music.youtube.com/playlist?list=TEST"
            s.trackUsage = false
            s.menuBar = .both
            s.skyFollowsClock = false
            let round = (try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)))
            check("settings round-trip keeps playlist", round?.playlistURL == s.playlistURL)
            check("settings round-trip keeps tally, menu bar and sky",
                  round?.trackUsage == false && round?.menuBar == .both && round?.skyFollowsClock == false)

            wheel.model.select(slot)
            wheel.model.onCommit?(slot)
            check("wheel closes on commit", !wheel.isOpen)
            // Activation is asynchronous and its timing varies, so poll rather than guess a delay.
            var waited = 0.0
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
                waited += 0.2
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
                guard front || waited > 4 else { return }
                timer.invalidate()
                check("committed app comes to the front", front)
                if let original, original != .current {
                    NSApp.yieldActivation(to: original)
                    original.activate(options: [])
                }
                print(failures == 0 ? "WHEEL SELFTEST OK" : "WHEEL SELFTEST: \(failures) FAILED")
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        state?.save()
    }

    /// Mirrors timer state into the menu bar and the fire's sound. Called on every state change, so
    /// each piece is only touched when its own value has moved.
    private func refresh() {
        let p = state.pomodoro
        let style = state.settings.menuBar
        let active = p.phase.isActive
        let clock = active ? formatClock(p.remaining(now: state.now)) : ""

        let title = active && style != .watch ? " " + clock : ""
        if title != lastTitle {
            lastTitle = title
            statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        }

        // Icon: the hat when idle, the pocket watch while a phase runs.
        let icon: String
        if active, style != .countdown {
            icon = "watch-\(WatchFace.step(for: p.progress(now: state.now)))-\(p.isPaused)-\(p.phase.isBreak)"
        } else {
            icon = "hat"
        }
        if icon != lastIcon {
            lastIcon = icon
            statusItem.button?.image = icon == "hat" ? hatIcon
                : WatchFace.image(step: WatchFace.step(for: p.progress(now: state.now)), paused: p.isPaused, resting: p.phase.isBreak)
        }
        // The exact time is always a hover away, whichever style is showing.
        let tip = active ? "\(p.isPaused ? "Paused" : (p.phase.isBreak ? "Rest" : "Focus")) · \(clock) left" : "Frontier"
        if statusItem.button?.toolTip != tip {
            statusItem.button?.toolTip = tip
            statusItem.button?.setAccessibilityValue(active ? tip : nil)
        }

        audio.volume = state.settings.volume
        let burning = state.settings.fireSound && p.isRunning
        audio.setFire(on: burning, level: state.fireLevel)
    }

    private func played(_ e: PomodoroEvent) {
        guard state.settings.endSound else { return }
        audio.volume = state.settings.volume
        switch e {
        case .focusEnded: audio.play(.focusEnded)
        case .breakEnded: audio.play(.breakEnded)
        case .allDone: audio.play(.allDone)
        }
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        state.settleLedger()
        state.refreshUsage()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        pop.appearance = NSAppearance(named: .aqua)
        pop.contentSize = NSSize(width: 380, height: 560)
        pop.contentViewController = NSHostingController(rootView: PopoverView(
            state: state,
            onOpenWheel: { [weak self] in
                self?.popover?.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.wheel.open(pinned: true) }
            },
            onHotKeyChange: { [weak self] in self?.wheel.registerHotKey() ?? false }))
        popover = pop
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
    }

    // The popover's view tree is built on demand and dropped on close, so it costs nothing while hidden.
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }
}
