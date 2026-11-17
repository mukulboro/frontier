import AppKit
import SwiftUI
import FrontierCore

/// The wheel has two faces: your apps, and the gramophone.
enum WheelPage { case apps, gramophone }

final class WheelModel: ObservableObject {
    static let outer: CGFloat = 250
    static let inner: CGFloat = 104

    @Published var slots: [AppInfo?] = Array(repeating: nil, count: 8)
    @Published var selected: Int?
    @Published var meta: AppMeta?
    /// Stays open after the modifier is released (tap-to-open, or while re-equipping).
    @Published var pinned = false
    @Published var editing = false
    @Published var query = ""
    @Published var catalog: [AppInfo] = []
    @Published var hotKeyLabel = ""
    @Published var page = WheelPage.apps
    @Published var tunes: [GramophoneAction] = []
    /// False when Frontier lacks the Accessibility permission, so the wheel can say so instead of
    /// quietly doing nothing.
    @Published var canControlMedia = true

    var onCommit: ((Int) -> Void)?
    var onEquip: ((Int, AppInfo?) -> Void)?
    var onCancel: (() -> Void)?

    var filtered: [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? catalog : catalog.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    func select(_ i: Int?) {
        guard i != selected else { return }
        selected = i
        // Only the apps page has app metadata to look up.
        meta = page == .apps ? i.flatMap { slots[$0] }.map(AppCatalog.meta) : nil
    }

    func flipPage() {
        page = page == .apps ? .gramophone : .apps
        let keep = selected
        selected = nil
        select(keep)
    }
}

private final class WheelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The app wheel: hold the hotkey, point, release.
final class WheelController {
    private let state: AppState
    private let hotKey = HotKey()
    let model = WheelModel()
    private var window: WheelWindow?
    private var poll: Timer?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var savedMouse: CGPoint?
    private var openedAt = Date.distantPast
    private var lastMouse = NSPoint.zero
    private var center = NSPoint.zero
    private var keyboardDriven = false

    var isOpen: Bool { window != nil }

    init(state: AppState) {
        self.state = state
        if state.settings.wheelSlots.count != 8 {
            state.settings.wheelSlots = AppCatalog.defaultSlots
        }
        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        registerHotKey()
        model.onCommit = { [weak self] i in self?.commit(i) }
        model.onCancel = { [weak self] in self?.close(restoreFocus: true) }
        model.onEquip = { [weak self] i, app in self?.equip(i, app) }
    }

    @discardableResult
    func registerHotKey() -> Bool {
        model.hotKeyLabel = state.settings.hotKey.label
        return hotKey.register(state.settings.hotKey)
    }

    private func loadSlots() {
        model.slots = state.settings.wheelSlots.map { AppCatalog.info(path: $0) }
    }

    private func hotKeyPressed() {
        guard isOpen else { open(); return }
        // Pressing again while held cycles clockwise, like ⌘-Tab.
        keyboardDriven = true
        step(1)
    }

    // MARK: Open / close

    func open(pinned: Bool = false, page: WheelPage = .apps) {
        guard !isOpen else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        loadSlots()
        model.page = page
        model.tunes = GramophoneAction.all(playlist: state.settings.playlistURL)
        model.canControlMedia = MediaKeys.hasPermission
        model.selected = nil; model.meta = nil
        model.pinned = pinned; model.editing = false; model.query = ""
        keyboardDriven = false
        previousApp = NSWorkspace.shared.frontmostApplication
        openedAt = Date()

        let win = WheelWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .popUpMenu
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        win.contentView = NSHostingView(rootView: WheelView(model: model))
        win.alphaValue = 0
        window = win

        // Start the pointer at the hub, as the game does; it's put back on cancel.
        center = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        savedMouse = CGEvent(source: nil)?.location
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        CGWarpMouseCursorPosition(CGPoint(x: center.x, y: primaryHeight - center.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        lastMouse = center

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            win.animator().alphaValue = 1
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.handle(e) ?? e
        }
        // Only ticks while the wheel is open. Reads the pointer and the modifier state directly,
        // so it works whether or not the window managed to become key.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func close(restoreFocus: Bool) {
        guard let win = window else { return }
        window = nil
        poll?.invalidate(); poll = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if restoreFocus {
            if let p = savedMouse { CGWarpMouseCursorPosition(p) }
            if let prev = previousApp, prev != .current {
                NSApp.yieldActivation(to: prev)
                prev.activate(from: .current, options: [])
            }
        }
        savedMouse = nil; previousApp = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            win.animator().alphaValue = 0
        }, completionHandler: {
            win.orderOut(nil)
            win.contentView = nil
        })
        AppCatalog.flushIcons()
        model.catalog = []
    }

    private func commit(_ index: Int) {
        if model.page == .gramophone {
            guard index >= 0, index < model.tunes.count else { return }
            let action = model.tunes[index]
            if let open = action.open {
                open()
                if action.staysOpen || action.id == "mute" {
                    // Volume and mute stay on the wheel so they can be nudged again, and the hub
                    // re-reads the live level.
                    model.tunes = GramophoneAction.all(playlist: state.settings.playlistURL)
                    let keep = model.selected
                    model.selected = nil
                    model.select(keep)
                } else {
                    close(restoreFocus: false)
                }
                return
            }
            guard let key = action.key else { return }
            if !MediaKeys.post(key) { model.canControlMedia = false; return }
            if !action.staysOpen { close(restoreFocus: true) }
            return
        }
        guard index >= 0, index < model.slots.count else { return }
        guard let app = model.slots[index] else {
            // An empty slot is an invitation to equip something.
            model.select(index)
            beginEditing()
            return
        }
        close(restoreFocus: false)
        AppCatalog.summon(app)
    }

    // MARK: Input

    private func tick() {
        guard isOpen else { return }
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse {
            lastMouse = mouse
            keyboardDriven = false
        }
        if !keyboardDriven, !model.editing {
            model.select(WheelMath.segment(dx: mouse.x - center.x, dy: mouse.y - center.y, deadZone: WheelModel.inner * 0.55))
        }
        guard !model.pinned else { return }
        let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: hotKey.modifiers)
        guard !held else { return }
        if let i = model.selected {
            commit(i)
        } else if Date().timeIntervalSince(openedAt) < 0.3 {
            model.pinned = true          // a quick tap leaves the wheel open
        } else {
            close(restoreFocus: true)
        }
    }

    /// Test hook: runs a key press through the real handler.
    func handleForTest(keyCode: UInt16) -> Bool {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: keyCode) else { return false }
        return handle(e) == nil
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard isOpen else { return e }
        switch e.type {
        case .leftMouseDown:
            if model.editing { return e }                      // let the picker take clicks
            if let i = segment(at: e) { commit(i) } else { close(restoreFocus: true) }
            return nil
        case .rightMouseDown:
            if model.page == .apps, let i = segment(at: e) { model.select(i); beginEditing() }
            return nil
        case .keyDown:
            if e.keyCode == 53 {                               // esc
                if model.editing { endEditing() } else { close(restoreFocus: true) }
                return nil
            }
            if model.editing { return e }                      // typing in the search field
            switch e.keyCode {
            case 36, 76: if let i = model.selected { commit(i) }
            case 124, 125: keyboardDriven = true; step(1)
            case 123, 126: keyboardDriven = true; step(-1)
            case 15: model.flipPage()                                       // R — flip to the other wheel
            case 14: if model.page == .apps, model.selected != nil { beginEditing() }   // E — change equipped
            case 51: if model.page == .apps, let i = model.selected { equip(i, nil) }   // delete — unequip
            default:
                if let n = Int(e.charactersIgnoringModifiers ?? ""), (1...8).contains(n) {
                    keyboardDriven = true
                    model.select(n - 1)
                }
            }
            return nil
        default:
            return e
        }
    }

    private func segment(at e: NSEvent) -> Int? {
        let p = NSEvent.mouseLocation
        let dx = p.x - center.x, dy = p.y - center.y
        guard (dx * dx + dy * dy).squareRoot() <= WheelModel.outer + 12 else { return nil }
        return WheelMath.segment(dx: dx, dy: dy, deadZone: WheelModel.inner)
    }

    private func step(_ d: Int) {
        model.select(((model.selected ?? (d > 0 ? -1 : 0)) + d + 8) % 8)
    }

    // MARK: Equipping

    private func beginEditing() {
        guard model.page == .apps else { return }
        if model.catalog.isEmpty { model.catalog = AppCatalog.installed() }
        model.query = ""
        model.pinned = true
        model.editing = true
    }

    private func endEditing() {
        model.editing = false
        window?.makeFirstResponder(nil)
    }

    private func equip(_ index: Int, _ app: AppInfo?) {
        guard model.page == .apps, index >= 0, index < 8 else { return }
        var slots = state.settings.wheelSlots
        slots[index] = app?.path ?? ""
        state.settings.wheelSlots = slots
        loadSlots()
        model.meta = app.map(AppCatalog.meta)
        endEditing()
    }
}
