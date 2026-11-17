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
        case "wheel": wheel.open(pinned: true)
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
            wheel.model.onCommit?(slot)
            check("wheel closes on commit", !wheel.isOpen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                check("committed app comes to the front", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")
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
