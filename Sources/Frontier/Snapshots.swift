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

        // Popover tabs, with a believable day in the ledger.
        let state = AppState(storeURL: nil, live: false)
        state.settings.wheelSlots = AppCatalog.defaultSlots
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
