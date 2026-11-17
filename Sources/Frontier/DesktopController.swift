import AppKit
import Combine
import SwiftUI
import FrontierCore

/// The connected displays, as the settings picker and the desktop controller see them.
enum Displays {
    static func id(_ screen: NSScreen) -> String {
        let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return n.map { "\($0.uint32Value)" } ?? screen.localizedName
    }

    static func all() -> [(id: String, name: String)] {
        NSScreen.screens.map { (id($0), $0.localizedName) }
    }

    /// The screens the desktop pieces should appear on. A remembered display that has been
    /// unplugged falls back to the primary one rather than showing nothing.
    static func targets(for setting: String) -> [NSScreen] {
        let screens = NSScreen.screens
        if setting == "all" { return screens }
        if let match = screens.first(where: { id($0) == setting }) { return [match] }
        return Array(screens.prefix(1))
    }
}

/// Puts the desktop pieces on whichever displays the user chose, and keeps that in step with
/// displays being plugged in, unplugged or rearranged.
final class DesktopController {
    private let state: AppState
    private var surfaces: [String: ScreenSurface] = [:]
    private var bag = Set<AnyCancellable>()
    private var observer: NSObjectProtocol?
    private var dismissMonitor: Any?

    init(state: AppState) {
        self.state = state
        // Coalesce: many published changes in one runloop turn become a single sync.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
        sync()
    }

    private func sync() {
        let targets = Displays.targets(for: state.settings.display)
        let wanted = Set(targets.map(Displays.id))
        for (id, surface) in surfaces where !wanted.contains(id) {
            surface.close()
            surfaces[id] = nil
        }
        for screen in targets {
            let id = Displays.id(screen)
            let surface = surfaces[id] ?? ScreenSurface(state: state)
            surfaces[id] = surface
            surface.sync(on: screen)
        }
        syncImmersive()
    }

    /// "Sit by the fire": while it's on, any click or key press brings the desktop back.
    private func syncImmersive() {
        if state.immersive, state.backdrop != .campfire { state.immersive = false }
        if state.immersive, dismissMonitor == nil {
            dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
                self?.state.immersive = false
                return nil
            }
        } else if !state.immersive, let m = dismissMonitor {
            NSEvent.removeMonitor(m)
            dismissMonitor = nil
        }
    }
}

/// Everything Frontier draws on one display's desktop, beneath every app:
/// the backdrop (campfire or honor vision), the honor meter, and the cores.
private final class ScreenSurface {
    private let state: AppState
    private var backdropWindow: NSWindow?
    private var honorWindow: NSWindow?
    private var coresWindow: NSWindow?
    private var fire: CampfireView?
    /// The vision is a bare layer showing an IOSurface, so exactly one copy of the picture exists.
    private var artLayer: CALayer?
    private var shown: BackdropMode = .none
    private var artSize = CGSize.zero
    private var occlusionObserver: NSObjectProtocol?

    private static let backdropLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    private static let honorLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
    /// Just above the Finder's desktop icons, so the cores can feel the pointer. Still below every app window.
    private static let coresLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(state: AppState) { self.state = state }

    func sync(on screen: NSScreen) {
        syncHonor(screen)
        syncCores(screen)
        syncBackdrop(screen)
    }

    func close() {
        fire?.tearDown(); fire = nil
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        for w in [backdropWindow, honorWindow, coresWindow] { w?.orderOut(nil) }
        backdropWindow = nil; honorWindow = nil; coresWindow = nil; artLayer = nil
        shown = .none
    }

    // MARK: Honor meter (click-through)

    private func syncHonor(_ screen: NSScreen) {
        guard state.settings.showHonorHUD else {
            honorWindow?.orderOut(nil); honorWindow = nil
            return
        }
        let frame = screen.visibleFrame
        if honorWindow == nil {
            let win = Self.makeWindow(frame: frame, level: Self.honorLevel)
            let host = NSHostingView(rootView: HonorHUDView(state: state))
            host.autoresizingMask = [.width, .height]
            win.contentView = host
            win.orderFrontRegardless()
            honorWindow = win
        }
        if honorWindow?.frame != frame { honorWindow?.setFrame(frame, display: true) }
    }

    // MARK: Cores (hoverable)

    private func syncCores(_ screen: NSScreen) {
        guard state.settings.showCores, state.vitals != nil else {
            coresWindow?.orderOut(nil); coresWindow = nil
            return
        }
        if coresWindow == nil {
            let win = Self.makeWindow(frame: .zero, level: Self.coresLevel)
            win.ignoresMouseEvents = false
            win.contentView = NSHostingView(rootView: CoresView(state: state))
            coresWindow = win
        }
        guard let win = coresWindow, let host = win.contentView else { return }
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.minX + 20, y: visible.minY + 14, width: size.width, height: size.height)
        if win.frame != frame { win.setFrame(frame, display: true) }
        if !win.isVisible { win.orderFrontRegardless() }
    }

    // MARK: Backdrop

    private func syncBackdrop(_ screen: NSScreen) {
        let mode = state.backdrop
        if let win = backdropWindow, win.frame != screen.frame { win.setFrame(screen.frame, display: true) }
        if mode == .campfire { updateFire() }
        applyImmersive()
        let size = screen.frame.size
        guard mode != shown || ((mode == .stag || mode == .wolf) && artSize != size) else { return }
        shown = mode
        guard mode != .none else {
            fadeOutBackdrop()
            return
        }
        let win = backdropWindow ?? {
            let w = Self.makeWindow(frame: screen.frame, level: Self.backdropLevel)
            w.contentView = NSView(frame: NSRect(origin: .zero, size: size))
            w.contentView?.wantsLayer = true
            w.alphaValue = 0
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                self?.occlusionChanged()
            }
            backdropWindow = w
            return w
        }()
        let bounds = NSRect(origin: .zero, size: size)

        if mode == .campfire {
            artLayer?.removeFromSuperlayer(); artLayer = nil
            if fire == nil {
                let v = CampfireView(frame: bounds)
                v.autoresizingMask = [.width, .height]
                win.contentView?.addSubview(v)
                fire = v
            }
            updateFire(animated: false)
        } else {
            fire?.tearDown(); fire = nil
            let layer = artLayer ?? {
                let l = CALayer()
                l.contentsGravity = .resize
                l.actions = ["contents": { let t = CATransition(); t.type = .fade; t.duration = 1.2; return t }()]
                win.contentView?.layer?.addSublayer(l)
                artLayer = l
                return l
            }()
            layer.frame = bounds
            // Paint, hand the pixels to the layer, and let every intermediate go before returning.
            autoreleasepool {
                layer.contents = HonorArt.surface(mode == .stag ? .stag : .wolf, size: size, scale: min(2, screen.backingScaleFactor))
            }
            Res.flushArt()
            artSize = size
        }
        win.orderFrontRegardless()
        honorWindow?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            win.animator().alphaValue = 1
        }
        occlusionChanged()
    }

    private func updateFire(animated: Bool = true) {
        guard let fire else { return }
        let p = state.pomodoro
        fire.configure(sky: state.sky, upgrades: state.upgrades)
        fire.set(level: p.phase == .done ? 0 : state.fireLevel, animated: animated)
        let title: String
        switch p.phase {
        case .focus: title = "Focus · Round \(p.round) of \(p.config.rounds)"
        case .shortBreak: title = "Rest a while"
        case .longBreak: title = "Long rest"
        case .done: title = "The fire is out"
        case .idle: title = ""
        }
        fire.set(phase: p.isPaused ? "Paused" : title, clock: p.phase == .done ? "" : formatClock(p.remaining(now: state.now)))
    }

    private func fadeOutBackdrop() {
        guard let win = backdropWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.2
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.shown == .none else { return }
            // Release the player, textures and window entirely while nothing is shown.
            self.fire?.tearDown(); self.fire = nil
            self.artLayer?.removeFromSuperlayer(); self.artLayer = nil
            if let o = self.occlusionObserver { NotificationCenter.default.removeObserver(o); self.occlusionObserver = nil }
            win.orderOut(nil)
            self.backdropWindow = nil
        })
    }

    /// Stop playback whenever the desktop is fully covered — the common case while working.
    private func occlusionChanged() {
        guard let win = backdropWindow, let fire else { return }
        fire.isPaused = !win.occlusionState.contains(.visible)
    }

    private func applyImmersive() {
        guard let win = backdropWindow else { return }
        let want = state.immersive && state.backdrop == .campfire
        guard want != (win.level == .screenSaver) else { return }
        if want {
            win.level = .screenSaver
            win.ignoresMouseEvents = false
            win.orderFrontRegardless()
        } else {
            win.level = Self.backdropLevel
            win.ignoresMouseEvents = true
            honorWindow?.orderFrontRegardless()
        }
    }

    private static func makeWindow(frame: NSRect, level: NSWindow.Level) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = level
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        return w
    }
}
