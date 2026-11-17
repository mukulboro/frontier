import AppKit
import AVFoundation
import SwiftUI
import FrontierCore

/// `Frontier --snapshot <dir>` renders every surface to PNG without touching the user's
/// saved state, so the UI can be checked by eye (and by CI) without clicking through it.
enum Snapshots {
    static func run(outputDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Theme.registerFonts()
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        func save(_ name: String, _ image: NSImage?) {
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("FAIL \(name)"); failures += 1; return
            }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            print("ok   \(name)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }

        let scene = CGSize(width: 1440, height: 900)
        save("vision-stag", HonorArt.render(.stag, size: scene))
        save("vision-wolf", HonorArt.render(.wolf, size: scene))

        // The camp under each sky, bare and fully built. (The fire itself is video; see campfire-* below.)
        for phase in SkyPhase.allCases {
            save("camp-\(phase.rawValue)", Scenery.campImage(size: scene, sky: phase, upgrades: phase == .night ? [] : CampUpgrade.allCases))
        }

        // The pocket watch at several points, enlarged, on light and dark menu bars.
        let faces: [(Int, Bool, Bool)] = [(0, false, false), (30, false, false), (60, false, false), (95, false, false), (45, true, false), (70, false, true)]
        let sheet = NSImage(size: NSSize(width: CGFloat(faces.count) * 80, height: 160))
        sheet.lockFocus()
        for (row, dark) in [(0, true), (1, false)] {
            (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(x: 0, y: CGFloat(row) * 80, width: sheet.size.width, height: 80).fill()
            for (i, f) in faces.enumerated() {
                let face = WatchFace.image(step: f.0, paused: f.1, resting: f.2)
                let rect = NSRect(x: CGFloat(i) * 80 + 13, y: CGFloat(row) * 80 + 13, width: 54, height: 54)
                // Tint the template the way the menu bar would.
                let tinted = Paint.image(size: rect.size, scale: 2) {
                    face.draw(in: NSRect(origin: .zero, size: rect.size))
                    (dark ? NSColor.white : NSColor.black).set()
                    NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
                }
                tinted.draw(in: rect)
            }
        }
        sheet.unlockFocus()
        save("watch-faces", sheet)

        // Popover tabs, with a believable day in the ledger.
        let state = AppState(storeURL: nil, live: false)
        state.settings.wheelSlots = AppCatalog.defaultSlots
        state.debugSet(renown: 4)
        // A made-up fortnight, so the snapshot never contains anything read from the real transcripts.
        var usage = UsageReport()
        let cal = Calendar.current
        for (i, out) in [412_000, 0, 88_000, 230_000, 17_000, 0, 0, 640_000, 120_000, 95_000, 0, 51_000, 380_000, 143_000].enumerated() {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            var t = UsageTotals(); t.output = out; t.messages = out / 900; t.cacheRead = out * 420
            usage.days[UsageScanner.dayKey(d)] = t
        }
        for (name, out) in [("frontier", 980_000), ("stt-data-clean", 640_000), ("ai-upskill", 410_000), ("cctv", 230_000)] {
            var t = UsageTotals(); t.output = out; t.messages = out / 850; usage.projects[name] = t
        }
        for (name, out) in [("claude-sonnet-5", 1_400_000), ("claude-opus-5", 620_000), ("claude-fable-5-2", 270_000)] {
            var t = UsageTotals(); t.output = out; t.messages = out / 870; usage.models[name] = t
        }
        usage.all = usage.days.values.reduce(UsageTotals(), +)
        state.debugSet(usage: usage)
        state.settings.trackUsage = true
        // Invented readings, in the shape the CLIs print.
        var claude = ProviderReading(provider: "Claude Code")
        claude.limits = [UsageLimit(label: "Current session", percentUsed: 80, resets: "Nov 17 at 5:25pm"),
                         UsageLimit(label: "Current week (all models)", percentUsed: 41, resets: "Nov 19 at 2:45pm")]
        claude.notice = "this sign-in ends between Nov 19 and Nov 22. Run claude auth login before then."
        claude.checked = Date()
        var codex = ProviderReading(provider: "Codex")
        codex.problem = "no usage command"
        codex.checked = Date()
        var agy = ProviderReading(provider: "Antigravity")
        agy.problem = "no usage command"
        agy.checked = Date()
        state.debugSet(limits: [claude, codex, agy])
        state.addTask("Mend the north fence #ranch", limit: 3600)
        state.addTask("Write to Mary #letters", limit: 7200)
        state.addTask("Clean the rifles", limit: nil)
        state.addTask("Settle the camp ledger #money #camp", limit: 1800)
        if let t = state.ledger.tasks.last { state.toggleTask(t.id) }
        for tab in PopoverTab.allCases {
            save("popover-\(tab.rawValue.lowercased())", render(PopoverView(state: state, tab: tab), size: CGSize(width: 380, height: 560), light: true))
        }
        state.startTimer()
        save("popover-camp-running", render(PopoverView(state: state, tab: .camp), size: CGSize(width: 380, height: 560), light: true))

        // HUD over a mid-grey "wallpaper", in a healthy and a depleted state.
        func hud(_ name: String, honor: Double, v: VitalSample, slow: Double, toast: Bool?, hover: Bool = false) {
            state.debugSet(honor: honor)
            state.debugSet(vitals: v, slow: slow)
            if let toast { state.debugToast(gained: toast) }
            let view = ZStack(alignment: .bottomLeading) {
                Color(white: 0.32)
                HonorHUDView(state: state)
                CoresView(state: state, forceHover: hover).padding(20)
            }
            save(name, render(view, size: CGSize(width: 1100, height: 260)))
        }
        hud("hud-high", honor: 0.62, v: VitalSample(cpuFree: 0.83, ramFree: 0.55, battery: 0.91, charging: true, wifi: 0.8), slow: 0.7, toast: true)
        hud("hud-hover", honor: 0.2, v: VitalSample(cpuFree: 0.93, ramFree: 0.45, battery: 0.82, charging: false, wifi: 0.7, wifiRSSI: -55, ramTotalGB: 24), slow: 0.8, toast: nil, hover: true)
        hud("hud-low", honor: -0.58, v: VitalSample(cpuFree: 0.12, ramFree: 0.18, battery: 0.14, charging: false, wifi: 0.35), slow: 0.3, toast: false)

        // Wheel: a selected running app, an empty slot, and the equip picker.
        let model = WheelModel()
        model.hotKeyLabel = "⌥ Tab"
        model.slots = AppCatalog.defaultSlots.map { AppCatalog.info(path: $0) }
        model.slots[5] = nil
        model.select(0)
        save("wheel-selected", render(WheelView(model: model), size: scene))
        model.select(nil)
        save("wheel-idle", render(WheelView(model: model), size: scene))
        // The gramophone face, with and without permission.
        model.page = .gramophone
        model.tunes = GramophoneAction.all(playlist: "https://music.youtube.com/playlist?list=PLx")
        model.select(0)
        save("wheel-gramophone", render(WheelView(model: model), size: scene))
        model.canControlMedia = false
        model.select(2)
        save("wheel-gramophone-blocked", render(WheelView(model: model), size: scene))
        model.canControlMedia = true
        model.page = .apps

        model.select(5)
        model.catalog = AppCatalog.installed()
        model.pinned = true; model.editing = true
        save("wheel-equip", render(WheelView(model: model), size: scene))

        // Campfire at three points in its life. Its particles are drawn by the system compositor, so it
        // can only be captured from a real window: one is parked on the desktop layer (beneath every
        // app) and photographed by window id. Needs Screen Recording permission; skipped without it.
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        let frame = (NSScreen.screens.first?.frame).map { NSRect(x: $0.minX, y: $0.minY, width: scene.width, height: scene.height) }
            ?? NSRect(origin: .zero, size: scene)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = level
        win.ignoresMouseEvents = true
        let fire = CampfireView(frame: NSRect(origin: .zero, size: scene))
        win.contentView = fire
        win.orderFrontRegardless()
        for (name, level, phase, clock) in [("campfire-full", 1.0, "Focus · Round 1 of 4", "24:51"),
                                            ("campfire-half", 0.5, "Focus · Round 2 of 4", "12:30"),
                                            ("campfire-embers", 0.04, "Focus · Round 4 of 4", "00:58")] {
            fire.configure(sky: name == "campfire-full" ? .dusk : .night, upgrades: name == "campfire-embers" ? [] : CampUpgrade.allCases)
            fire.set(level: level, animated: false)
            fire.set(phase: phase, clock: clock)
            RunLoop.main.run(until: Date().addingTimeInterval(3.5))
            let out = dir.appendingPathComponent(name + ".png")
            try? FileManager.default.removeItem(at: out)
            let cap = Process()
            cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            cap.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", out.path]
            try? cap.run()
            cap.waitUntilExit()
            if FileManager.default.fileExists(atPath: out.path) { print("ok   \(name)") } else { print("skip \(name)  (no Screen Recording permission)") }
        }
        win.orderOut(nil)

        // Sound can't be seen, so check it numerically: audible, never clipping, and seamless at the loop point.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        func stats(_ b: AVAudioPCMBuffer) -> (peak: Float, rms: Float, seam: Float) {
            let n = Int(b.frameLength), d = b.floatChannelData![0]
            var peak: Float = 0, sum: Float = 0
            for i in 0..<n { peak = max(peak, abs(d[i])); sum += d[i] * d[i] }
            return (peak, (sum / Float(n)).squareRoot(), abs(d[0] - d[n - 1]))
        }
        func audio(_ name: String, _ b: AVAudioPCMBuffer, loops: Bool) {
            let s = stats(b)
            let ok = s.peak > 0.05 && s.peak < 0.999 && s.rms > 0.005 && (!loops || s.seam < 0.15)
            print(String(format: "%@ audio-%@  %.1fs peak %.2f rms %.3f seam %.3f", ok ? "ok  " : "FAIL", name,
                         Double(b.frameLength) / 44_100, s.peak, s.rms, s.seam))
            if !ok { failures += 1 }
        }
        audio("fire-loop", FireAudio.makeFireLoop(format: format), loops: true)
        audio("focus-ended", FireAudio.makeCue(.focusEnded, format: format), loops: false)
        audio("break-ended", FireAudio.makeCue(.breakEnded, format: format), loops: false)
        audio("all-done", FireAudio.makeCue(.allDone, format: format), loops: false)

        print(failures == 0 ? "ALL SNAPSHOTS OK" : "\(failures) SNAPSHOT(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Renders a SwiftUI view through a real (off-screen) window so AppKit-backed controls draw too.
    static func render<V: View>(_ view: V, size: CGSize, light: Bool = false) -> NSImage? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        win.orderOut(nil)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}
